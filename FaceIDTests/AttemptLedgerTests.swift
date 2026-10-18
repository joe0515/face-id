//
//  AttemptLedgerTests.swift
//  Face IDTests
//
//  The lockout arithmetic behind the app-lock ladder, exercised without a camera or
//  a UI. Every case drives an explicit `now` so the tests never race a real clock.
//

import Foundation
import Testing

@testable import FaceID

@Suite("AttemptLedger")
struct AttemptLedgerTests {

    private let start = Date(timeIntervalSince1970: 1_700_000_000)

    @Test("A fresh ledger is not locked out and reports no remaining lockout")
    func freshLedger() {
        let ledger = AttemptLedger()
        #expect(ledger.failedAttempts == 0)
        #expect(ledger.isLockedOut == false)
        var mutable = ledger
        #expect(mutable.remainingLockout(now: start) == nil)
    }

    @Test("Failures below the limit accumulate without locking out")
    func belowLimit() {
        var ledger = AttemptLedger()
        for _ in 1..<FIDConstants.maxFailedAttempts {
            #expect(ledger.recordFailure(now: start) == false)
        }
        #expect(ledger.failedAttempts == FIDConstants.maxFailedAttempts - 1)
        #expect(ledger.isLockedOut == false)
    }

    @Test("Reaching the limit locks out and reports the full window")
    func tripsAtLimit() {
        var ledger = AttemptLedger()
        var tripped = false
        for _ in 1...FIDConstants.maxFailedAttempts {
            tripped = ledger.recordFailure(now: start)
        }

        #expect(tripped)
        #expect(ledger.isLockedOut)
        // The remaining time is measured from the failure that tripped it, not from
        // the first failure of the streak.
        #expect(ledger.remainingLockout(now: start) == FIDConstants.lockoutDuration)
    }

    @Test("Remaining lockout counts down as time passes")
    func countsDown() {
        var ledger = AttemptLedger()
        for _ in 1...FIDConstants.maxFailedAttempts {
            ledger.recordFailure(now: start)
        }

        let later = start.addingTimeInterval(20)
        #expect(ledger.remainingLockout(now: later) == FIDConstants.lockoutDuration - 20)
    }

    @Test("An expired lockout clears itself the moment it is read")
    func expiryClearsOnRead() {
        var ledger = AttemptLedger()
        for _ in 1...FIDConstants.maxFailedAttempts {
            ledger.recordFailure(now: start)
        }

        let afterWindow = start.addingTimeInterval(FIDConstants.lockoutDuration + 1)
        #expect(ledger.remainingLockout(now: afterWindow) == nil)
        // Reading is what ends it — a stale `lockedOutUntil` would otherwise keep
        // reporting a lockout that no longer applies.
        #expect(ledger.isLockedOut == false)
        #expect(ledger.failedAttempts == 0)
    }

    @Test("A success wipes the streak, so spread-out failures never compound")
    func successResets() {
        var ledger = AttemptLedger()
        for _ in 1..<FIDConstants.maxFailedAttempts {
            ledger.recordFailure(now: start)
        }
        ledger.recordSuccess()
        #expect(ledger.failedAttempts == 0)

        // A full streak is needed again from zero.
        var tripped = false
        for _ in 1..<FIDConstants.maxFailedAttempts {
            tripped = ledger.recordFailure(now: start)
        }
        #expect(tripped == false)
        #expect(ledger.isLockedOut == false)
    }

    @Test("Success clears an active lockout")
    func successClearsLockout() {
        var ledger = AttemptLedger()
        for _ in 1...FIDConstants.maxFailedAttempts {
            ledger.recordFailure(now: start)
        }
        #expect(ledger.isLockedOut)

        ledger.recordSuccess()
        #expect(ledger.isLockedOut == false)
        #expect(ledger.remainingLockout(now: start) == nil)
    }
}
