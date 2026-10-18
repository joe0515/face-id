//
//  AppRelauncher.swift
//  Face ID
//
//  Quits this process and starts a fresh copy of the same bundle.
//
//  This exists because of how TCC works, not for convenience. An Accessibility or
//  PostEvent grant is resolved when the process launches and is not re-resolved
//  afterwards: `AXIsProcessTrusted` and `CGPreflightPostEventAccess` keep returning
//  their launch-time answer even after the user flips the switch. Apple's own remedy
//  — and the one System Settings itself offers — is to relaunch, so the app offers
//  the same button rather than telling the user to find the Quit item and come back.
//

import AppKit

@MainActor
enum AppRelauncher {

    /// Launches a new instance and, only if that succeeded, terminates this one.
    ///
    /// `createsNewApplicationInstance` matters: without it LaunchServices would
    /// treat the request as "bring the running app forward" and nothing would
    /// restart. The old instance is deliberately kept alive until the new one is
    /// confirmed launched — quitting first would leave the user with no app at all
    /// if the launch failed.
    static func relaunch() {
        let bundleURL = Bundle.main.bundleURL
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true

        NSWorkspace.shared.openApplication(at: bundleURL, configuration: configuration) { app, error in
            Task { @MainActor in
                guard app != nil, error == nil else { return }
                NSApp.terminate(nil)
            }
        }
    }
}
