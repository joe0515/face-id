//
//  SettingsWindowView.swift
//  Face ID
//
//  Root layout: one `.sidebar` material behind the whole window, the
//  selected page scrolling beneath a transparent header (traffic lights and
//  the session lock button) and a floating tab bar pinned to the bottom.
//

import SwiftUI

/// A closure `onPreferenceChange` can actually consume — that API requires
/// `Value: Equatable`, which a bare closure can never be. Equality is by
/// identity (a fresh `id` per instance), so this is deliberately never
/// equal to a previous instance.
struct HeaderAction: Equatable {
    private let id = UUID()
    let perform: () -> Void

    static func == (lhs: HeaderAction, rhs: HeaderAction) -> Bool { lhs.id == rhs.id }
}

/// Lets one page (today, only Camera's "Refresh camera list") publish a
/// trailing action into the shared header without the header needing
/// to know that page's state. Switching away resolves back to `defaultValue`.
struct HeaderTrailingActionKey: PreferenceKey {
    static var defaultValue: HeaderAction? { nil }
    static func reduce(value: inout HeaderAction?, nextValue: () -> HeaderAction?) {
        value = nextValue() ?? value
    }
}

struct SettingsWindowView: View {
    let environment: AppEnvironment
    @State private var selection: SettingsTab = .general
    @State private var headerTrailingAction: HeaderAction?
    @Environment(\.dismissWindow) private var dismissWindow

    /// Defense-in-depth, not the primary gate: Settings is `.suppressed` at
    /// launch and `AppDelegate.revealSettingsWindow()` refuses to open it
    /// while onboarding is incomplete. A real user should never hit this
    /// branch, only a blank frame before `dismissWindow` closes it.
    var body: some View {
        if FIDSettings.shared.hasCompletedOnboarding {
            settingsContent
        } else {
            Color.clear
                .onAppear { dismissWindow(id: "settings") }
        }
    }

    private var settingsContent: some View {
        ZStack {
            VisualEffectView()
            SettingsMetrics.windowTintColor
            contentPage
        }
        // No `.clipShape`, manual stroke, or `.shadow` on the outer window —
        // deliberately: the window keeps its native background (see
        // WindowConfiguringView), so AppKit masks it to the real macOS
        // corner and draws its own edge highlight and shadow for free.
        //
        // Fills whatever size the window is (set once by
        // WindowConfiguringView) — a fixed size here combined with
        // content-size resizability made SwiftUI keep re-adding a titlebar
        // band to the window height.
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .ignoresSafeArea()
        .background(WindowConfigurator())
        // Cascades to every native control so nothing falls back to the
        // system accent. Only takes effect because the window can become
        // key; see WindowConfiguringView.configure.
        .tint(FIDTheme.accent)
        // `Window` is a singleton scene — closing it only orders the
        // NSWindow out, keeping `@State` alive, so without this `selection`
        // would remember the last tab instead of resetting to General.
        .onDisappear { selection = .general }
    }

    /// The header and tab bar float over the scroll content as overlays so
    /// scrolled rows pass underneath them rather than being pushed aside.
    private var contentPage: some View {
        ScrollView(.vertical, showsIndicators: false) {
            pageBody
                .padding(.horizontal, SettingsMetrics.contentHorizontalPadding)
                .padding(.top, SettingsMetrics.headerHeight + 4)
                .padding(.bottom, SettingsMetrics.pageBottomInset)
                // Without an explicit top alignment the scroll view
                // centers short pages vertically, leaving a large gap
                // between the header and the first row.
                .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .overlay(alignment: .top) {
            // Blur first, header content on top — so it fades whatever
            // scrolls beneath both without ever softening the buttons
            // themselves.
            ZStack(alignment: .top) {
                ProgressiveHeaderBlur(height: SettingsMetrics.headerBlurHeight)
                header
            }
        }
        .overlay(alignment: .bottom) {
            SettingsTabBar(
                selection: $selection,
                isDebugSectionRevealed: environment.isDebugSectionRevealed
            )
            .padding(.bottom, SettingsMetrics.tabBarBottomInset)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onPreferenceChange(HeaderTrailingActionKey.self) { headerTrailingAction = $0 }
    }

    /// Leading side stays empty — the window's real traffic lights are drawn
    /// there by AppKit (see WindowConfiguringView). No background of its
    /// own; `ProgressiveHeaderBlur` sits behind it in `contentPage`.
    private var header: some View {
        HStack(spacing: 8) {
            Spacer()

            if let headerTrailingAction {
                Button(action: headerTrailingAction.perform) {
                    Image(systemName: "arrow.trianglehead.clockwise.rotate.90")
                        .font(.system(size: 13))
                        .foregroundStyle(SettingsMetrics.textPrimary)
                        .frame(width: SettingsMetrics.headerButtonHeight, height: SettingsMetrics.headerButtonHeight)
                        .background(Circle().fill(SettingsMetrics.rowColor))
                        .overlay(
                            Circle()
                                .strokeBorder(SettingsMetrics.rowBorder, lineWidth: SettingsMetrics.rowBorderWidth)
                        )
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .help("刷新摄像头列表")
            }

            SessionLockButton(pocController: environment.pocController)
        }
        .padding(.horizontal, SettingsMetrics.contentHorizontalPadding)
        .frame(height: SettingsMetrics.headerHeight)
    }

    @ViewBuilder
    private var pageBody: some View {
        VStack(alignment: .leading, spacing: SettingsMetrics.rowSpacing) {
            switch selection {
            case .general:
                GeneralSettingsPage(
                    coordinator: environment.faceUnlockCoordinator,
                    pocController: environment.pocController
                )
            case .yourFace:
                YourFaceSettingsPage(environment: environment)
            case .password:
                PasswordSettingsPage(pocController: environment.pocController)
            case .lockedApps:
                LockedAppsSettingsPage(
                    coordinator: environment.appUnlockCoordinator,
                    pocController: environment.pocController
                )
            case .camera:
                CameraSettingsPage(pocController: environment.pocController)
            case .recognition:
                RecognitionSettingsPage(
                    coordinator: environment.faceUnlockCoordinator,
                    pocController: environment.pocController
                )
            case .about:
                AboutSettingsPage(updater: environment.updater, environment: environment)
            case .debugFaceLab:
                FaceLabView(controller: environment.faceLabController)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
