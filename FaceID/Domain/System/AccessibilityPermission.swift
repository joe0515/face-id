//
//  AccessibilityPermission.swift
//  Face ID
//
//  One place that answers "does this process have the Accessibility privileges?"
//  and — just as importantly — "could it even hold them?".
//
//  ## Why this replaced a bare `AXIsProcessTrusted()`
//
//  A TCC grant is pinned to the process when it launches. Neither
//  `AXIsProcessTrusted` nor `CGPreflightPostEventAccess` changes its answer
//  afterwards; Apple's own remedy, and the one System Settings offers when you
//  toggle one of these switches, is to relaunch the app. That is not a quirk we can
//  code around — it just means the UI has to say so instead of silently showing
//  "not granted" forever.
//
//  Two heuristics were tried and **rejected on evidence**, both recorded here so
//  nobody re-adds them:
//
//  1. *"An AX call returning `kAXErrorAPIDisabled` means untrusted."* — measured on
//     an untrusted process, `AXUIElementCopyAttributeValue` returns
//     `kAXErrorCannotComplete` (-25204) and `kAXErrorInvalidUIElement` (-25208),
//     **never** `kAXErrorAPIDisabled` (-25211). A check built on it reports
//     *granted* while the process is untrusted, which is the worst possible failure
//     direction — it would let `KeystrokeInjector` type into nothing, silently.
//  2. *"Polling the preflight APIs will notice a grant made while running."* — it
//     won't; see above. Polling is still worth doing for the cases where the system
//     does update, but it is not the fix.
//
//  ## The two privileges
//
//  System Settings shows one "Accessibility" list, but it covers **two distinct
//  privileges**: reading other apps' UI, and synthesizing events. They can be
//  granted independently, which is why this reports them separately — "I ticked the
//  box and it still says no" is often one privilege granted and the other not.
//

import AppKit
import ApplicationServices
import CoreGraphics
import Security

