import QuotaBarCore
import Combine
import Foundation

/// Owns provider state and the refresh schedule. Polling, opening the menu, and the Refresh row
/// refresh only the displayed provider. Switching providers refreshes the newly selected one.
/// New third-party rates, and turning them on or off, refresh local costs independently of
/// quota requests.
@MainActor
final class UsageStore: ObservableObject {
    @Published private(set) var displays: [Provider: ProviderDisplay] = [:]
    /// Which providers have a fetch in flight. Per provider rather than one flag: a switch made
    /// while the provider left behind is still fetching must not make the new card say
    /// "Refreshing…" for a request that is not about it.
    @Published private(set) var refreshingProviders: Set<Provider> = []
    /// Counts finished local usage scans, for views that show what a scan recorded.
    @Published private(set) var finishedLocalScans = 0

    /// Keeps other machines' logs mirrored for the scans below to read.
    private(set) lazy var remoteSync = RemoteSyncModel(
        settings: self.settings,
        mirror: self.remoteLogMirror,
        didSync: { [weak self] in self?.refreshAllLocalUsageAfterChange() },
        readUsage: { [costService = self.costService] hosts in
            try? CostUsageReader.remoteUsage(
                hosts: hosts,
                remoteLogs: costService.remoteLogsURL,
                databaseURL: costService.databaseURL
            )
        }
    )

    private var timer: Timer?
    private var refreshTasks: [Provider: Task<Void, Never>] = [:]
    private var costTasks: [Provider: Task<Void, Never>] = [:]
    private var pendingCostRefreshes: Set<Provider> = []
    private let historyStore: UsageHistoryStore
    private let recovery: QuotaRecoveryTracker
    private let settings: SettingsStore
    private var settingsObserver: AnyCancellable?
    private var providerObserver: AnyCancellable?
    private var modelsDevObserver: AnyCancellable?
    /// The models.dev download in flight, so cost refreshes started meanwhile do not queue more.
    private var thirdPartyRatesTask: Task<Void, Never>?
    /// Whether each provider may be refreshed now, claimed by whichever path asked.
    private var eligibility = RefreshEligibility()
    private let clock: () -> TimeInterval
    private let dateClock: () -> Date
    private let fetchState: (Provider, ClaudeRefreshInteraction) async -> ProviderState
    private let fetchCost: (Provider) async -> CostSnapshot?
    /// Downloads models.dev when it is due; true when the rates changed.
    private let updateThirdPartyRates: () async -> Bool
    private let invalidatePricing: () async -> Void
    private let remoteLogMirror: RemoteLogMirror
    /// The cost service every local scan goes through.
    let costService: CostService

    init(
        settings: SettingsStore,
        costService: CostService,
        clock: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
        dateClock: @escaping () -> Date = Date.init,
        fetchState: ((Provider, ClaudeRefreshInteraction) async -> ProviderState)? = nil,
        fetchCost: ((Provider) async -> CostSnapshot?)? = nil,
        updateThirdPartyRates: (() async -> Bool)? = nil,
        historyStore: UsageHistoryStore? = nil,
        recoveryDefaults: UserDefaults = .standard
    ) {
        self.settings = settings
        self.costService = costService
        self.historyStore = historyStore ?? UsageHistoryStore()
        self.recovery = QuotaRecoveryTracker(defaults: recoveryDefaults)
        self.clock = clock
        self.dateClock = dateClock
        self.fetchState = fetchState ?? { await Self.fetch($0, interaction: $1) }
        self.fetchCost = fetchCost ?? { await costService.refresh($0) }
        self.updateThirdPartyRates = updateThirdPartyRates ?? { await costService.updateThirdPartyRates() }
        self.invalidatePricing = { await costService.invalidatePricing() }
        self.remoteLogMirror = RemoteLogMirror(root: costService.remoteLogsURL)
    }

