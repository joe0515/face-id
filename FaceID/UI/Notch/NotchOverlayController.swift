//
//  NotchOverlayController.swift
//  Face ID
//
//  The only file other code should touch to show the notch overlay.
//
//  Interaction is hover-driven, not click-driven: a non-activating panel
//  otherwise needs a first click just to gain focus before a second click
//  registers — hover avoids that "have to double-click" bug entirely.
//

import AppKit
import SwiftUI
import Observation

@Observable
@MainActor
final class NotchOverlayController {
    /// One overlay window for the whole app — sharing one instance guarantees
    /// the triggers never run concurrently, rather than leaving that incidental.
    static let shared = NotchOverlayController()

    enum Phase: Equatable {
        /// While armed, the window stays on-screen here (hover-reactive); otherwise ordered out.
        case closed
        /// Expanded, showing the idle still image — actively looking for a face.
        case scanning
        /// Success animation playing, then auto-collapses.
        case success
        /// Failure animation playing/held; collapses after a hold unless
        /// the user hovers first to retry.
        case failure
        case collapsing
        /// Hosting the multi-step onboarding flow, driven by the hosted
        /// OnboardingController rather than this controller's own machinery.
        case onboarding
        /// Showing a short message instead of a scan — e.g. "the keychain needs
        /// re-authorizing, do it from the menu bar once you're logged in".
        /// Exists so the lock screen can explain itself without any interactive
        /// surface: on the login window nothing else of ours is visible.
        case notice(String)
    }

    /// Kept as one enum (rather than two independent optionals) so exactly one is ever active.
    enum Content: Equatable {
        case scan(ScanMedia)
        case onboarding(OnboardingController)
        /// A locked app is asking to be unlocked. The payload carries its own media
        /// so resolving an attempt swaps the video without evicting the icon and
        /// name that identify which app is being unlocked.
        case appLock(AppLockContent)
        /// A plain message — see `Phase.notice`.
        case notice(String)

        static func == (lhs: Content, rhs: Content) -> Bool {
            switch (lhs, rhs) {
            case (.scan(let a), .scan(let b)): return a == b
            case (.onboarding(let a), .onboarding(let b)): return a === b
            case (.appLock(let a), .appLock(let b)): return a == b
            case (.notice(let a), .notice(let b)): return a == b
            default: return false
            }
        }
    }

    private(set) var phase: Phase = .closed
    private(set) var content: Content = .scan(.idle)
    /// Read-only convenience for the scan-mode view/callers — `.idle` while
    /// onboarding owns the panel.
    var media: ScanMedia {
        switch content {
        case .scan(let media): return media
        case .appLock(let appLock): return appLock.media
        case .onboarding, .notice: return .idle
        }
    }
    private(set) var geometry: NotchGeometry = .forMainScreen()
    /// Read by the view for the hover-driven size/shadow bump — irrelevant
    /// to the phase state machine itself.
    private(set) var isArmed = false

    /// Pill style only: whether the pill is parked on screen at rest vs. off-screen.
    /// Deliberately separate from `isArmed` — it lags it by a frame on the way in
    /// (making the pill slide into place) and leads it on the way out.
    private(set) var isPillDocked = false

    /// Snapshotted from `FIDSettings` when a cycle begins rather than read live,
    /// so a settings change mid-attempt can't resize the panel or change how it resolves.
    private(set) var activeUnlockStyle: UnlockAnimationStyle = .original

    /// What a hover-driven activation should do — set by `arm()` (persists
    /// across scan cycles) or by one-shot `present(onRetry:)` (single use).
    private var onActivate: (() -> Void)?

    private let windowController = NotchWindowController()
    private var resolveTask: Task<Void, Never>?
    private var scanTimeoutTask: Task<Void, Never>?

    /// Guards `primeWindowIfNeeded` so the extra render pass only happens on the first show.
    private var hasPrimedWindow = false

    /// Matches the success asset duration (~1.22s) plus a short beat to read the final frame.
    private let successHoldDuration: Duration = .milliseconds(1_700)
    /// Non-private so FaceUnlockCoordinator's auto-retry can wait this out too.
    let failureHoldDuration: Duration = .seconds(5)
    /// Reads the same setting as `FaceUnlockCoordinator.scanWindowDuration` so
    /// the two separate timers expire together — plus the camera's cold-start
    /// allowance, because the recognition window is anchored to the first frame
    /// while this timer starts at `beginScanning()`. Without the extra room the
    /// panel collapsed before a single frame had been scored.
    private var scanTimeoutDuration: Duration {
        .seconds(Double(FIDSettings.shared.faceDetectionSeconds) + FIDConstants.cameraWarmupAllowance)
    }
    /// Long enough for the closing spring to fully settle before the window is
    /// hidden/left closed — collapsing state too early made the window visibly pop away.
    let collapseAnimationDuration: Duration = .milliseconds(700)

