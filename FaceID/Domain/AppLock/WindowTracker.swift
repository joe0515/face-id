//
//  WindowTracker.swift
//  Face ID
//
//  Locates and follows the on-screen windows of a target app, so a shield panel
//  can be laid exactly over each one.
//
//  There is no public API to attach a view to *another process's* window. The
//  workaround is equivalent: read the window's geometry through the Accessibility
//  API and park one of our own borderless panels at the same rectangle, then keep
//  it in step. Accessibility is already required by the whole-machine unlock path,
//  so this costs no extra permission.
//
//  Following is event-first (`AXObserver` fires continuously during a drag) with a
//  slow poll underneath for the cases notifications miss — windows created by a
//  child process, geometry changes during a Space transition, and an app that
//  simply doesn't post every notification.
//

import AppKit
import ApplicationServices
import Observation

/// Identity for a tracked window.
///
/// `AXUIElement` is a Core Foundation type: Swift gives it neither `Equatable`
/// nor `Hashable`, but `CFEqual`/`CFHash` have exactly the semantics needed —
/// two wrappers obtained for the same window at different times compare equal.
nonisolated struct AXWindowKey: Hashable {
    let element: AXUIElement

    static func == (lhs: AXWindowKey, rhs: AXWindowKey) -> Bool {
        CFEqual(lhs.element, rhs.element)
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(CFHash(element))
    }
}

/// One window of the shielded app, as seen by the tracker.
nonisolated struct TrackedWindow: Identifiable, Equatable {
    let key: AXWindowKey
    /// Frame in **Cocoa** screen coordinates (origin at the primary display's
    /// bottom-left, y increasing upward).
    let frame: CGRect
    let isMinimized: Bool
    /// Covers essentially one whole display — see `WindowTracker.coversWholeScreen`.
    let isFullScreen: Bool

    var id: AXWindowKey { key }

    static func == (lhs: TrackedWindow, rhs: TrackedWindow) -> Bool {
        lhs.key == rhs.key && lhs.frame == rhs.frame && lhs.isMinimized == rhs.isMinimized
    }
}

@Observable
@MainActor
final class WindowTracker {

    /// Latest snapshot, in AX order (front-to-back is not guaranteed).
    private(set) var windows: [TrackedWindow] = []

    private(set) var isRunning = false

    @ObservationIgnored private var observer: AXObserver?
    @ObservationIgnored private var appElement: AXUIElement?
    @ObservationIgnored private var pollTimer: Timer?
    /// Windows whose per-window notifications are already registered.
    @ObservationIgnored private var observedWindows: Set<AXWindowKey> = []
    @ObservationIgnored private var onChange: (([TrackedWindow]) -> Void)?

    /// Owned by `WindowShieldManager`, which tracks one app at a time.
    init() {}

    // MARK: - Trust

    /// Whether this process may read other apps' windows. Without it the tracker
    /// can find nothing and the caller must fall back to hiding the app.
    ///
    /// Delegates so there is exactly one definition of "trusted" in the app — see
    /// `AccessibilityPermission` for why it reads both privileges and why the answer
    /// can't change until the process restarts.
    nonisolated static var isTrusted: Bool {
        AccessibilityPermission.check().canReadWindows
    }

    /// Asks the system to show the Accessibility prompt. No-op once decided.
    static func requestTrust() {
        AccessibilityPermission.requestPrompt()
    }

    // MARK: - Lifecycle

    /// Begins tracking `pid`'s windows. Returns `false` when Accessibility isn't
    /// granted, so the caller can go straight to the hidden fallback.
    @discardableResult
    func start(pid: pid_t, onChange: @escaping ([TrackedWindow]) -> Void) -> Bool {
        stop()
        guard Self.isTrusted else { return false }

        self.onChange = onChange
        appElement = AXUIElementCreateApplication(pid)

        if let appElement {
            var created: AXObserver?
            // `AXObserverCreate` takes a C callback; `refcon` carries `self` back in.
            let error = AXObserverCreate(pid, Self.observerCallback, &created)
            if error == .success, let created {
                observer = created
                let refcon = Unmanaged.passUnretained(self).toOpaque()
                for notification in [kAXWindowCreatedNotification, kAXFocusedWindowChangedNotification] {
                    _ = AXObserverAddNotification(created, appElement, notification as CFString, refcon)
                }
                CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(created), .defaultMode)
            }
        }

