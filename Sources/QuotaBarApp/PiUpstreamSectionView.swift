import QuotaBarCore
import SwiftUI

/// Names for the upstream providers Pi logs, which it writes as lowercase identifiers.
enum UpstreamProviderName {
    private static let known = [
        "anthropic": "Anthropic",
        "openai": "OpenAI",
        "openai-codex": "OpenAI Codex",
        "azure-openai-responses": "Azure OpenAI",
        "google": "Google",
        "google-vertex": "Vertex AI",
        "google-gemini-cli": "Gemini CLI",
        "amazon-bedrock": "Bedrock",
        "github-copilot": "GitHub Copilot",
        "openrouter": "OpenRouter",
        "vercel-ai-gateway": "Vercel AI Gateway",
        "xai": "xAI",
        "zai": "Z.ai",
        "groq": "Groq",
        "cerebras": "Cerebras",
        "mistral": "Mistral",
        "deepseek": "DeepSeek",
        "minimax": "MiniMax",
        "huggingface": "Hugging Face",
    ]

    static func display(_ identifier: String) -> String {
        self.known[identifier.lowercased()]
            ?? identifier.split(separator: "-").map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined(separator: " ")
    }
}

/// Where Pi's usage in the window went, by upstream provider: one bar split in proportion, then
/// a row per provider. One hue at stepped strengths, so rank reads without a second palette.
struct PiUpstreamSectionView: View {
    let snapshot: CostSnapshot
    let labelMode: CostChartLabelMode

    struct Share: Equatable, Identifiable {
        let id: String
        let name: String
        var tokens: Int
        var costUSD: Double
        var hasUnpricedUsage: Bool
    }

    private static let visibleRows = 4
    private static let strengths: [Double] = [1, 0.7, 0.46, 0.3, 0.18]

    /// Providers ranked by the chosen unit, with everything past the visible rows folded into one.
    static func shares(of snapshot: CostSnapshot, by mode: CostChartLabelMode) -> [Share] {
        var totals: [String: Share] = [:]
        for day in snapshot.days {
            for (key, usage) in day.byModel {
                let id = key.upstreamProvider ?? ""
                var share = totals[id] ?? Share(
                    id: id, name: id.isEmpty ? "Unattributed" : UpstreamProviderName.display(id),
                    tokens: 0, costUSD: 0, hasUnpricedUsage: false
                )
                share.tokens += usage.tokens.total
                share.costUSD += usage.costUSD ?? 0
                share.hasUnpricedUsage = share.hasUnpricedUsage || usage.costUSD == nil
                totals[id] = share
            }
        }
        let ranked = totals.values.sorted {
            let (lhs, rhs) = (Self.value($0, mode), Self.value($1, mode))
            return lhs == rhs ? $0.name < $1.name : lhs > rhs
        }
        guard ranked.count > Self.visibleRows + 1 else { return ranked }
        let rest = ranked.dropFirst(Self.visibleRows)
        return ranked.prefix(Self.visibleRows) + [Share(
            id: "\u{0}rest", name: "\(rest.count) more",
            tokens: rest.reduce(0) { $0 + $1.tokens },
            costUSD: rest.reduce(0) { $0 + $1.costUSD },
            hasUnpricedUsage: rest.contains(where: \.hasUnpricedUsage)
        )]
    }

    private static func value(_ share: Share, _ mode: CostChartLabelMode) -> Double {
        mode == .tokens ? Double(share.tokens) : share.costUSD
    }

    var body: some View {
        let shares = Self.shares(of: self.snapshot, by: self.labelMode)
        let total = shares.reduce(0) { $0 + Self.value($1, self.labelMode) }
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text("Providers")
                    .font(QuotaHeadline.font)
                Spacer(minLength: 8)
                Text("Last 30 days")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            self.bar(shares, total: total)
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(shares.enumerated()), id: \.element.id) { index, share in
                    self.row(share, strength: Self.strength(index))
                }
            }
        }
    }

    private static func strength(_ index: Int) -> Double {
        self.strengths[min(index, self.strengths.count - 1)]
    }

    private func bar(_ shares: [Share], total: Double) -> some View {
        GeometryReader { geometry in
            let gaps = CGFloat(max(0, shares.count - 1))
            let width = max(0, geometry.size.width - gaps)
            HStack(spacing: 1) {
                ForEach(Array(shares.enumerated()), id: \.element.id) { index, share in
                    Rectangle()
                        .fill(Theme.accent(tab: .pi).opacity(Self.strength(index)))
                        .frame(width: total > 0 ? max(2, width * Self.value(share, self.labelMode) / total) : 0)
                }
            }
            .frame(width: geometry.size.width, alignment: .leading)
            .background(Theme.progressTrack)
            .clipShape(Capsule())
        }
        .frame(height: 6)
        .accessibilityHidden(true)
    }

    private func row(_ share: Share, strength: Double) -> some View {
        let amount = share.costUSD > 0 || !share.hasUnpricedUsage ? Formatters.cost(share.costUSD) : "No price"
        let tokens = Formatters.tokens(share.tokens)
        let showsCost = self.labelMode == .cost
        return HStack(spacing: 6) {
            RoundedRectangle(cornerRadius: 1.5)
                .fill(Theme.accent(tab: .pi).opacity(strength))
                .frame(width: 6, height: 6)
            Text(share.name)
                .truncationMode(.tail)
            Spacer(minLength: 4)
            Text(showsCost ? amount : tokens)
                .layoutPriority(1)
            Text(showsCost ? tokens : amount)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .frame(minWidth: 34, alignment: .trailing)
                .layoutPriority(1)
        }
        .font(.system(size: 11))
        .monospacedDigit()
        .lineLimit(1)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(share.name)
        .accessibilityValue("\(share.tokens) tokens, \(amount)")
    }
}