    func start() {
        self.refresh()
        self.rescheduleTimer()
        self.remoteSync.start()
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

        // Turning models.dev off unprices third-party usage at once; turning it on prices it from
        // the cache and downloads whatever is due.
        self.modelsDevObserver = self.settings.$modelsDevPricing
            .removeDuplicates()
            .dropFirst()
            .sink { [weak self] enabled in
                guard let self else { return }
                if !enabled {
                    self.thirdPartyRatesTask?.cancel()
                    self.thirdPartyRatesTask = nil
                }
                Task { @MainActor in
                    await self.invalidatePricing()
                    self.refreshCostsAfterPricingChange()
                }
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
        // Lets the system batch this wakeup with others. Polling has no exact deadline.
        timer.tolerance = interval / 10
        // Common modes, so polling keeps running while a menu is open; the default mode alone
        // stops during menu tracking.
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        self.remoteSync.stop()
        self.timer?.invalidate()
        self.timer = nil
        for task in self.refreshTasks.values { task.cancel() }
        self.refreshTasks = [:]
        for task in self.costTasks.values { task.cancel() }
        self.costTasks = [:]
        self.pendingCostRefreshes = []
        self.thirdPartyRatesTask?.cancel()
        self.thirdPartyRatesTask = nil
        self.settingsObserver = nil
        self.providerObserver = nil
        self.modelsDevObserver = nil
    }

    /// Refreshes the provider on screen when `RefreshEligibility` lets `trigger` through.
    func refresh(trigger: RefreshEligibility.Trigger = .automatic) {
        self.refresh(provider: self.settings.menuBarProvider, trigger: trigger)
    }

    /// Whether this provider currently has a fetch in flight.
    func isRefreshing(_ provider: Provider) -> Bool {
        self.refreshingProviders.contains(provider)
    }

    private func refresh(provider: Provider, trigger: RefreshEligibility.Trigger = .automatic) {
        // Coalesce: clicking the status item during a poll should not start a second round of
        // requests. Manual refreshes do not reschedule the independent polling timer.
        guard self.refreshTasks[provider] == nil,
              self.eligibility.claim(
                  provider,
                  by: trigger,
                  given: self.conditions(for: provider),
                  uptime: self.clock(),
                  now: self.dateClock()
              ) else { return }
        let interaction: ClaudeRefreshInteraction = trigger == .user ? .userInitiated : .automatic

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
                self.apply(state: state, to: provider, history: history)
                Self.log(provider: provider, state: state)
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

    /// Log scanning runs on its own task: the first pass reads hundreds of megabytes and must not
    /// hold up the quota numbers, which are what the menu bar icon needs. Utility priority lets
    /// that multi-second pass yield the performance cores to whatever the user is doing.
    private func refreshCosts(for provider: Provider, repeatingRunningScan: Bool = false) {
        self.updateThirdPartyRatesIfDue()
        guard self.costTasks[provider] == nil else {
            if repeatingRunningScan { self.pendingCostRefreshes.insert(provider) }
            return
        }

        self.displays[provider, default: ProviderDisplay()].localScanStatus = .scanning
        self.costTasks[provider] = Task(priority: .utility) { [weak self, fetchCost] in
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
                self.finishedLocalScans += 1
                if self.pendingCostRefreshes.remove(provider) != nil {
                    self.refreshCosts(for: provider)
                }
            }
        }
    }

    /// New rates only affect local costs. Coalesce changes during a scan into one follow-up
    /// so its earlier snapshot cannot hide the result of the new rates.
    func refreshCostsAfterPricingChange() {
        self.refreshCosts(for: self.settings.menuBarProvider, repeatingRunningScan: true)
    }

    /// Newly mirrored logs and imported usage need a scan that starts after them, so a scan
    /// already running does not stand in for this one.
    func refreshAllLocalUsageAfterChange() {
        for provider in Provider.allCases { self.refreshCosts(for: provider, repeatingRunningScan: true) }
    }

    /// Checks models.dev alongside a cost refresh without holding the scan up. The service
    /// decides whether a download is due, so this is cheap to call on every refresh.
    private func updateThirdPartyRatesIfDue() {
        guard self.thirdPartyRatesTask == nil else { return }
        self.thirdPartyRatesTask = Task(priority: .utility) { [weak self, updateThirdPartyRates] in
            let changed = await updateThirdPartyRates()
            await MainActor.run {
                guard let self else { return }
                self.thirdPartyRatesTask = nil
                if changed { self.refreshCostsAfterPricingChange() }
            }
        }
    }

    /// Retries only the selected provider's local usage scan. This has no quota cooldown and
    /// shares the scan task with automatic and pricing-triggered work, so repeated clicks coalesce.
    func retryLocalUsage() {
        self.refreshCosts(for: self.settings.menuBarProvider)
    }

    /// Scans every provider's local usage, for the usage window, which reports all sources at
    /// once. Each scan shares its provider's task with every other path, so calls coalesce.
    func refreshAllLocalUsage() {
        for provider in Provider.allCases { self.refreshCosts(for: provider) }
    }

    func cooldownRemaining(for provider: Provider) -> TimeInterval {
        self.eligibility.remaining(provider, given: self.conditions(for: provider),
                                   uptime: self.clock(), now: self.dateClock())
    }

    /// The same effective eligibility used by refresh(), expressed as a wall-clock date for UI.
    func retryEligibleAt(for provider: Provider) -> Date? {
        let remaining = self.cooldownRemaining(for: provider)
        return remaining > 0 ? self.dateClock().addingTimeInterval(remaining) : nil
    }

    /// Whether a user click on the Refresh row would start a refresh now.
    func canRefresh(_ provider: Provider) -> Bool {
        self.refreshRow(for: provider).isEnabled
    }

    /// What the menu's Refresh row shows for this provider right now.
    func refreshRow(for provider: Provider) -> RefreshEligibility.Row {
        self.eligibility.row(provider, given: self.conditions(for: provider),
                             uptime: self.clock(), now: self.dateClock())
    }

    private func conditions(for provider: Provider) -> RefreshEligibility.Conditions {
        let display = self.displays[provider] ?? ProviderDisplay()
        return RefreshEligibility.Conditions(
            isRefreshing: self.isRefreshing(provider),
            serverRetryAfter: display.retryDeadline,
            allowsCredentialRecovery: display.canAttemptCredentialRecovery,
            isSignedOut: display.isSignedOut
        )
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
        self.eligibility.recordRefresh(provider ?? self.settings.menuBarProvider, uptime: time)
    }
#endif

    /// A failed refresh keeps whatever snapshot we already had: showing yesterday's numbers with
    /// an error line beats blanking a working card because one request was rate-limited.
    private func apply(state: ProviderState, to provider: Provider, history: UsageHistoryDataset? = nil) {
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
            display.pace.observe(snapshot, history: history)
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
