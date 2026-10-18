//
//  LockedAppsSettingsPage.swift
//  Face ID
//
//  The app-locking page: the master switch, how a locked app is presented, which apps
//  are locked, how long an unlock lasts, and the two daily schedule windows.
//
//  Every value here is read back through the same types the enforcement path uses —
//  `LockedAppsStore`, `AppLockSessionManager`, `AppScheduleManager`, `WindowShieldManager`
//  — so the page can't drift from what's actually enforced. Nothing is mirrored into
//  `FIDSettings`, which is the whole-machine config.
//

import AppKit
import SwiftUI

struct LockedAppsSettingsPage: View {
    @Bindable var coordinator: AppUnlockCoordinator
    @Bindable var pocController: POCController
    @Bindable private var store = LockedAppsStore.shared
    @Bindable private var schedule = AppScheduleManager.shared

    /// `AppLockSessionManager`'s timeout and timer mode are computed over
    /// `UserDefaults`, so Observation can't see them change — these mirror them and are
    /// the single place the page writes back through.
    @State private var sessionWindow: SessionWindow = .from(AppLockSessionManager.shared.sessionTimeout)
    @State private var sessionFromFocus = AppLockSessionManager.shared.sessionTimerFromFocus

    /// `WindowShieldManager.requestedMode` reads `UserDefaults` directly for the same
    /// reason. Kept separate from `AppLockSessionManager`'s mirror so the two can't
    /// overwrite each other's `@State`.
    @State private var shieldMode: FIDConstants.ShieldMode = WindowShieldManager.shared.requestedMode

    @State private var touchIDEnabled = TouchIDAuth.shared.isEnabled
    @State private var isPickingApps = false
    @State private var isUnlocking = false
    @State private var sessionError: String?
    /// Both Accessibility privileges, re-read while the page is open — see
    /// `accessibilityNotice` for why a one-shot reading isn't enough.
    @State private var permission = AccessibilityPermission.check()
    /// How this build is signed and where it lives. Read once: neither changes while
    /// the app is running, and `signature()` touches the bundle on disk.
    @State private var environment = AccessibilityPermission.environment()

    /// Same gate as the Face / Password / Recognition / Camera pages — and here it
    /// guards the most consequential thing in Settings.
    ///
    /// This page *is* the list of what app locking protects, plus the master switch
    /// and the schedule that decides when it applies. Left readable while the session
    /// is locked, anyone at the Mac could hit "移除" on every entry (or flip the
    /// switch off, or widen the unlock window) and the protection would be gone
    /// without a single prompt.
    private var isSessionUnlocked: Bool { pocController.isSessionUnlocked }

    var body: some View {
        ZStack(alignment: .top) {
            lockedState
                .opacity(isSessionUnlocked ? 0 : 1)
                .allowsHitTesting(!isSessionUnlocked)
                .accessibilityHidden(isSessionUnlocked)

            content
                .opacity(isSessionUnlocked ? 1 : 0)
                .allowsHitTesting(isSessionUnlocked)
                .accessibilityHidden(!isSessionUnlocked)
        }
        .animation(SettingsMetrics.stateTransitionAnimation, value: isSessionUnlocked)
        .onAppear { pocController.refreshCredentialStatus() }
        // Password / enrollment / app-password flows run in the notch, outside this
        // window, so nothing else prompts a re-check once one closes.
        .onChange(of: NotchOverlayController.shared.phase) { _, newPhase in
            guard newPhase == .closed else { return }
            pocController.refreshCredentialStatus()
        }
    }

    private var content: some View {
        Group {
            if coordinator.isEnabled {
                enabledContent
            } else {
                disabledContent
            }
        }
    }

    // MARK: - Session lock

    private var lockedState: some View {
        SettingsEmptyStateView(
            icon: "lock.fill",
            message: "会话已锁定",
            buttonTitle: isUnlocking ? "正在验证…" : "解锁会话",
            isButtonEnabled: !isUnlocking,
            caption: sessionError,
            action: unlock
        )
    }

    private func unlock() {
        isUnlocking = true
        sessionError = nil
        Task {
            await pocController.unlockSession()
            sessionError = pocController.sessionError
            isUnlocking = false
        }
    }

    // MARK: - Off state

    private var disabledContent: some View {
        SettingsEmptyStateView(
            icon: "lock.shield",
            message: "应用加锁已关闭",
            buttonTitle: "开启",
            caption: "Face ID 可以单独锁定某些应用，打开它们时需要你刷脸。",
            action: { coordinator.isEnabled = true }
        )
    }

    // MARK: - On state