    /// Invoked when Esc is pressed while an app-lock challenge owns the panel.
    /// Set by `AppUnlockCoordinator`; `nil` the rest of the time, so Esc does nothing
    /// during onboarding or the lock-screen scan.
    @ObservationIgnored var onAppLockCancel: (() -> Void)?

    private init() {
        windowController.contentView = NSHostingView(rootView: NotchOverlayView(controller: self))
        // A display connecting/disconnecting mid-flow can flip notch vs. pill style.
        windowController.onScreenParametersChanged = { [weak self] in
            guard let self else { return }
            self.geometry = self.windowController.currentGeometry
        }
        windowController.onEscape = { [weak self] in
            guard let self, self.hasAppLockContent else { return }
            self.onAppLockCancel?()
        }
    }

    /// Takes key without activating Face ID, so the challenge can catch Esc. Needed
    /// because the window shield — which catches Esc itself — isn't always present:
    /// in the `.hidden` fallback there are no windows to cover.
    func makeAppLockKey() {
        guard hasAppLockContent else { return }
        windowController.makePanelKey()
    }

    // MARK: - Armed mode (FaceUnlockCoordinator)

    /// Arms the overlay for the lock-screen flow: shows the window and keeps it
    /// up until `disarm()`. `onActivate` restarts scanning on hover.
    func arm(onActivate: @escaping () -> Void) {
        isArmed = true
        self.onActivate = onActivate
        geometry = windowController.currentGeometry
        phase = .closed
        content = .scan(.idle)
        isPillDocked = false
        windowController.show()
        hasPrimedWindow = true // already shown+rendered while closed, same effect as primeWindowIfNeeded
        updateInteractivity()

        guard geometry.style == .pill else {
            // The notch silhouette has nowhere to travel from — it's on top of hardware already there.
            isPillDocked = true
            return
        }
        // Render one real frame with the pill still off-screen, so flipping the
        // flag next runloop animates it down instead of appearing already docked.
        windowController.displaySynchronously()
        DispatchQueue.main.async { [weak self] in
            guard let self, self.isArmed else { return }
            self.isPillDocked = true
        }
    }

    /// Gives up key and frontmost status so a **system-owned** prompt can take the
    /// keyboard — see `NotchWindowController.relinquishKey`.
    ///
    /// Called before the keychain ACL dialog. Without it that dialog is visible but
    /// unresponsive, which reads as a hang rather than as a question.
    func relinquishKeyForSystemPrompt() {
        windowController.relinquishKey()
    }

