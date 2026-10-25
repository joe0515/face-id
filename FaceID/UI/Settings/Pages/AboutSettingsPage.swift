//
//  AboutSettingsPage.swift
//  Face ID
//

import SwiftUI
import AppKit

struct AboutSettingsPage: View {
    @Bindable var updater: UpdaterController
    let environment: AppEnvironment

    /// Secret-tap state for revealing the Debug/Face Lab sidebar section —
    /// see `AppEnvironment.isDebugSectionRevealed`. A pause over a second
    /// resets the count, so this requires 5 *consecutive* taps.
    @State private var iconTapCount = 0
    @State private var lastTapDate: Date?
    private let requiredTapCount = 5
    private let tapResetInterval: TimeInterval = 1.0

    /// Drives which artwork the logo below uses, so it matches the Dock instead of
    /// freezing on one variant.
    @Environment(\.colorScheme) private var colorScheme

    /// The same two images `AppIconAppearanceController` swaps between — kept as a
    /// lookup rather than a third copy of the artwork.
    private var appIcon: NSImage {
        NSImage(named: colorScheme == .dark ? "AppIconDark" : "AppIconLight")
            ?? NSImage(systemSymbolName: "faceid", accessibilityDescription: nil)
            ?? NSImage()
    }

    private var versionString: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "1.0"
        let build = info?["CFBundleVersion"] as? String ?? "1"
        return "版本 \(short)（\(build)）"
    }

    var body: some View {
        VStack(spacing: 2) {
            Image(nsImage: appIcon)
                .resizable()
                // 96 rather than 80: the artwork sits inside Apple's icon grid at ~82%
                // of the canvas, so the frame has to grow for the mark itself to end up
                // the same size it was before the icon gained its margins.
                .frame(width: 96, height: 96)
                .padding(.top, 8)
                .padding(.bottom, 4)
                .contentShape(Rectangle())
                .onTapGesture(perform: handleIconTap)

            Text("Face ID")
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(SettingsMetrics.textPrimary)

            Text(versionString)
                .font(.system(size: 12))
                .foregroundStyle(SettingsMetrics.textSecondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.bottom, 16)

        SettingsGroup {
            SettingsActionRowContent(
                title: "检查更新",
                buttonTitle: "检查",
                isEnabled: updater.canCheckForUpdates
            ) {
                updater.checkForUpdates()
            }

            SettingsGroupDivider()

            SettingsRowContent(title: "自动检查更新") {
                FIDToggle(isOn: $updater.automaticallyChecksForUpdates)
            }

            SettingsGroupDivider()

            SettingsActionRowContent(
                title: "GitHub 项目主页",
                subtitle: "joe0515/face-id",
                buttonTitle: "打开"
            ) {
                if let url = URL(string: "https://github.com/joe0515/face-id") {
                    NSWorkspace.shared.open(url)
                }
            }

            SettingsGroupDivider()

            SettingsActionRowContent(
                title: "发送反馈",
                subtitle: "在 GitHub 上提交问题",
                buttonTitle: "发送"
            ) {
                if let url = URL(string: "https://github.com/joe0515/face-id/issues") {
                    NSWorkspace.shared.open(url)
                }
            }
        }
    }

    private func handleIconTap() {
        let now = Date()
        if let lastTapDate, now.timeIntervalSince(lastTapDate) > tapResetInterval {
            iconTapCount = 0
        }
        lastTapDate = now
        iconTapCount += 1
        guard iconTapCount >= requiredTapCount else { return }
        iconTapCount = 0
        environment.isDebugSectionRevealed = true
    }
}