    private var enabledContent: some View {
        VStack(alignment: .leading, spacing: SettingsMetrics.rowSpacing) {
            masterGroup
            if !permission.isFullyGranted && shieldMode == .windowShield {
                accessibilityNotice
            }
            lockedAppsSection
            sessionSection
            scheduleSection

            if let status = coordinator.statusMessage.isEmpty ? nil : coordinator.statusMessage {
                SettingsCaption(text: status)
            }
        }
        // Polled rather than refreshed only on activation: the TCC answer is normally
        // pinned at launch, so there is usually nothing to pick up — but when the
        // system *does* update it, a stale "未授权" is precisely the state the user
        // can't get themselves out of. Cheap enough to just keep looking.
        .task {
            while !Task.isCancelled {
                refreshPermission()
                try? await Task.sleep(for: .seconds(1.5))
            }
        }
        .sheet(isPresented: $isPickingApps) {
            AppPickerSheet(
                alreadyLocked: Set(store.lockedApps.map(\.bundleIdentifier)),
                onAdd: { apps in
                    for app in apps { store.lockApp(app) }
                    isPickingApps = false
                },
                onCancel: { isPickingApps = false }
            )
        }
    }

    /// Re-reads the live privileges. Not the environment — the signature and the
    /// bundle path can't change while the process runs.
    private func refreshPermission() {
        let fresh = AccessibilityPermission.check()
        if fresh != permission { permission = fresh }
    }

    private var masterGroup: some View {
        SettingsGroup {
            SettingsRowContent(
                title: "锁定选中的应用",
                subtitle: "这些应用切到前台时要求刷脸",
                subtitleMaxWidth: SettingsMetrics.rowSubtitleMaxWidth
            ) {
                FIDToggle(isOn: $coordinator.isEnabled)
            }
            SettingsGroupDivider()
            SettingsRowContent(
                title: "锁定时",
                info: "「遮住应用窗口」让你能继续使用屏幕的其余部分。当遮罩不可靠时会自动改为隐藏应用 —— 全屏、调度中心、或切换 Space。"
            ) {
                SettingsMenuPickerPill(label: shieldMode.title) {
                    ForEach(FIDConstants.ShieldMode.allCases) { mode in
                        Button(mode.title) {
                            shieldMode = mode
                            WindowShieldManager.shared.requestedMode = mode
                        }
                    }
                }
            }
            SettingsGroupDivider()
            SettingsRowContent(
                title: "使用触控 ID",
                subtitle: TouchIDAuth.shared.isAvailable ? nil : "这台 Mac 没有触控 ID 硬件"
            ) {
                FIDToggle(isOn: Binding(
                    get: { touchIDEnabled },
                    set: { newValue in
                        touchIDEnabled = newValue
                        TouchIDAuth.shared.isEnabled = newValue
                    }
                ))
                .disabled(!TouchIDAuth.shared.isAvailable)
            }
        }
    }

