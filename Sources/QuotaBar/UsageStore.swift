import QuotaBarCore
import Combine
import Foundation

/// Owns provider state and the refresh schedule. Polling, opening the menu, and the Refresh row
/// refresh only the displayed provider. Switching providers refreshes the newly selected one.
/// Price edits refresh local costs independently of quota requests.
@MainActor
final class UsageStore: ObservableObject {
    @Published private(set) var displays: [Provider: ProviderDisplay] = [:]
    /// Which providers have a fetch in flight. Per provider rather than one flag: a switch made
    /// while the provider left behind is still fetching must not make the new card say
    /// "Refreshing…" for a request that is not about it.
    @Published private(set) var refreshingProviders: Set<Provider> = []

    private var timer: Timer?
    private var refreshTasks: [Provider: Task<Void, Never>] = [:]
    private var costTasks: [Provider: Task<Void, Never>] = [:]
    private var pendingCostRefreshes: Set<Provider> = []
    private let historyStore: UsageHistoryStore
    private let recovery: QuotaRecoveryTracker
    private let settings: SettingsStore
    private var settingsObserver: AnyCancellable?
    private var providerObserver: AnyCancellable?
    /// One cooldown per provider, claimed by whichever path asked, so the minute after any
    /// refresh of that provider stays quiet. Switching back and forth buys no extra refreshes:
    /// each provider's own minute has to elapse before it is fetched again.
    private var cooldowns = ProviderRefreshCooldown()
    private let clock: () -> TimeInterval
    private let dateClock: () -> Date
    private let fetchState: (Provider, ClaudeRefreshInteraction) async -> ProviderState
    private let fetchCost: (Provider) async -> CostSnapshot?

    init(
        settings: SettingsStore,
        costService: CostService,
        clock: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
        dateClock: @escaping () -> Date = Date.init,
        fetchState: ((Provider, ClaudeRefreshInteraction) async -> ProviderState)? = nil,
        fetchCost: ((Provider) async -> CostSnapshot?)? = nil,
        historyStore: UsageHistoryStore? = nil,
        recoveryDefaults: UserDefaults = .standard
    ) {
        self.settings = settings
        self.historyStore = historyStore ?? UsageHistoryStore()
        self.recovery = QuotaRecoveryTracker(defaults: recoveryDefaults)
        self.clock = clock
        self.dateClock = dateClock
        self.fetchState = fetchState ?? { await Self.fetch($0, interaction: $1) }
        self.fetchCost = fetchCost ?? { await costService.refresh($0) }
    }

    func start() {
        self.refresh()
        self.rescheduleTimer()
        self.settingsObserver = self.settings.$refreshFrequency
            .removeDuplicates()
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.rescheduleTimer() }

