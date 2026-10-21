import AppKit
import QuotaBarCore
import SwiftUI

private struct MenuRefreshStateKey: EnvironmentKey {
    static let defaultValue = RefreshEligibility.Row.idle
}

extension EnvironmentValues {
    var menuRefreshState: RefreshEligibility.Row {
        get { self[MenuRefreshStateKey.self] }
        set { self[MenuRefreshStateKey.self] = newValue }
    }
}

@MainActor
final class MenuPopoverModel: ObservableObject {
    @Published var card: MenuCardView
    @Published var provider: Provider
    @Published var presentationID = UUID()
    @Published var refreshState = MenuRefreshStateKey.defaultValue
    @Published var showsRefresh = true
    @Published var contentHeight: CGFloat = 0
    @Published var maximumHeight: CGFloat = 700
    var measuredProvider: Provider?
    var onRefresh: () -> Void = {}
    var onSettings: () -> Void = {}
    var onQuit: () -> Void = {}
    var onClose: () -> Void = {}
    var onSizeChanged: () -> Void = {}

    init(card: MenuCardView, provider: Provider) {
        self.card = card
        self.provider = provider
    }
    var footerHeight: CGFloat { self.showsRefresh ? 85 : 61 }
    var viewportHeight: CGFloat { max(1, min(self.contentHeight, self.maximumHeight - self.footerHeight)) }
}

private struct MenuContentHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

/// How far the card has scrolled from its top.
private struct MenuScrollOffsetKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

struct MenuPopoverView: View {
    @ObservedObject var model: MenuPopoverModel
    @State private var scrollOffset: CGFloat = 0
    private static let scrollSpace = "menuScroll"

    var body: some View {
        VStack(spacing: 0) {
            ScrollView(.vertical) {
                self.model.card
                    .id(self.model.presentationID)
                    .frame(width: 280, alignment: .topLeading)
                    .fixedSize(horizontal: false, vertical: true)
                    .background {
                        GeometryReader { geometry in
                            Color.clear
                                .preference(key: MenuContentHeightKey.self, value: geometry.size.height)
                                .preference(
                                    key: MenuScrollOffsetKey.self,
                                    value: -geometry.frame(in: .named(Self.scrollSpace)).minY
                                )
                        }
                    }
            }
            .coordinateSpace(.named(Self.scrollSpace))
            .scrollBounceBehavior(.basedOnSize)
            .frame(width: 280, height: self.model.viewportHeight, alignment: .topLeading)
            // A card taller than the screen fades out at whichever edge still has more to show.
            .mask {
                ScrollEdgeFadeMask(
                    top: self.scrollOffset,
                    bottom: self.model.contentHeight - self.model.viewportHeight - self.scrollOffset
                )
            }
            .onPreferenceChange(MenuScrollOffsetKey.self) { offset in
                if abs(self.scrollOffset - offset) > 0.25 { self.scrollOffset = offset }
            }
            .onPreferenceChange(MenuContentHeightKey.self) { height in
                let rounded = height.rounded(.up)
                guard rounded > 0, abs(self.model.contentHeight - rounded) > 0.5 else { return }
                withTransaction(Transaction(animation: nil)) {
                    self.model.contentHeight = rounded
                    self.model.onSizeChanged()
                }
            }
            Divider()
            VStack(spacing: 0) {
                if self.model.showsRefresh {
                    MenuPopoverAction(
                        title: self.model.refreshState.title, symbol: "arrow.clockwise",
                        trailing: self.model.refreshState.trailingText ?? "⌘R",
                        isWorking: self.model.refreshState.isInProgress, action: self.model.onRefresh
                    )
                    .disabled(!self.model.refreshState.isEnabled)
                    .keyboardShortcut("r", modifiers: .command)
                }
                MenuPopoverAction(title: "Settings…", symbol: "gearshape", trailing: "⌘,", action: self.model.onSettings)
                    .keyboardShortcut(",", modifiers: .command)
                MenuPopoverAction(title: "Quit", symbol: "xmark.rectangle", trailing: "⌘Q", action: self.model.onQuit)
                    .keyboardShortcut("q", modifiers: .command)
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 6)
        }
        .frame(width: 280)
        .frame(maxHeight: .infinity, alignment: .top)
        .environment(\.menuRefreshState, self.model.refreshState)
        .onExitCommand(perform: self.model.onClose)
    }
}

private struct MenuPopoverAction: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.isEnabled) private var isEnabled
    let title: String
    let symbol: String
    let trailing: String
    var isWorking = false
    let action: () -> Void
    @State private var hovered = false
    @FocusState private var focused: Bool

    var body: some View {
        Button(action: self.action) {
            HStack(spacing: 8) {
                Image(systemName: self.symbol).frame(width: 15)
                if self.isWorking {
                    WorkingLabel(title: self.title)
                } else {
                    Text(self.title)
                }
                Spacer()
                Text(self.trailing).foregroundStyle(.secondary).accessibilityHidden(true)
            }
            .font(.system(size: 12))
            .padding(.horizontal, 8)
            .frame(height: 24)
            .contentShape(Rectangle())
        }
        .buttonStyle(ControlFeedbackStyle(pressScale: CardMotion.rowPressScale))
        .foregroundStyle(self.isEnabled ? .primary : .tertiary)
        .background(self.isEnabled && self.hovered ? Color.primary.opacity(0.06) : .clear,
                    in: RoundedRectangle(cornerRadius: 5))
        .animation(self.reduceMotion ? nil : .easeOut(duration: 0.10), value: self.isEnabled && self.hovered)
        .focused(self.$focused)
        .overlay {
            RoundedRectangle(cornerRadius: 5)
                .strokeBorder(Color.accentColor, lineWidth: 2)
                .opacity(self.isEnabled && self.focused ? 1 : 0)
                .allowsHitTesting(false)
        }
        .onHover { self.hovered = $0 }
        .accessibilityLabel(self.title)
    }
}