nonisolated enum AccessibilityPermission {

    // MARK: - The two privileges

    struct Status: Equatable {
        /// Reading other apps' UI. What `WindowTracker` needs to place shields, and
        /// what `AXIsProcessTrusted` reports.
        var canReadWindows: Bool
        /// Synthesizing keystrokes. What `KeystrokeInjector` needs on the lock screen.
        /// A separate TCC privilege that also lives under Accessibility.
        var canPostEvents: Bool

        /// Both, which is what Face ID's full feature set needs.
        var isFullyGranted: Bool { canReadWindows && canPostEvents }

        /// True when one is granted and the other isn't — the confusing state worth
        /// calling out by name.
        var isPartiallyGranted: Bool { (canReadWindows || canPostEvents) && !isFullyGranted }
    }

    /// Reads both privileges. Never prompts.
    static func check() -> Status {
        Status(
            canReadWindows: axIsTrusted(),
            canPostEvents: CGPreflightPostEventAccess()
        )
    }

    /// `AXIsProcessTrustedWithOptions` with the prompt suppressed — the documented
    /// API for "is this process a trusted accessibility client".
    static func axIsTrusted() -> Bool {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: false] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    /// Asks the system to show its own "would like to control this computer" alert
    /// and add Face ID to the Accessibility list. Call once, not in a loop.
    @discardableResult
    static func requestPrompt() -> Bool {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    /// Asks for the **event-posting** privilege specifically.
    ///
    /// `requestPrompt()` above only covers the AX half. System Settings draws both
    /// services in one "Accessibility" list, which is exactly what makes this
    /// confusing: adding Face ID there (or answering the AX prompt) grants
    /// *"read other apps' UI"* and nothing else. Synthesizing keystrokes is a separate
    /// TCC service, and this is the only call that asks for it.
    ///
    /// Without it, `KeystrokeInjector` posts events that the system silently drops —
    /// the worst kind of failure, because the injection reports success.
    @discardableResult
    static func requestPostEventAccess() -> Bool {
        CGRequestPostEventAccess()
    }

    /// Opens the Accessibility pane directly. For the case where the app is already
    /// listed but switched off, where the prompt above would do nothing.
    @MainActor
    static func openSystemSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") else { return }
        NSWorkspace.shared.open(url)
    }

    // MARK: - Environment

    /// How this build is signed. Decides whether a grant can survive at all.
    enum Signature: Equatable {
        /// Signed with a real team certificate. TCC records a requirement based on
        /// the team and bundle id, so the grant survives a rebuild.
        case team(String)
        /// Ad-hoc: the identity is the cdhash, which changes on **every** build, so
        /// a grant is silently invalidated and the app must be re-added. This is the
        /// usual reason a permission "stops working" during development.
        case adHoc
        /// No signature to pin anything to — TCC has nothing to remember.
        case unsigned

        var isStableAcrossRebuilds: Bool {
            if case .team = self { return true }
            return false
        }
    }

    /// Everything the UI needs to explain a missing grant, gathered in one place so
    /// the wording lives with the view rather than with the checks.
    struct Environment: Equatable {
        var signature: Signature
        /// Running under Xcode's Run button, where TCC attributes the decision to
        /// Xcode rather than to Face ID.
        var isLaunchedByXcode: Bool
        var isInsideApplicationsFolder: Bool
        var bundlePath: String

        /// What to suggest, in priority order. The first entry is the likeliest cause.
        var advice: [Advice] {
            var result: [Advice] = []
            if isLaunchedByXcode {
                result.append(.runStandalone)
            }
            if !signature.isStableAcrossRebuilds {
                result.append(.unstableSignature)
            }
            if !isInsideApplicationsFolder {
                result.append(.moveToApplications)
            }
            // Always last: relaunching is the documented remedy for every case above.
            result.append(.relaunch)
            return result
        }

        enum Advice: Equatable {
            case runStandalone
            case unstableSignature
            case moveToApplications
            case relaunch
        }
    }

    static func environment() -> Environment {
        Environment(
            signature: signature(),
            isLaunchedByXcode: isLaunchedByXcode,
            isInsideApplicationsFolder: isInsideApplicationsFolder,
            bundlePath: Bundle.main.bundleURL.path
        )
    }

    /// `__XCODE_BUILT_PRODUCTS_DIR_PATHS` is injected by Xcode when it launches the
    /// binary from a build directory. Same signal `SpaceKeyMonitor` uses.
    static var isLaunchedByXcode: Bool {
        ProcessInfo.processInfo.environment["__XCODE_BUILT_PRODUCTS_DIR_PATHS"] != nil
    }

    static var isInsideApplicationsFolder: Bool {
        let path = Bundle.main.bundleURL.resolvingSymlinksInPath().path
        return path.hasPrefix("/Applications/") || path.hasPrefix(NSHomeDirectory() + "/Applications/")
    }

    // MARK: - Signature inspection

    /// Reads the code signature out of the bundle on disk.
    ///
    /// `kSecCodeSignatureAdhoc` is `0x0002`; the constant itself isn't surfaced to
    /// Swift, so the raw value is spelled out with this note rather than left as a
    /// magic number.
    static func signature() -> Signature {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(Bundle.main.bundleURL as CFURL, [], &code) == errSecSuccess,
              let code else { return .unsigned }

        var info: CFDictionary?
        let status = SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &info)
        guard status == errSecSuccess, let dictionary = info as? [String: Any] else { return .unsigned }

        if let team = dictionary[kSecCodeInfoTeamIdentifier as String] as? String, !team.isEmpty {
            return .team(team)
        }

        let adHocFlag: UInt32 = 0x0002
        let flags = dictionary[kSecCodeInfoFlags as String] as? UInt32 ?? 0
        return flags & adHocFlag != 0 ? .adHoc : .unsigned
    }
}
