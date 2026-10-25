//
//  UpdaterController.swift
//  Face ID
//
//  "Check for Updates" is backed by `GitHubReleaseChecker`, which queries the
//  GitHub Releases API for the latest published build, compares versions, and
//  downloads + mounts the .dmg when a newer one exists. Sparkle still starts
//  (its `SUFeedURL` is a placeholder we don't rely on) but its own scheduler is
//  switched off so there's a single source of truth for update checks.
//

import AppKit
import Observation
import Sparkle

@Observable
@MainActor
final class UpdaterController {
    private let controller: SPUStandardUpdaterController
    private let presentationDelegate = UpdatePresentationDelegate()

    /// Mirrors `SPUUpdater.canCheckForUpdates` (KVO-only on Sparkle's side, hence the manual observation below).
    private(set) var canCheckForUpdates = false
    private var canCheckForUpdatesObservation: NSKeyValueObservation?

    /// Forwards straight to `FIDSettings` — the background check honours the same flag.
    var automaticallyChecksForUpdates: Bool {
        get { FIDSettings.shared.automaticallyChecksForUpdates }
        set { FIDSettings.shared.automaticallyChecksForUpdates = newValue }
    }

    /// True while Sparkle is showing anything (none of our flows use it, kept for parity with `AppDelegate`).
    var isPresentingUpdateUI: Bool { presentationDelegate.isPresentingUpdateUI }

    /// Custom session so GitHub serves both the API and the asset download without a 403.
    private let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.httpAdditionalHeaders = ["User-Agent": "Face-ID-Mac"]
        return URLSession(configuration: config)
    }()

    private var autoCheckTimer: Timer?

    init() {
        // `startingUpdater: false` — `start()` is called explicitly from `AppDelegate.applicationDidFinishLaunching`.
        controller = SPUStandardUpdaterController(
            startingUpdater: false,
            updaterDelegate: nil,
            userDriverDelegate: presentationDelegate
        )

        canCheckForUpdatesObservation = controller.updater.observe(
            \.canCheckForUpdates, options: [.initial, .new]
        ) { [weak self] updater, _ in
            let value = updater.canCheckForUpdates
            Task { @MainActor [weak self] in
                self?.canCheckForUpdates = value
            }
        }
    }

    /// Starts Sparkle (for parity) but turns its own scheduler off; we drive all checks ourselves.
    func start() {
        controller.startUpdater()
        controller.updater.automaticallyChecksForUpdates = false
        scheduleAutoCheck()
    }

    /// User-initiated "Check for Updates" — runs the GitHub flow and reports the outcome.
    func checkForUpdates() {
        Task { await performCheck(silent: false) }
    }

    // MARK: - Check flow

    private func performCheck(silent: Bool) async {
        do {
            let release = try await GitHubReleaseChecker.fetchLatestRelease()
            guard GitHubReleaseChecker.isUpdateAvailable(latest: release.version) else {
                if !silent { await presentUpToDate(current: GitHubReleaseChecker.currentVersion) }
                return
            }
            await presentUpdateAvailable(release)
        } catch {
            if !silent { await presentError(error) }
        }
    }

    private func presentUpdateAvailable(_ release: GitHubRelease) async {
        let body = (release.body ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let info = body.isEmpty ? "" : "\n\n\(body.count > 600 ? String(body.prefix(600)) + "…" : body)"
        let message = "发现新版本 \(release.version)。\(info)"
        let response = runAlert(title: "发现新版本", message: message, buttons: ["下载并更新", "稍后"])
        if response == .alertFirstButtonReturn {
            await downloadAndOpen(release)
        }
    }

    private func presentUpToDate(current: String) async {
        runAlert(title: "已是最新版本", message: "当前版本 \(current)，无需更新。", buttons: ["好"])
    }

    private func presentError(_ error: Error) async {
        let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        runAlert(title: "检查更新失败", message: message, buttons: ["好"])
    }

    private func downloadAndOpen(_ release: GitHubRelease) async {
        guard let dmgURL = release.dmgURL else {
            await presentError(GitHubUpdateError.noDMGAsset(release.version))
            return
        }
        do {
            let (tempURL, _) = try await session.download(from: dmgURL)
            let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first?
                .appendingPathComponent("FaceID-\(release.version).dmg")
            guard let destination = downloads else { throw GitHubUpdateError.invalidResponse }
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.moveItem(at: tempURL, to: destination)
            // Opening a .dmg mounts it and reveals the window — the user drags Face ID.app to Applications.
            NSWorkspace.shared.open(destination)
            runAlert(
                title: "已下载更新",
                message: "已将 FaceID-\(release.version).dmg 下载到「下载」并打开安装包。把 Face ID 拖入「应用程序」即可完成更新。",
                buttons: ["好"]
            )
        } catch {
            await presentError(GitHubUpdateError.downloadFailed(error))
        }
    }

    // MARK: - Auto check

    private func scheduleAutoCheck() {
        guard FIDSettings.shared.automaticallyChecksForUpdates else { return }
        // One quiet check shortly after launch.
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 30 * 1_000_000_000)
            await self?.performCheck(silent: true)
        }
        // Then once a day.
        autoCheckTimer = Timer.scheduledTimer(withTimeInterval: 24 * 60 * 60, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard FIDSettings.shared.automaticallyChecksForUpdates else { return }
                await self?.performCheck(silent: true)
            }
        }
    }

    /// Modal alert on the main thread. The first button is the default (Return).
    private func runAlert(title: String, message: String, buttons: [String]) -> NSApplication.ModalResponse {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = title
        alert.informativeText = message
        for (index, title) in buttons.enumerated() {
            let button = alert.addButton(withTitle: title)
            if index == 0 { button.keyEquivalent = "\r" }
        }
        return alert.runModal()
    }
}

/// Receives Sparkle's show/hide callbacks (kept for parity with `AppDelegate.windowWillClose`).
@MainActor
private final class UpdatePresentationDelegate: NSObject, SPUStandardUserDriverDelegate {
    private(set) var isPresentingUpdateUI = false

    func standardUserDriverWillShowModalAlert() { beginPresenting() }

    func standardUserDriverWillHandleShowingUpdate(
        _ handleShowingUpdate: Bool, forUpdate update: SUAppcastItem, state: SPUUserUpdateState
    ) { beginPresenting() }

    func standardUserDriverWillFinishUpdateSession() { isPresentingUpdateUI = false }

    private func beginPresenting() {
        isPresentingUpdateUI = true
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }
}