    /// Shown when the window shield is wanted but its prerequisite is missing.
    ///
    /// Deliberately verbose. "未授权" on its own is what makes this state so hard to
    /// escape: the switch in System Settings can be on and the app still can't see
    /// it. So this names *which* of the two privileges is missing and lists the
    /// concrete reasons, rather than leaving the user to guess.
    private var accessibilityNotice: some View {
        VStack(alignment: .leading, spacing: 6) {
            SettingsCaption(text: permissionSummary)

            ForEach(Array(environment.advice.enumerated()), id: \.offset) { _, advice in
                SettingsCaption(text: "• " + adviceText(advice))
            }

            HStack(spacing: 14) {
                noticeButton("打开辅助功能设置") {
                    AccessibilityPermission.requestPrompt()
                    AccessibilityPermission.openSystemSettings()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1) { refreshPermission() }
                }
                noticeButton("重新检测") { refreshPermission() }
                // The documented remedy, and the one System Settings itself suggests.
                noticeButton("退出并重新打开 Face ID") { AppRelauncher.relaunch() }
            }
            .padding(.top, 2)
        }
    }

    private func noticeButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(title, action: action)
            .buttonStyle(.plain)
            .font(.system(size: 12))
            .foregroundStyle(FIDTheme.accent)
    }

    private var permissionSummary: String {
        if permission.isPartiallyGranted {
            let missing = permission.canReadWindows ? "发送按键事件" : "读取其他应用的窗口"
            return "辅助功能权限不完整：缺少「\(missing)」。两项都在「系统设置 › 隐私与安全性 › 辅助功能」这同一个列表里，但它们是两个独立授权项 —— 没有单独的开关，只能靠系统弹窗授予；授予后需要重启 Face ID 才生效。"
        }
        return "尚未获得辅助功能权限。用鼠标和键盘操作被锁应用的窗口需要它；没有它 Face ID 只能退而隐藏整个应用。"
    }

    private func adviceText(_ advice: AccessibilityPermission.Environment.Advice) -> String {
        switch advice {
        case .runStandalone:
            return "当前是从 Xcode 启动的：权限判定会算在 Xcode 头上，而不是 Face ID。请单独打开 Face ID.app（或在「应用程序」里双击）再授权。"
        case .unstableSignature:
            switch environment.signature {
            case .team:
                return ""
            case .adHoc:
                return "当前构建是临时签名（ad-hoc），系统记不住授权：**每次重新编译后都要重新勾选一次**。在 Xcode 里为 target 选择开发团队后重新构建可以避免。"
            case .unsigned:
                return "当前构建没有代码签名，系统无法把授权绑定到这个程序。请在 Xcode 里为 target 选择开发团队后重新构建。"
            }
        case .moveToApplications:
            return "Face ID 目前不在「应用程序」文件夹里（\(environment.bundlePath)）。系统可能把它当成另一个程序，建议先移到 /Applications 再授权。"
        case .relaunch:
            return "授权后需要**重启 Face ID** 才会生效 —— 在系统设置里切换这类开关时，macOS 自己也会提示「退出并重新打开」。"
        }
    }

    // MARK: - Locked apps

    private var lockedAppsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            SettingsSectionTitle(text: "已锁定的应用")

            if store.lockedApps.isEmpty {
                SettingsEmptyStateView(
                    icon: "square.grid.2x2",
                    message: "还没有锁定任何应用",
                    buttonTitle: "选择应用",
                    caption: "已锁定的应用在打开前会要求刷脸。",
                    action: { isPickingApps = true }
                )
            } else {
                SettingsGroup {
                    ForEach(Array(store.lockedApps.enumerated()), id: \.element.bundleIdentifier) { index, app in
                        if index > 0 { SettingsGroupDivider() }
                        lockedAppRow(app)
                    }
                }
                SettingsActionRow(
                    title: "再添加一个应用",
                    subtitle: nil,
                    buttonTitle: "选择应用"
                ) { isPickingApps = true }
            }
        }
    }

    private func lockedAppRow(_ app: LockedApp) -> some View {
        SettingsRowContent(title: app.displayName, subtitle: app.bundleIdentifier, subtitleMaxWidth: 240) {
            HStack(spacing: 10) {
                if let icon = app.icon {
                    Image(nsImage: icon)
                        .resizable()
                        .interpolation(.high)
                        .frame(width: 24, height: 24)
                }
                Button("移除") {
                    store.unlockApp(app.bundleIdentifier)
                }
                .buttonStyle(.plain)
                .font(.system(size: 12))
                .foregroundStyle(FIDTheme.accent)
            }
        }
    }

    // MARK: - Session

    private var sessionSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            SettingsSectionTitle(text: "解锁会话")
            SettingsGroup {
                SettingsSteppedSliderRowContent(
                    title: "解锁后保持",
                    valueLabel: sessionWindow.title,
                    index: Binding(
                        get: { Double(SessionWindow.allCases.firstIndex(of: sessionWindow) ?? 0) },
                        set: { newValue in
                            let picked = SessionWindow.allCases[Int(newValue.rounded())]
                            sessionWindow = picked
                            AppLockSessionManager.shared.sessionTimeout = picked.rawValue
                        }
                    ),
                    stopCount: SessionWindow.allCases.count
                )
                SettingsGroupDivider()
                SettingsRowContent(
                    title: "从失去焦点开始计时",
                    subtitle: "离开该应用超过这段时间后重新锁定",
                    subtitleMaxWidth: SettingsMetrics.rowSubtitleMaxWidth
                ) {
                    FIDToggle(isOn: Binding(
                        get: { sessionFromFocus },
                        set: { newValue in
                            sessionFromFocus = newValue
                            AppLockSessionManager.shared.sessionTimerFromFocus = newValue
                        }
                    ))
                }
            }
            SettingsCaption(text: "「立即」表示每次切回该应用都要重新验证。")
        }
    }

    // MARK: - Schedule

    private var scheduleSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            SettingsSectionTitle(text: "定时")

            SettingsGroup {
                scheduleRows(
                    title: "锁定区间：从",
                    window: schedule.lockWindow,
                    enabled: Binding(
                        get: { schedule.lockWindow.isEnabled },
                        set: { schedule.lockWindow.isEnabled = $0; schedule.refresh() }
                    ),
                    hour: { schedule.lockWindow.startHour },
                    minute: { schedule.lockWindow.startMinute },
                    apply: { hour, minute in
                        var window = schedule.lockWindow
                        window.startHour = hour
                        window.startMinute = minute
                        schedule.lockWindow = window
                        schedule.refresh()
                    }
                )
                SettingsGroupDivider()
                scheduleRows(
                    title: "到",
                    window: schedule.lockWindow,
                    enabled: nil,
                    hour: { schedule.lockWindow.endHour },
                    minute: { schedule.lockWindow.endMinute },
                    apply: { hour, minute in
                        var window = schedule.lockWindow
                        window.endHour = hour
                        window.endMinute = minute
                        schedule.lockWindow = window
                        schedule.refresh()
                    }
                )
                SettingsGroupDivider()
                scheduleRows(
                    title: "解锁区间：从",
                    window: schedule.unlockWindow,
                    enabled: Binding(
                        get: { schedule.unlockWindow.isEnabled },
                        set: { schedule.unlockWindow.isEnabled = $0; schedule.refresh() }
                    ),
                    hour: { schedule.unlockWindow.startHour },
                    minute: { schedule.unlockWindow.startMinute },
                    apply: { hour, minute in
                        var window = schedule.unlockWindow
                        window.startHour = hour
                        window.startMinute = minute
                        schedule.unlockWindow = window
                        schedule.refresh()
                    }
                )
                SettingsGroupDivider()
                scheduleRows(
                    title: "到",
                    window: schedule.unlockWindow,
                    enabled: nil,
                    hour: { schedule.unlockWindow.endHour },
                    minute: { schedule.unlockWindow.endMinute },
                    apply: { hour, minute in
                        var window = schedule.unlockWindow
                        window.endHour = hour
                        window.endMinute = minute
                        schedule.unlockWindow = window
                        schedule.refresh()
                    }
                )
            }

            if schedule.windowsOverlap {
                SettingsCaption(text: "两个区间有重叠。重叠时段以锁定为准，应用会保持锁定。")
            }
        }
    }

    /// One schedule row. `enabled` is non-nil only on a window's first row, so the
    /// switch reads as belonging to the whole pair rather than to one time.
    private func scheduleRows(
        title: String,
        window: ScheduleWindow,
        enabled: Binding<Bool>?,
        hour: @escaping () -> Int,
        minute: @escaping () -> Int,
        apply: @escaping (Int, Int) -> Void
    ) -> some View {
        SettingsRowContent(title: title) {
            HStack(spacing: 10) {
                DatePicker(
                    "",
                    selection: timeBinding(hour: hour, minute: minute, apply: apply),
                    displayedComponents: .hourAndMinute
                )
                .labelsHidden()
                .datePickerStyle(.stepperField)
                .controlSize(.small)
                .disabled(!window.isEnabled)
                .opacity(window.isEnabled ? 1 : 0.4)

                if let enabled {
                    FIDToggle(isOn: enabled)
                }
            }
        }
    }

    /// Builds a `Date` from the stored hour/minute so a native time picker can drive a
    /// `ScheduleWindow` — which stores the two fields rather than a `Date`, because a
    /// window is a time of day, not a moment.
    private func timeBinding(
        hour: @escaping () -> Int,
        minute: @escaping () -> Int,
        apply: @escaping (Int, Int) -> Void
    ) -> Binding<Date> {
        Binding(
            get: {
                var components = DateComponents()
                components.hour = hour()
                components.minute = minute()
                return Calendar.current.date(from: components) ?? Date()
            },
            set: { newValue in
                let parts = Calendar.current.dateComponents([.hour, .minute], from: newValue)
                apply(parts.hour ?? 0, parts.minute ?? 0)
            }
        )
    }

}

