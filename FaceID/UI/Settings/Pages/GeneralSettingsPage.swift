//
//  GeneralSettingsPage.swift
//  Face ID
//

import OSLog
import SwiftUI

struct GeneralSettingsPage: View {
    @Bindable var coordinator: FaceUnlockCoordinator
    @Bindable private var settings = FIDSettings.shared

    @State private var launchAtLoginEnabled = LaunchAtLogin.isEnabled
    @State private var launchAtLoginError: String?
    /// Refreshed on `didChangeScreenParametersNotification` so the picker
    /// reflects displays connecting/disconnecting while Settings is open.
    @State private var screens: [NSScreen] = NSScreen.screens
    /// Refreshed when the app regains focus, so granting the permission in
    /// System Settings clears the prompt below without a relaunch.
    @State private var inputMonitoring = SpaceKeyMonitor.inputMonitoringAccess
    /// Result of the last diagnostics export — shown as a caption under the row.
    @State private var diagnosticsNote: String?

    private var needsInputMonitoring: Bool {
        settings.unlockTriggers.contains(.onSpace) && inputMonitoring != .granted
    }

    /// Dev-only: under Xcode the reading above is Xcode's permission, not
    /// Face ID's, so it's meaningless. See `SpaceKeyMonitor.isLaunchedByXcode`.
    private var hasInheritedXcodePermission: Bool {
        settings.unlockTriggers.contains(.onSpace) && SpaceKeyMonitor.isLaunchedByXcode
    }

    /// Copies the unlock-path trace somewhere the user can attach it to a bug report.
    private func exportDiagnostics() {
        guard let url = UnlockDiagnostics.logURL,
              FileManager.default.fileExists(atPath: url.path) else {
            diagnosticsNote = "暂无诊断记录 —— 还没有发生过唤醒或锁屏事件。"
            return
        }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "Face ID 诊断日志.txt"
        panel.begin { response in
            guard response == .OK, let destination = panel.url else { return }
            do {
                if FileManager.default.fileExists(atPath: destination.path) {
                    try FileManager.default.removeItem(at: destination)
                }
                try FileManager.default.copyItem(at: url, to: destination)
                diagnosticsNote = "已导出到 \(destination.path)"
            } catch {
                diagnosticsNote = "导出失败：\(error.localizedDescription)"
            }
        }
    }