    /// Shows a plain message on the panel — no scanning, no video, nothing to click.
    ///
    /// Used when the unlock path can't proceed and the reason is something the user
    /// must act on **away from the lock screen** (a keychain re-authorization, say).
    /// On the login window this panel is the only surface of ours that is visible at
    /// all, so "do nothing" would read as a broken feature; a sentence reads as a
    /// state. Collapses after `noticeHoldDuration`.
    func presentNotice(_ text: String) {
        isArmed = false
        onActivate = nil
        isPillDocked = false
        geometry = windowController.currentGeometry
        content = .notice(text)
        phase = .notice(text)
        windowController.show()
        hasPrimedWindow = true
        updateInteractivity()

        scanTimeoutTask?.cancel()
        scanTimeoutTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(FIDConstants.noticeHoldDuration))
            guard let self, !Task.isCancelled, !self.isArmed else { return }
            await self.collapse()
        }
    }

    /// Truly hides the window. Only call once the lock-screen attempt is
    /// completely done — while armed, resolving an attempt goes back to `.closed`, not this.    ///
    /// If a success/collapse sequence is already resolving, let it finish
    /// naturally: setting `isArmed = false` is enough, since the already-scheduled
    /// `collapse()` checks `isArmed` once its hold expires and hides for real then.
    func disarm() {
        isArmed = false
        onActivate = nil
        // Undocked before the guard: if a success collapse is already in flight, this
        // turns it into a full slide-off-screen exit rather than a shrink to a resting pill.
        isPillDocked = false
        guard phase != .success, phase != .collapsing else { return }
        resolveTask?.cancel(); resolveTask = nil
        scanTimeoutTask?.cancel(); scanTimeoutTask = nil
        // Re-measured here, not just trusted from `arm()` — `arm()` typically
        // fires right around wake/unlock, when AppKit may not have finished
        // laying out the menu bar yet, so `auxiliaryTopLeftArea`/`RightArea`
        // can read back momentarily wrong. Refreshing right before settling
        // to `.closed` (the shape most directly compared against the real
        // notch) self-corrects instead of baking in a bad first reading.
        geometry = windowController.currentGeometry
        phase = .closed
        setScanMedia(.idle)
        windowController.setInteractive(false)

        guard geometry.style == .pill, windowController.isVisible else {
            windowController.hide()
            return
        }
        // The pill is visible at rest, so hiding the window right now would blink it
        // away instead of playing the slide-up (visibility check above skips hidden windows).
        Task { [weak self] in
            try? await Task.sleep(for: self?.collapseAnimationDuration ?? .milliseconds(700))
            guard let self, !self.isArmed, self.phase == .closed else { return }
            self.windowController.hide()
        }
    }

    /// Shows the idle still; auto-collapses silently (no failure animation) after
    /// `scanTimeoutDuration` if nothing resolves it.
    func beginScanning() {
        resolveTask?.cancel(); resolveTask = nil
        scanTimeoutTask?.cancel()
        geometry = windowController.currentGeometry
        activeUnlockStyle = FIDSettings.shared.effectiveUnlockAnimationStyle
        setScanMedia(.idle)
        phase = .scanning
        updateInteractivity()

        scanTimeoutTask = Task { [weak self] in
            try? await Task.sleep(for: self?.scanTimeoutDuration ?? .seconds(5))
            guard let self, !Task.isCancelled, self.phase == .scanning else { return }
            await self.collapse()
        }
    }

    // MARK: - Window priming (first show only)

    /// On the very first show, `present()`/`presentOnboarding()` would otherwise render
    /// already-expanded with no prior "closed" frame for SwiftUI to animate away from.
    /// This runs one real closed-state show+render pass first, only on that first call.
    private func primeWindowIfNeeded(_ completion: @escaping () -> Void) {
        guard !hasPrimedWindow else {
            completion()
            return
        }
        hasPrimedWindow = true
        content = .scan(.idle)
        phase = .closed
        windowController.show()
        windowController.displaySynchronously()
        DispatchQueue.main.async(execute: completion)
    }

    // MARK: - One-shot mode (onboarding, Face Lab preview)

    /// Shows the overlay in its scanning state. Safe to call again while already visible.
    /// `onRetry` runs on hover after a failed attempt; pass nil to just collapse on hover.
    ///
    /// - Parameter styleOverride: forces `.minimal`/`.original` regardless of the saved
    ///   preference, for the Animation section's live preview.
    func present(styleOverride: UnlockAnimationStyle? = nil, onRetry: (() -> Void)? = nil) {
        isArmed = false
        onActivate = onRetry
        resolveTask?.cancel(); resolveTask = nil
        scanTimeoutTask?.cancel(); scanTimeoutTask = nil
        geometry = windowController.currentGeometry
        activeUnlockStyle = styleOverride ?? FIDSettings.shared.effectiveUnlockAnimationStyle
        primeWindowIfNeeded { [weak self] in
            guard let self else { return }
            content = .scan(.idle)
            phase = .scanning
            windowController.show()
            updateInteractivity()
        }
    }

    // MARK: - App-lock mode (AppUnlockCoordinator)

    /// Presents an app-unlock challenge: the locked app's own icon where the lock
    /// glyph normally sits, beside the scan video, in the compact silhouette.
    ///
    /// Self-contained — it also starts the scan, including the timeout that collapses
    /// the panel — because an app challenge always has a scan window, unlike the
    /// one-shot `present()` whose caller decides when scanning begins.
    ///
    /// - Parameter onRetry: runs on hover after a failed attempt; pass nil to just
    ///   collapse on hover. Hover works here because `updateInteractivity()` keeps the
    ///   panel mouse-responsive while an app-lock payload is showing.
    func presentAppLock(_ content: AppLockContent, onRetry: (() -> Void)? = nil) {
        isArmed = false
        onActivate = onRetry
        resolveTask?.cancel(); resolveTask = nil
        scanTimeoutTask?.cancel(); scanTimeoutTask = nil
        geometry = windowController.currentGeometry
        primeWindowIfNeeded { [weak self] in
            guard let self else { return }
            self.content = .appLock(content)
            self.windowController.show()
            // Docked up front so that when the challenge eventually collapses it
            // comes to rest *on screen* rather than sliding away: a resting pill is
            // what makes the hover-to-retry gesture reachable at all. The lock-screen
            // path doesn't need this because its next wake event re-arms it.
            self.isPillDocked = true
            // `beginScanning()` only rewrites the media, so the payload above survives.
            self.beginScanning()
        }
    }

    /// Ends an app-lock challenge for good: drops the payload and hides the panel.
    ///
    /// Needed because an app-lock challenge deliberately survives `collapse()` — see
    /// there — so nothing else would ever clear it.
    func endAppLockChallenge() {
        guard hasAppLockContent else { return }
        isArmed = false
        onActivate = nil
        resolveTask?.cancel(); resolveTask = nil
        scanTimeoutTask?.cancel(); scanTimeoutTask = nil
        phase = .closed
        content = .scan(.idle)
        isPillDocked = false
        windowController.setInteractive(false)
        windowController.hide()
    }

    /// Plays the success animation, then ends the challenge once it has finished.
    /// Deferred because `endAppLockChallenge()` would otherwise cut the video short —
    /// and because `collapse()` no longer hides the panel while a payload is present.
    func completeAppLock() {
        guard hasAppLockContent else { return }
        finish(success: true)
        Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(for: self.successHoldDuration + self.collapseAnimationDuration)
            self.endAppLockChallenge()
        }
    }

    // MARK: - Onboarding mode (OnboardingController)

    /// Hands the panel to the onboarding flow — this object only owns visibility and
    /// interactivity while `.onboarding` is active; sizing/content is driven by `controller`.
    func presentOnboarding(_ controller: OnboardingController) {
        isArmed = false
        onActivate = nil
        resolveTask?.cancel(); resolveTask = nil
        scanTimeoutTask?.cancel(); scanTimeoutTask = nil
        geometry = windowController.currentGeometry
        primeWindowIfNeeded { [weak self] in
            guard let self else { return }
            content = .onboarding(controller)
            phase = .onboarding
            windowController.show()
            updateInteractivity()
        }
    }

    /// Gracefully shrinks the onboarding panel away and hides the window; guarded by
    /// re-checking `content` so a concurrently-started scan cycle can't be interrupted.
    func dismissOnboarding() {
        guard case .onboarding = content else { return }
        // Drop key/interactivity now, not inside the Task: first-run completion opens
        // Settings this same turn, and a still-key overlay would leave it inactive.
        phase = .collapsing
        updateInteractivity()
        Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(for: self.collapseAnimationDuration)
            guard case .onboarding = self.content else { return }
            self.content = .scan(.idle)
            self.phase = .closed
            self.windowController.hide()
        }
    }

    // MARK: - Resolving (shared by both modes)

    /// Writes the scan media into whichever content case owns it.
    ///
    /// Assigning `.scan(media)` directly would evict an app-lock payload — losing the
    /// app's icon and name mid-animation — and would evict an onboarding flow outright.
    /// Every "reset the video" path goes through here for that reason.
    private func setScanMedia(_ media: ScanMedia) {
        content = Self.content(content, withMedia: media)
    }

    /// The preservation rule in pure form, so it can be exercised without a live panel.
    ///
    /// - `.appLock`: keeps its identity, swaps only the video.
    /// - `.onboarding`: returned untouched — onboarding owns the panel and its content.
    /// - `.notice`: returned untouched — a notice has no video to swap.
    /// - `.scan`: becomes the given media.
    static func content(_ content: Content, withMedia media: ScanMedia) -> Content {
        switch content {
        case .appLock(var appLock):
            appLock.media = media
            return .appLock(appLock)
        case .onboarding, .notice:
            return content
        case .scan:
            return .scan(media)
        }
    }

    /// Resolves the current attempt. Success plays its animation and then
    /// collapses on its own; failure plays its animation and holds until
    /// either the hold expires or the user hovers to retry.
    func finish(success: Bool) {
        resolveTask?.cancel()
        scanTimeoutTask?.cancel()

        // Unlock Animation → None just skips the success/failure video; phase and
        // retry behavior are unaffected. Reads the cycle's captured style, not live settings.
        let shouldAnimate = activeUnlockStyle != .none
        // Routed through `setScanMedia` rather than assigning `.scan(...)`: an app-lock
        // challenge must keep its icon and name on screen while the resolve video plays.
        setScanMedia(shouldAnimate ? (success ? .success : .failure) : .idle)
        phase = success ? .success : .failure
        updateInteractivity()

        let hold = shouldAnimate ? (success ? successHoldDuration : failureHoldDuration) : Duration.milliseconds(400)
        resolveTask = Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(for: hold)
            guard !Task.isCancelled else { return }
            await self.collapse()
        }
    }

    /// Hover-driven activation: wakes from a closed/armed state, or retries from a held
    /// failure frame. No-op during scanning/success/collapsing.
    func activate() {
        // Gated here rather than in `updateInteractivity()` so the cosmetic hover bump
        // stays unaffected — only the retry itself is removed.
        //
        // An app-lock challenge is exempt: this panel is the only way to retry a
        // blocked app, so honoring "retry on hover: off" here would leave the app
        // unreachable rather than merely less convenient.
        guard FIDSettings.shared.retryOnHover || hasAppLockContent else { return }
        switch phase {
        case .closed, .failure, .notice:
            guard let onActivate else {
                if phase == .failure { Task { await collapse() } }
                return
            }
            resolveTask?.cancel(); resolveTask = nil
            if !isArmed {
                // Captures its own style here; the armed path doesn't need to since
                // `onActivate()` routes through `beginScanning()`, which captures.
                activeUnlockStyle = FIDSettings.shared.effectiveUnlockAnimationStyle
                setScanMedia(.idle)
                phase = .scanning
                updateInteractivity()
            }
            onActivate()
        case .scanning, .success, .collapsing, .onboarding:
            break
        }
    }

    /// Collapses gracefully: animates shut, then either leaves the window
    /// at rest (closed, still on-screen, hover-reactive) if armed, or
    /// orders it out entirely if not.
    func collapse() async {
        guard phase != .closed, phase != .collapsing else { return }
        phase = .collapsing
        updateInteractivity()
        try? await Task.sleep(for: collapseAnimationDuration)
        guard phase == .collapsing else { return }

        // Same re-measure as `disarm()` — self-corrects a geometry captured
        // during a mid-wake reading before the panel settles to `.closed`.
        geometry = windowController.currentGeometry
        setScanMedia(.idle)
        // An app-lock challenge stays on screen when it times out. Unlike the
        // lock-screen path — which the next wake/lock event re-arms — this panel *is*
        // the only route back into the blocked app, so hiding it would strand the
        // user with no way to retry. `endAppLockChallenge()` is what finally clears it.
        if isArmed || hasAppLockContent {
            phase = .closed
            updateInteractivity()
        } else {
            phase = .closed
            windowController.hide()
        }
    }

    /// Tears the overlay down without any resolve animation. Deliberately a no-op while
    /// success/collapsing is in flight — interrupting that made the window vanish abruptly.
    func dismissImmediately() {
        guard phase != .success, phase != .collapsing else { return }
        resolveTask?.cancel(); resolveTask = nil
        scanTimeoutTask?.cancel(); scanTimeoutTask = nil
        phase = .closed
        setScanMedia(.idle)
        isPillDocked = false
        windowController.setInteractive(false)
        windowController.hide()
    }

    /// Drops a `notice` (its hold timer is still pending, or the machine just got
    /// unlocked). No-op for every other phase.
    func dismissNotice() {
        guard case .notice = phase else { return }
        scanTimeoutTask?.cancel(); scanTimeoutTask = nil
        phase = .closed
        setScanMedia(.idle)
        isPillDocked = false
        windowController.hide()
    }

    private func updateInteractivity() {
        // Click-through otherwise, so the overlay never intercepts anything it doesn't
        // need to. Onboarding additionally needs key so its text field can receive keystrokes.
        //
        // `.appLock` is included because there is no armed state to make the panel
        // interactive, and without mouse events the hover-to-retry gesture — the only
        // way back from a failed app unlock — would never fire.
        let wantsMouseEvents = isArmed || phase == .failure || phase == .onboarding || hasAppLockContent
        windowController.setInteractive(wantsMouseEvents, key: phase == .onboarding)
    }

    /// Whether the panel is currently showing an app-unlock challenge.
    var hasAppLockContent: Bool {
        if case .appLock = content { return true }
        return false
    }

    /// Called by `NotchOverlayView` whenever the visible panel's own frame
    /// changes (step change, expand/collapse, hover bump, …) — see
    /// `NotchWindowController.updateMousePassthrough()`.
    func updateInteractiveContentRect(_ rect: CGRect?) {
        windowController.setInteractiveContentRect(rect)
    }
}
