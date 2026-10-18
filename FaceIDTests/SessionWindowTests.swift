//
//  SessionWindowTests.swift
//  Face IDTests
//
//  The "Stay unlocked for" slider's option set. Small, but the fallback matters:
//  a stored timeout the slider no longer offers has to read as the standard
//  duration, not as the first option — which is "Immediately", a materially
//  stricter setting than the user ever chose.
//

import Foundation
import Testing

@testable import FaceID

@Suite("SessionWindow")
struct SessionWindowTests {

    @Test("Sentinel raw values are the ones AppLockSessionManager understands")
    func sentinelsMatchTheSessionManager() {
        #expect(SessionWindow.immediately.rawValue == 0)
        #expect(SessionWindow.indefinite.rawValue == FIDConstants.indefiniteSessionValue)
    }

    @Test("The shipped default is one of the offered options")
    func defaultIsOffered() {
        // `FIDConstants.defaultAppSessionTimeout` is what `AppLockSessionManager`
        // falls back to when nothing is stored — it must be selectable, or the
        // slider would open on a value it can't display.
        #expect(SessionWindow(rawValue: FIDConstants.defaultAppSessionTimeout) != nil)
    }

    @Test("Every round-trips through its raw value")
    func roundTrips() {
        for window in SessionWindow.allCases {
            #expect(SessionWindow.from(window.rawValue) == window)
        }
    }

    @Test("An unknown stored value falls back to the standard duration, not to 'Immediately'")
    func unknownValueFallsBackToStandard() {
        // e.g. a build that once offered 2 hours, now reopened by this one.
        let result = SessionWindow.from(7200)
        #expect(result == .fiveMinutes)
        #expect(result != .immediately)
    }

    @Test("Options are ordered from strictest to loosest, so the slider reads left-to-right")
    func ordering() {
        let cases = SessionWindow.allCases
        #expect(cases.first == .immediately)
        #expect(cases.last == .indefinite)
        // The one non-monotonic spot is the sentinel at the end — everything before it
        // must ascend, or the slider's positions would lie about what they do.
        let timed = cases.dropLast()
        #expect(timed.map(\.rawValue) == timed.map(\.rawValue).sorted())
    }
}