    var body: some View {
        SettingsGroup {
            SettingsRowContent(title: "登录时启动") {
                FIDToggle(isOn: Binding(
                    get: { launchAtLoginEnabled },
                    set: { newValue in
                        launchAtLoginEnabled = newValue
                        do {
                            try LaunchAtLogin.setEnabled(newValue)
                            launchAtLoginError = nil
                        } catch {
                            launchAtLoginEnabled = !newValue
                            launchAtLoginError = error.localizedDescription
                        }
                    }
                ))
            }
            SettingsGroupDivider()
            SettingsRowContent(title: "启用整机解锁") {
                FIDToggle(isOn: $coordinator.isEnabled)
            }
            SettingsGroupDivider()
            UnlockTriggerPicker(selection: $settings.unlockTriggers, isEnabled: coordinator.isEnabled)
            SettingsGroupDivider()
            displayPicker()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)) { _ in
            screens = NSScreen.screens
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            inputMonitoring = SpaceKeyMonitor.inputMonitoringAccess
        }
        .onChange(of: settings.unlockTriggers) { oldValue, newValue in
            // Only prompt on the transition into selecting "On space".
            SpaceKeyMonitor.log.info("unlockTriggers changed: old=\(String(describing: oldValue), privacy: .public) new=\(String(describing: newValue), privacy: .public) state=\(String(describing: inputMonitoring), privacy: .public)")
            if newValue.contains(.onSpace), !oldValue.contains(.onSpace), inputMonitoring != .granted {
                SpaceKeyMonitor.requestInputMonitoringAccess()
                // tccd flips notDetermined -> denied just after the call
                // returns, so re-read on the next beat rather than inline.
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                    inputMonitoring = SpaceKeyMonitor.inputMonitoringAccess
                }
            }
        }
        if let launchAtLoginError {
            SettingsCaption(text: launchAtLoginError)
        }
        if hasInheritedXcodePermission {
            SettingsCaption(text: "当前从 Xcode 运行：权限判定会算在 Xcode 头上而不是 Face ID，所以这个读数没有意义。请单独打开 Face ID.app 查看真实状态。")
        } else if needsInputMonitoring {
            inputMonitoringNotice()
        }

        VStack(alignment: .leading, spacing: 8) {
            SettingsSectionTitle(text: "行为")
            SettingsGroup {
                SettingsRowContent(title: "悬停刘海时重试") {
                    FIDToggle(isOn: $settings.retryOnHover)
                }
                SettingsGroupDivider()
                SettingsRowContent(title: "失败后自动重试一次") {
                    FIDToggle(isOn: $settings.autoRetryOnce)
                }
                SettingsGroupDivider()
                SettingsRowContent(title: "触觉反馈") {
                    FIDToggle(isOn: $settings.hapticFeedbackEnabled)
                }
                SettingsGroupDivider()
                SettingsSteppedSliderRowContent(
                    title: "人脸检测时长",
                    valueLabel: "\(settings.faceDetectionSeconds) 秒",
                    index: Binding(
                        get: { Double(settings.faceDetectionSeconds - FIDSettings.faceDetectionRange.lowerBound) },
                        set: { settings.faceDetectionSeconds = FIDSettings.faceDetectionRange.lowerBound + Int($0.rounded()) }
                    ),
                    stopCount: FIDSettings.faceDetectionRange.count
                )
            }
        }

        VStack(alignment: .leading, spacing: 8) {
            SettingsSectionTitle(text: "诊断")
            SettingsGroup {
                SettingsRowContent(
                    title: "导出诊断日志",
                    subtitle: "记录每次唤醒/锁屏事件走到了哪一步。遇到「打开屏幕却拉不起人脸认证」时，导出来发我定位。"
                ) {
                    Button("导出…") { exportDiagnostics() }
                        .buttonStyle(.plain)
                        .foregroundStyle(FIDTheme.accent)
                }
            }
            if let diagnosticsNote {
                SettingsCaption(text: diagnosticsNote)
            }
        }

        VStack(alignment: .leading, spacing: 8) {
            SettingsSectionTitle(text: "动画")
            SettingsGroup {
                SettingsRowContent(title: "显示动画") {
                    FIDToggle(isOn: $settings.showUnlockAnimation)
                }
                SettingsGroupDivider()
                UnlockAnimationPicker(
                    selection: $settings.unlockAnimationStyle,
                    isEnabled: settings.showUnlockAnimation
                )
            }
        }
    }

    /// Shown while "On space" is selected but Input Monitoring isn't granted.
    private func inputMonitoringNotice() -> some View {
        VStack(alignment: .leading, spacing: 6) {
            SettingsCaption(text: "「按空格键」需要直接读取键盘才能在锁屏上识别空格键，这需要辅助功能权限（也就是 Face ID 输入密码用的同一个权限）。请在「隐私与安全性 → 辅助功能」中打开 Face ID，然后退出并重新打开 Face ID。")
            Button("打开辅助功能设置") {
                // Covers the rare install with no Accessibility grant at all.
                SpaceKeyMonitor.requestInputMonitoringAccess()
                openSystemSettings(pane: "Privacy_Accessibility")
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                    inputMonitoring = SpaceKeyMonitor.inputMonitoringAccess
                }
            }
            .buttonStyle(.plain)
            .font(.system(size: 12))
            .foregroundStyle(FIDTheme.accent)
        }
    }

    private func openSystemSettings(pane: String) {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") else { return }
        NSWorkspace.shared.open(url)
    }

    private func displayPicker() -> some View {
        SettingsRowContent(title: "显示在") {
            SettingsMenuPickerPill(label: displayLabel) {
                Button("主显示器") {
                    settings.preferredDisplayID = nil
                    settings.preferredDisplayName = nil
                }
                ForEach(screens.compactMap(NamedScreen.init), id: \.id) { screen in
                    Button(screen.name) {
                        settings.preferredDisplayID = screen.id
                        settings.preferredDisplayName = screen.name
                    }
                }
            }
        }
    }

    /// A connected screen with its stable ID already unwrapped, so the
    /// picker's `ForEach` doesn't need to filter/force-unwrap inline.
    private struct NamedScreen {
        let id: String
        let name: String

        init?(_ screen: NSScreen) {
            guard let id = screen.stableDisplayID else { return nil }
            self.id = id
            self.name = screen.localizedName
        }
    }

    private var displayLabel: String {
        guard let targetID = settings.preferredDisplayID else { return "主显示器" }
        if let connected = screens.first(where: { $0.stableDisplayID == targetID }) {
            return connected.localizedName
        }
        // Picked, but not currently connected — say so rather than showing
        // a bare ID or falling back to another display's name.
        guard let name = settings.preferredDisplayName else { return "所选显示器（已断开）" }
        return "\(name)（已断开）"
    }
}