        // The moment of the switch is the only thing that pulls the other provider into a
        // refresh, and it goes through that provider's cooldown like every other path.
        // SettingsStore is MainActor-isolated; consume the emitted provider synchronously so a
        // rapid switch back cannot leave a fetch queued behind a newer selection.
        self.providerObserver = self.settings.$menuBarProvider
            .removeDuplicates()
            .dropFirst()
            .sink { [weak self] provider in
                guard let self else { return }
                self.refresh(provider: provider)
            }
    }

    /// Rebuilt whenever the cadence changes; `.manual` leaves no timer at all.
    private func rescheduleTimer() {
        self.timer?.invalidate()
        self.timer = nil

        guard let interval = self.settings.refreshFrequency.seconds else { return }
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        // Common modes, so polling keeps running while a menu is open; the default mode alone
        // stops during menu tracking.
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        self.timer?.invalidate()
        self.timer = nil
        for task in self.refreshTasks.values { task.cancel() }
        self.refreshTasks = [:]
        for task in self.costTasks.values { task.cancel() }
        self.costTasks = [:]
        self.pendingCostRefreshes = []
        self.settingsObserver = nil
        self.providerObserver = nil
    }

    /// Refreshes the provider on screen. `force` only skips the local cooldown for an explicit
    /// user-initiated credential recovery already requested by the provider.
    func refresh(
        force: Bool = false,
        interaction: ClaudeRefreshInteraction = .automatic
    ) {
        self.refresh(
            provider: self.settings.menuBarProvider,
            force: force,
            interaction: interaction
        )
    }

    /// Whether this provider currently has a fetch in flight.
    func isRefreshing(_ provider: Provider) -> Bool {
        self.refreshingProviders.contains(provider)
    }

    private func refresh(
        provider: Provider,
        force: Bool = false,
        interaction: ClaudeRefreshInteraction = .automatic
    ) {
        // Coalesce: clicking the status item during a poll should not start a second round of
        // requests. Manual refreshes do not reschedule the independent polling timer.
        guard self.refreshTasks[provider] == nil else { return }
        // Only a user click on a known credential-recovery state can skip the local cooldown.
        // A server 429 remains authoritative, even for that click.
        let allowsRecoveryBypass = force && interaction == .userInitiated
            && self.displays[provider]?.canAttemptCredentialRecovery == true
        guard self.serverCooldownRemaining(for: provider) == 0 else { return }
        guard self.claimRefresh(for: provider, force: allowsRecoveryBypass, at: self.clock()) else { return }

        self.refreshingProviders.insert(provider)

        self.refreshTasks[provider] = Task { [weak self, historyStore, fetchState] in
            let state = await fetchState(provider, interaction)

            // Sampling the weekly window builds the history the pace model regresses over.
            // CodexBar records only Codex here; the model is provider-agnostic, so both are.
            var history: UsageHistoryDataset?
            if case let .loaded(snapshot) = state, let weekly = snapshot.weekly {
                history = await historyStore.record(provider: provider, window: weekly)
            }

            await MainActor.run {
                guard let self else { return }
                self.apply(state: state, to: provider)
                Self.log(provider: provider, state: state)
                if let history {
                    self.displays[provider, default: ProviderDisplay()].history = history
                }
                self.refreshingProviders.remove(provider)
                self.refreshTasks[provider] = nil
            }
        }

        self.refreshCosts(for: provider)
    }

    private static func fetch(
        _ provider: Provider,
        interaction: ClaudeRefreshInteraction
    ) async -> ProviderState {
        switch provider {
        case .codex: await CodexProvider.fetch()
        case .claude: await ClaudeProvider.fetch(interaction: interaction)
        }
    }

    /// Takes the local cooldown for this provider. A permitted recovery restarts it too.
    private func claimRefresh(for provider: Provider, force: Bool, at time: TimeInterval) -> Bool {
        guard !force else {
            self.cooldowns.recordRefresh(provider, at: time)
            return true
        }
        return self.cooldowns.claimRefresh(provider, at: time)
    }

    /// Log scanning runs on its own task: the first pass reads hundreds of megabytes and must not
    /// hold up the quota numbers, which are what the menu bar icon needs.
    private func refreshCosts(for provider: Provider, afterPricingChange: Bool = false) {
        guard self.costTasks[provider] == nil else {
            if afterPricingChange { self.pendingCostRefreshes.insert(provider) }
            return
        }

        self.displays[provider, default: ProviderDisplay()].localScanStatus = .scanning
        self.costTasks[provider] = Task { [weak self, fetchCost] in
            let scanned = await fetchCost(provider)
            await MainActor.run {
                guard let self else { return }
                if let scanned {
                    self.displays[provider, default: ProviderDisplay()].cost = scanned
                    self.displays[provider, default: ProviderDisplay()].localScanStatus =
                        .completed(self.dateClock())
                } else {
                    self.displays[provider, default: ProviderDisplay()].localScanStatus =
                        .failed("Local usage scan failed. Previous usage remains available.")
                }
                self.costTasks[provider] = nil
                if self.pendingCostRefreshes.remove(provider) != nil {
                    self.refreshCosts(for: provider)
                }
            }
        }
    }

    /// Price edits only affect local costs. Coalesce edits during a scan into one follow-up
    /// so its earlier snapshot cannot hide the result of saving new rates.
    func refreshCostsAfterPricingChange() {
        self.refreshCosts(for: self.settings.menuBarProvider, afterPricingChange: true)
    }

    /// Retries only the selected provider's local usage scan. This has no quota cooldown and
    /// shares the scan task with automatic and pricing-triggered work, so repeated clicks coalesce.
    func retryLocalUsage() {
        self.refreshCosts(for: self.settings.menuBarProvider)
    }

    /// Seconds until the next refresh of the provider on screen would actually run. The Refresh
    /// row counts this down instead of accepting clicks it would drop.
    func refreshCooldownRemaining() -> TimeInterval {
        self.cooldownRemaining(for: self.settings.menuBarProvider)
    }

    func cooldownRemaining(for provider: Provider) -> TimeInterval {
        max(
            self.cooldowns.remaining(provider, at: self.clock()),
            self.serverCooldownRemaining(for: provider)
        )
    }

    /// The same effective eligibility used by refresh(), expressed as a wall-clock date for UI.
    func retryEligibleAt(for provider: Provider) -> Date? {
        let remaining = self.cooldownRemaining(for: provider)
        return remaining > 0 ? self.dateClock().addingTimeInterval(remaining) : nil
    }

    func canRefresh(_ provider: Provider) -> Bool {
        guard !self.isRefreshing(provider) else { return false }
        if self.displays[provider]?.canAttemptCredentialRecovery == true {
            return self.serverCooldownRemaining(for: provider) == 0
        }
        return self.cooldownRemaining(for: provider) == 0
    }

    private func serverCooldownRemaining(for provider: Provider) -> TimeInterval {
        guard let deadline = self.displays[provider]?.retryDeadline else { return 0 }
        return max(0, deadline.timeIntervalSince(self.dateClock()))
    }

    /// Window resets that have not been shown yet. Consuming them arms the animation, so only the
    /// card that actually shows it may ask.
    func consumeCelebrations(for provider: Provider) -> [QuotaWindowKind: QuotaRecoveryEvent] {
        self.recovery.consumePending(for: provider)
    }

