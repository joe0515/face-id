//
//  AppEnvironment.swift
//  Face ID
//
//  Owns app-wide, long-lived controllers so Settings pages share one instance instead of racing duplicates.
//

import Foundation
import Observation

@Observable
@MainActor
final class AppEnvironment {
    let pocController = POCController()
    let faceLabController = FaceLabController()
    let faceUnlockCoordinator: FaceUnlockCoordinator
    /// Held, not just constructed — owns a repeating timer that would silently stop enforcing auto-lock if deallocated.
    let sessionAutoLocker: SessionAutoLocker
    /// Constructed here (not started) so the About page and `AppDelegate` share one instance; `AppDelegate` calls `updater.start()`.
    let updater = UpdaterController()

    /// Only one feature may capture at a time. Re-exposed here (same instance as
    /// `CameraArbiter.shared`) so construction sites read as dependency flow
    /// rather than reaching for a global — see `CameraArbiter`'s header.
    let cameraArbiter = CameraArbiter.shared

    /// Covers a locked app's windows, or hides it when covering can't be trusted.
    let windowShieldManager = WindowShieldManager.shared

    /// Application-level locking: detection → shield → challenge → authentication.
    /// Held (not just constructed) so the challenge survives as long as the app does.
    let appUnlockCoordinator: AppUnlockCoordinator

    /// Revealed by tapping the app icon 5 times on the About page. Plain in-memory `var` so it resets on every relaunch.
    var isDebugSectionRevealed = false

    init() {
        faceUnlockCoordinator = FaceUnlockCoordinator(pocController: pocController, cameraArbiter: cameraArbiter)
        sessionAutoLocker = SessionAutoLocker(pocController: pocController)

        // Its own camera and pipeline, not FaceUnlockCoordinator's: the two run in
        // different situations and `CameraArbiter` is what keeps them off the device
        // simultaneously. Sharing the objects would buy nothing and couple the paths.
        let authenticationCoordinator = AuthenticationCoordinator(
            camera: CameraManager(),
            pipeline: FaceRecognitionPipeline(),
            cameraArbiter: cameraArbiter,
            touchID: TouchIDAuth.shared
        )
        appUnlockCoordinator = AppUnlockCoordinator(
            monitor: .shared,
            locker: .shared,
            shield: windowShieldManager,
            notch: .shared,
            store: .shared,
            auth: authenticationCoordinator,
            cameraArbiter: cameraArbiter,
            passwordPrompt: ChallengePasswordPanel()
        )
    }
}
