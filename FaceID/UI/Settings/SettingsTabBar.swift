//
//  SettingsTabBar.swift
//  Face ID
//
//  Floating pill tab bar pinned to the bottom of the Settings window. The
//  selected tab sits on its own highlight pill, which slides between tabs
//  and widens to show that tab's title.
//

import SwiftUI
private struct TabFramePreferenceKey: PreferenceKey {
    static var defaultValue: [SettingsTab: CGRect] = [:]
    static func reduce(value: inout [SettingsTab: CGRect], nextValue: () -> [SettingsTab: CGRect]) {
        value.merge(nextValue()) { _, new in new }
    }
}

struct SettingsTabBar: View {
    @Binding var selection: SettingsTab
    /// Whether the Face Lab tab should render — see
    /// `AppEnvironment.isDebugSectionRevealed`. This view only reflects it.
    let isDebugSectionRevealed: Bool

    /// Every visible tab's measured frame, keyed by tab — read back via
    /// `TabFramePreferenceKey` from each item's own `GeometryReader`.
    @State private var tabFrames: [SettingsTab: CGRect] = [:]

    private static let coordinateSpace = "SettingsTabBar"

    var body: some View {
        ZStack(alignment: .topLeading) {
            if let frame = tabFrames[selection] {
                Capsule()
                    .fill(SettingsMetrics.selectedPillColor)
                    .overlay(
                        Capsule()
                            .strokeBorder(SettingsMetrics.selectedPillBorder, lineWidth: 1)
                    )
                    .frame(width: frame.width, height: frame.height)
                    .offset(x: frame.minX, y: frame.minY)
                    .transition(.opacity)
            }

            HStack(spacing: 0) {
                ForEach(SettingsTab.visibleTabs(includingDebug: isDebugSectionRevealed)) { tab in
                    item(tab)
                }
            }
        }
        .coordinateSpace(name: Self.coordinateSpace)
        .padding(.horizontal, SettingsMetrics.tabBarHorizontalPadding)
        .frame(height: SettingsMetrics.tabBarHeight)
        .background {
            Capsule()
                .fill(.regularMaterial)
            Capsule()
                .fill(SettingsMetrics.tabBarTint)
        }
        .overlay(
            Capsule()
                .strokeBorder(SettingsMetrics.tabBarBorder, lineWidth: 1)
        )
        .onPreferenceChange(TabFramePreferenceKey.self) { frames in
            withAnimation(SettingsMetrics.tabSelectionAnimation) {
                tabFrames = frames
            }
        }
    }

    private func item(_ tab: SettingsTab) -> some View {
        let isSelected = selection == tab
        return Button {
            withAnimation(SettingsMetrics.tabSelectionAnimation) {
                selection = tab
            }
        } label: {
            HStack(spacing: 7) {
                SettingsTabGlyph(icon: tab.icon)
                if isSelected {
                    Text(tab.title)
                        .font(SettingsMetrics.tabTitleFont)
                        .lineLimit(1)
                        .fixedSize()
                        .transition(.tabLabelReveal)
                }
            }
            .foregroundStyle(SettingsMetrics.textPrimary)
            .padding(.horizontal, isSelected
                ? SettingsMetrics.selectedTabItemHorizontalPadding
                : SettingsMetrics.tabItemHorizontalPadding)
            .frame(height: SettingsMetrics.tabItemHeight)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .background(
            GeometryReader { proxy in
                Color.clear.preference(
                    key: TabFramePreferenceKey.self,
                    value: [tab: proxy.frame(in: .named(Self.coordinateSpace))]
                )
            }
        )
        .help(tab.title)
        .accessibilityLabel(tab.title)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// A tab's bare glyph — an SF Symbol or template asset, no badge behind it.
private struct SettingsTabGlyph: View {
    let icon: SettingsTabIcon

    var body: some View {
        Group {
            switch icon {
            case .system(let name):
                Image(systemName: name)
                    .font(.system(size: SettingsMetrics.tabGlyphSize, weight: .medium))
            case .asset(let name):
                Image(name)
                    .renderingMode(.template)
                    .resizable()
                    .scaledToFit()
                    .frame(width: SettingsMetrics.tabGlyphSize + 1, height: SettingsMetrics.tabGlyphSize + 1)
                    .offset(y: 1)
            }
        }
        // Fixed box so glyphs of different widths space evenly along the bar.
        .frame(width: SettingsMetrics.tabGlyphSize + 4, height: SettingsMetrics.tabGlyphSize + 4)
    }
}

/// A tab label's entrance/exit: it reads as unfurling from, and collapsing
/// back into, the icon beside it — sliding along that edge while fading and
/// blurring.
private struct TabLabelRevealModifier: ViewModifier {
    /// 1 = fully shown (identity); 0 = collapsed into the icon (active).
    var progress: CGFloat

    func body(content: Content) -> some View {
        content
            .opacity(progress)
            .blur(radius: (1 - progress) * SettingsMetrics.tabLabelRevealBlur)
            .offset(x: (1 - progress) * -SettingsMetrics.tabLabelRevealOffset)
    }
}

private extension AnyTransition {
    /// One modifier transition (not `.asymmetric`) so insertion runs
    /// active→identity and removal runs identity→active automatically.
    static var tabLabelReveal: AnyTransition {
        .modifier(
            active: TabLabelRevealModifier(progress: 0),
            identity: TabLabelRevealModifier(progress: 1)
        )
    }
}
