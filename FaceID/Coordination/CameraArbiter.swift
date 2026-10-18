//
//  CameraArbiter.swift
//  Face ID
//
//  Exactly one feature may capture from the camera at a time.
//
//  Five features each own — or will own — a `CameraManager` on the same device:
//  the lock-screen scanner, app locking, first-run enrollment, the Face Lab, and
//  the Settings preview. Two live `AVCaptureSession`s with different formats on
//  one device produce "camera in use" failures and a visibly flapping capture, so
//  every one of them must take a lease here before calling `camera.start()`.
//
//  This is a *priority lease*, not a queue. A arriving owner with a higher
//  priority preempts the current one by invoking its registered stopper; an
//  owner that can't preempt simply gets `false` and skips that cycle, letting its
//  own timeout/retry handling deal with "try again shortly".
//
//  A process-wide singleton is deliberate: the camera is a process-wide hardware
//  resource, and the owners include static factory paths (onboarding) and SwiftUI
//  views that have no natural injection point. `AppEnvironment.cameraArbiter`
//  re-exposes it so dependency flow stays readable in construction sites.
//

import Foundation
import Observation

@Observable
@MainActor
final class CameraArbiter {

    /// One instance for the whole process — see the file header for why.
    static let shared = CameraArbiter()

    /// Every feature that can hold the camera.
    enum Owner: String, CaseIterable {
        /// Lock-screen / wake face unlock. This is the login path: the user can
        /// be shut out of their Mac without it, so nothing may preempt it.
        case systemUnlock
        /// First-run face enrollment.
        case onboarding
        /// Face-gating an app the user asked to keep locked.
        case appLock
        /// The hidden debug console.
        case faceLab
        /// The live camera preview in Settings.
        case preview

        /// Higher wins. `systemUnlock` deliberately outranks everything, including
        /// enrollment: a lock that lands mid-enrollment must still be able to unlock.
        var priority: Int {
            switch self {
            case .systemUnlock: return 40
            case .onboarding: return 30
            case .appLock: return 20
            case .faceLab: return 10
            case .preview: return 5
            }
        }

        var displayName: String {
            switch self {
            case .systemUnlock: return "整机解锁"
            case .onboarding: return "人脸录入"
            case .appLock: return "应用加锁"
            case .faceLab: return "Face Lab"
            case .preview: return "相机预览"
            }
        }
    }

    /// Who holds the camera right now, if anyone. Exposed for diagnostics/Face Lab.
    private(set) var currentOwner: Owner?

    /// How an owner is force-released. **Contract:** a stopper stops the hardware
    /// (cancel any scan, `camera.stop()`). It may also call `release(_:)` — the
    /// arbiter reassigns ownership immediately after the stopper returns, so
    /// releasing from inside one is harmless and is the common case.
    @ObservationIgnored private var stoppers: [Owner: () -> Void] = [:]

    private init() {}

    // MARK: - Registration

    /// Registers the closure the arbiter calls to take the camera away from
    /// `owner`. Must be idempotent and safe to call at any time.
    func register(_ owner: Owner, stopper: @escaping () -> Void) {
        stoppers[owner] = stopper
    }

    func unregister(_ owner: Owner) {
        stoppers[owner] = nil
        if currentOwner == owner { currentOwner = nil }
    }

    // MARK: - Lease

    /// True when the camera is free, or `owner` already holds it.
    func isAvailable(to owner: Owner) -> Bool {
        currentOwner == nil || currentOwner == owner
    }

    func isHeld(by owner: Owner) -> Bool {
        currentOwner == owner
    }

    /// Requests the camera for `owner`.
    ///
    /// - Returns: `true` if `owner` now holds it. `false` means a holder of equal
    ///   or higher priority wouldn't yield — the caller must **not** start a
    ///   second session, and should skip this cycle.
    @discardableResult
    func acquire(_ owner: Owner) -> Bool {
        guard let holder = currentOwner, holder != owner else {
            currentOwner = owner
            return true
        }
        guard owner.priority > holder.priority else { return false }
        stoppers[holder]?()
        currentOwner = owner
        return true
    }

    /// Gives the camera back. No-op unless `owner` is the current holder, so a
    /// late release from a preempted owner can't clobber the new holder.
    func release(_ owner: Owner) {
        guard currentOwner == owner else { return }
        currentOwner = nil
    }

    /// Drops whatever is running — app termination, or a hard reset.
    func releaseAll() {
        if let holder = currentOwner { stoppers[holder]?() }
        currentOwner = nil
    }
}