        isRunning = true
        refresh()
        startPolling()
        return true
    }

    func stop() {
        pollTimer?.invalidate()
        pollTimer = nil

        if let observer {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode)
        }
        observer = nil
        appElement = nil
        observedWindows.removeAll()
        windows = []
        onChange = nil
        isRunning = false
    }

    // MARK: - Collection

    private func startPolling() {
        let timer = Timer(timeInterval: FIDConstants.windowTrackPollInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        pollTimer = timer
        // `.common` so the poll keeps ticking while the user is dragging a window
        // or holding a menu open, which switches the run loop out of `.default`.
        RunLoop.main.add(timer, forMode: .common)
    }

    /// Re-reads every window and republishes. Called on start, on every poll tick,
    /// and from the AX callback.
    private func refresh() {
        guard let appElement else { return }
        let screens = NSScreen.screens.map(\.frame)
        let primaryHeight = NSScreen.screens.first?.frame.maxY ?? 0

        let found = Self.standardWindows(of: appElement)
            .compactMap { element -> TrackedWindow? in
                guard let axFrame = Self.rect(of: element) else { return nil }
                let frame = Self.cocoaRect(fromAX: axFrame, primaryDisplayHeight: primaryHeight)
                return TrackedWindow(
                    key: AXWindowKey(element: element),
                    frame: frame,
                    isMinimized: Self.isMinimized(element),
                    isFullScreen: Self.coversWholeScreen(frame, screens: screens)
                )
            }
            // A minimised window has no on-screen rectangle to cover.
            .filter { !$0.isMinimized }
            .prefix(FIDConstants.maxShieldedWindows)
            .map { $0 }

        observeNewWindows(found)

        // Only publish on a real change: the poll runs ~7×/s and republishing an
        // identical snapshot would churn every observer for nothing.
        guard found != windows else { return }
        windows = found
        onChange?(found)
    }

    /// Registers move/resize/minimise notifications for windows we haven't seen
    /// before, so an in-flight drag is followed immediately rather than a poll late.
    private func observeNewWindows(_ found: [TrackedWindow]) {
        guard let observer else { return }
        let refcon = Unmanaged.passUnretained(self).toOpaque()

        for window in found where !observedWindows.contains(window.key) {
            for notification in [
                kAXWindowMovedNotification,
                kAXWindowResizedNotification,
                kAXWindowMiniaturizedNotification,
                kAXWindowDeminiaturizedNotification,
                kAXUIElementDestroyedNotification,
            ] {
                _ = AXObserverAddNotification(observer, window.key.element, notification as CFString, refcon)
            }
            observedWindows.insert(window.key)
        }

        // A destroyed window's notifications die with it; drop it so a recycled
        // element can be re-registered.
        observedWindows.formIntersection(Set(found.map(\.key)))
    }

    /// The C trampoline. Notifications arrive on the main run loop because that's
    /// where the observer's source was added.
    private static let observerCallback: AXObserverCallback = { _, _, _, refcon in
        guard let refcon else { return }
        let tracker = Unmanaged<WindowTracker>.fromOpaque(refcon).takeUnretainedValue()
        MainActor.assumeIsolated {
            tracker.refresh()
        }
    }

    // MARK: - Pure helpers (unit-tested)

    /// Converts an Accessibility global rectangle to Cocoa screen coordinates.
    ///
    /// AX measures from the primary display's **top-left**, y increasing downward;
    /// Cocoa from its **bottom-left**, y increasing upward. Flipping about the
    /// primary display's height converts between them — and it stays correct for
    /// displays positioned above the primary, where AX y is negative and the
    /// resulting Cocoa y exceeds the primary height.
    nonisolated static func cocoaRect(fromAX rect: CGRect, primaryDisplayHeight: CGFloat) -> CGRect {
        CGRect(
            x: rect.minX,
            y: primaryDisplayHeight - rect.maxY,
            width: rect.width,
            height: rect.height
        )
    }

    /// True when `frame` covers at least `threshold` of some display in both axes.
    ///
    /// A full-screen window lives in its own Space and has no boundary worth
    /// hugging, and it can't be covered usefully — the caller falls back to hiding
    /// the app instead.
    nonisolated static func coversWholeScreen(
        _ frame: CGRect,
        screens: [CGRect],
        threshold: CGFloat = FIDConstants.fullScreenCoverageThreshold
    ) -> Bool {
        guard frame.width > 0, frame.height > 0 else { return false }
        return screens.contains { screen in
            guard screen.width > 0, screen.height > 0 else { return false }
            return frame.width >= screen.width * threshold
                && frame.height >= screen.height * threshold
        }
    }

    /// Only real, user-facing windows are worth shielding — panels, popovers and
    /// sheets have their own subroles and would otherwise get spurious covers.
    nonisolated static func isStandardWindow(subrole: String?) -> Bool {
        subrole == (kAXStandardWindowSubrole as String)
    }

    // MARK: - Accessibility plumbing

    nonisolated private static func standardWindows(of app: AXUIElement) -> [AXUIElement] {
        var raw: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &raw) == .success,
              let list = raw as? [AXUIElement] else { return [] }

        return list.filter { isStandardWindow(subrole: string(of: $0, attribute: kAXSubroleAttribute)) }
    }

    nonisolated private static func rect(of element: AXUIElement) -> CGRect? {
        guard let origin = point(of: element),
              let size = size(of: element) else { return nil }
        return CGRect(origin: origin, size: size)
    }

    nonisolated private static func point(of element: AXUIElement) -> CGPoint? {
        guard let value = axValue(of: element, attribute: kAXPositionAttribute) else { return nil }
        var result = CGPoint.zero
        guard AXValueGetValue(value, .cgPoint, &result) else { return nil }
        return result
    }

    nonisolated private static func size(of element: AXUIElement) -> CGSize? {
        guard let value = axValue(of: element, attribute: kAXSizeAttribute) else { return nil }
        var result = CGSize.zero
        guard AXValueGetValue(value, .cgSize, &result) else { return nil }
        return result
    }

    nonisolated private static func axValue(of element: AXUIElement, attribute: String) -> AXValue? {
        var raw: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &raw) == .success,
              let value = raw,
              CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        return unsafeBitCast(value, to: AXValue.self)
    }

    nonisolated private static func string(of element: AXUIElement, attribute: String) -> String? {
        var raw: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &raw) == .success else { return nil }
        return raw as? String
    }

    nonisolated private static func isMinimized(_ element: AXUIElement) -> Bool {
        var raw: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXMinimizedAttribute as CFString, &raw) == .success else {
            return false
        }
        return (raw as? Bool) ?? false
    }
}