#if DEBUG
    func debugSetDisplay(_ display: ProviderDisplay, for provider: Provider) {
        self.displays[provider] = display
    }

    /// Starts the cooldown without the network round trip a real refresh would make, so the menu
    /// wiring can be verified headlessly.
    func debugRecordRefresh(at time: TimeInterval, provider: Provider? = nil) {
        self.cooldowns.recordRefresh(provider ?? self.settings.menuBarProvider, at: time)
    }
#endif

    /// A failed refresh keeps whatever snapshot we already had: showing yesterday's numbers with
    /// an error line beats blanking a working card because one request was rate-limited.
    private func apply(state: ProviderState, to provider: Provider) {
        var display = self.displays[provider] ?? ProviderDisplay()
        switch state {
        case let .signedOut(reason):
            display.snapshot = nil
            display.error = nil
            display.failure = nil
            display.signedOutReason = reason
            display.isSignedOut = true
            display.canAttemptCredentialRecovery = false
        case let .failed(reason):
            display.error = reason
            display.failure = ProviderFailure(kind: .refresh, reason: reason)
            display.signedOutReason = nil
            display.isSignedOut = false
            display.canAttemptCredentialRecovery = false
        case let .rateLimited(reason, retryAfter):
            display.error = reason
            display.failure = ProviderFailure(
                kind: .rateLimited,
                reason: reason,
                serverRetryAfter: retryAfter
            )
            display.signedOutReason = nil
            display.isSignedOut = false
            display.canAttemptCredentialRecovery = false
        case let .recoveryRequired(reason):
            display.error = reason
            display.failure = ProviderFailure(kind: .credentialRecovery, reason: reason)
            display.signedOutReason = nil
            display.isSignedOut = false
            display.canAttemptCredentialRecovery = true
        case let .loaded(snapshot):
            display.snapshot = snapshot
            display.error = nil
            display.failure = nil
            display.signedOutReason = nil
            display.isSignedOut = false
            display.canAttemptCredentialRecovery = false
            // Every reading of this provider, not just the ones the card is looking at: a window
            // that runs dry has to be noticed even when the menu has not been opened in hours.
            self.recovery.observe(snapshot: snapshot)
        }
        self.displays[provider] = display
    }

    private static func log(provider: Provider, state: ProviderState) {
        switch state {
        case let .signedOut(reason):
            Log.ui.info("\(provider.rawValue, privacy: .public) signed out: \(reason, privacy: .public)")
        case let .failed(reason):
            Log.ui.error("\(provider.rawValue, privacy: .public) refresh failed: \(reason, privacy: .public)")
        case let .rateLimited(reason, retryAfter):
            Log.ui.warning(
                "\(provider.rawValue, privacy: .public) rate-limited until \(retryAfter): \(reason, privacy: .public)"
            )
        case let .recoveryRequired(reason):
            Log.ui.warning("\(provider.rawValue, privacy: .public) recovery required: \(reason, privacy: .public)")
        case let .loaded(snapshot):
            let session = snapshot.session?.remainingPercent ?? -1
            let weekly = snapshot.weekly?.remainingPercent ?? -1
            Log.ui.debug("\(provider.rawValue, privacy: .public) session=\(session) weekly=\(weekly)")
        }
    }
}