// MARK: - Session window options

/// The choices the "Stay unlocked for" slider snaps to. Raw values are the seconds
/// `AppLockSessionManager` understands, including its two sentinels — `0` for "lock
/// immediately" and `-1` for "until the app is locked again".
///
/// Internal rather than private so `SessionWindowTests` can pin the fallback below:
/// getting it wrong silently makes the app *stricter* than the user asked for.
///
/// `nonisolated` for the same reason `FIDConstants` is: the project defaults to
/// `MainActor` isolation, which a pure value type has no business inheriting.
nonisolated enum SessionWindow: TimeInterval, CaseIterable, Identifiable {
    case immediately = 0
    case oneMinute = 60
    case fiveMinutes = 300
    case fifteenMinutes = 900
    case thirtyMinutes = 1800
    case oneHour = 3600
    case indefinite = -1

    var id: TimeInterval { rawValue }

    var title: String {
        switch self {
        case .immediately: return "立即"
        case .oneMinute: return "1 分钟"
        case .fiveMinutes: return "5 分钟"
        case .fifteenMinutes: return "15 分钟"
        case .thirtyMinutes: return "30 分钟"
        case .oneHour: return "1 小时"
        case .indefinite: return "直到我手动锁定"
        }
    }

    /// Falls back to the shipped default rather than `allCases[0]` — a stored value the
    /// slider no longer offers should read as "the standard duration", not as
    /// "immediately", which is a materially stricter setting.
    static func from(_ seconds: TimeInterval) -> SessionWindow {
        SessionWindow(rawValue: seconds) ?? .fiveMinutes
    }
}
