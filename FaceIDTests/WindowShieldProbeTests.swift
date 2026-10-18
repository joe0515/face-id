//
//  WindowShieldProbeTests.swift
//  Face ID Tests
//
//  The two probe questions the coordinator branches on — "is it painting?" and "does
//  it have any window at all?" — decide whether a locked app is challenged at all.
//  Getting them wrong either exposes the app's contents or pops an authentication
//  panel for a window that doesn't exist, so their answers are pinned here.
//

import AppKit
import Testing
@testable import FaceID

@Suite("WindowShieldManager 探测")
@MainActor
struct WindowShieldProbeTests {

    /// An id no process can have. Both probes must report "nothing", and — more
    /// importantly — `hasOnScreenWindow` must stay a *subset* of `hasAnyWindow`:
    /// a process cannot be painting without owning a window.
    @Test
    func probesReportNothingForUnknownProcess() {
        let shield = WindowShieldManager.shared
        #expect(shield.hasOnScreenWindow(pid: -1) == false)
        #expect(shield.hasAnyWindow(pid: -1) == false)
    }

    /// Whatever the truth is about the test host's own windows, the invariant must
    /// hold: on-screen implies present. This is what keeps branch ② from firing for
    /// an app whose windows were merely closed.
    @Test
    func onScreenImpliesPresent() {
        let shield = WindowShieldManager.shared
        let pid = ProcessInfo.processInfo.processIdentifier
        if shield.hasOnScreenWindow(pid: pid) {
            #expect(shield.hasAnyWindow(pid: pid))
        }
    }
}
