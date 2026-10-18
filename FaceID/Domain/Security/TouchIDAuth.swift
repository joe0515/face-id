//
//  TouchIDAuth.swift
//  Face ID
//
//  Touch ID as the middle rung of the authentication ladder
//  (face → Touch ID → app password).
//
//  Ported from FaceGate's `TouchIDAuth`. `evaluatePolicy`'s completion-handler
//  form became the native `async` overload, so the whole ladder can be `await`ed
//  without a continuation wrapper.
//

import Foundation
import LocalAuthentication

enum TouchIDError: LocalizedError, Equatable {
    case notAvailable(String)
    case cancelled
    /// The user tapped the (hidden) fallback affordance, or the system offered
    /// device-password entry. Treated as "try a different method", not a failure.
    case fallbackRequested
    case lockedOut
    case failed(String)
    /// The owner gate (`deviceOwnerAuthentication`) could not run at all — the system
    /// has neither usable biometrics nor an account password to fall back to.
    case ownerGateUnavailable(String)

    var errorDescription: String? {
        switch self {
        case .notAvailable(let message):
            return "触控 ID 不可用：\(message)"
        case .cancelled:
            return "验证已取消"
        case .fallbackRequested:
            return "用户选择了其他验证方式"
        case .lockedOut:
            return "触控 ID 已被锁定，请稍后重试。"
        case .failed(let message):
            return "触控 ID 验证失败：\(message)"
        case .ownerGateUnavailable(let message):
            return "无法验证你的身份：\(message)"
        }
    }
}

@MainActor
final class TouchIDAuth {

    static let shared = TouchIDAuth()

    private init() {}

    // MARK: - Availability

    /// Whether this Mac has usable biometric hardware right now.
    var isAvailable: Bool {
        let context = LAContext()
        var error: NSError?
        return context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error)
    }

    /// User preference stored with the rest of the app-lock settings.
    var isEnabled: Bool {
        get { UserDefaults.standard.object(forKey: FIDConstants.Defaults.appLockTouchIDEnabled) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: FIDConstants.Defaults.appLockTouchIDEnabled) }
    }

    /// Available **and** not switched off by the user.
    var canUse: Bool { isAvailable && isEnabled }

    // MARK: - Authentication

    func authenticate(reason: String) async -> Result<Void, TouchIDError> {
        let context = LAContext()
        context.localizedCancelTitle = "取消"
        // Hide the system's "Use Password…" affordance — Face ID supplies its own
        // app-password fallback, and two competing password prompts is confusing.
        context.localizedFallbackTitle = ""

        var evalError: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &evalError) else {
            return .failure(.notAvailable(evalError?.localizedDescription ?? "Touch ID 不可用"))
        }

        do {
            try await context.evaluatePolicy(
                .deviceOwnerAuthenticationWithBiometrics,
                localizedReason: reason
            )
            return .success(())
        } catch let laError as LAError {
            switch laError.code {
            case .userCancel, .appCancel, .systemCancel:
                return .failure(.cancelled)
            case .userFallback:
                return .failure(.fallbackRequested)
            case .biometryLockout:
                return .failure(.lockedOut)
            default:
                return .failure(.failed(laError.localizedDescription))
            }
        } catch {
            return .failure(.failed(error.localizedDescription))
        }
    }

    /// "Confirm it's the owner" gate for menu actions that would otherwise undo app
    /// locking: pausing protection, and quitting.
    ///
    /// Uses `.deviceOwnerAuthentication`, so it accepts Touch ID **or** the account
    /// password. Deliberately separate from `authenticate(reason:)` above, for two
    /// reasons that both matter here:
    ///   • that one is the ladder's biometric rung and must fail rather than silently
    ///     accept the login password;
    ///   • it honors the user's "use Touch ID" switch, and a quit gate that honored
    ///     that switch could leave a Mac with no way to quit at all.
    func authenticateOwner(reason: String) async -> Result<Void, TouchIDError> {
        let context = LAContext()
        context.localizedCancelTitle = "取消"
        context.localizedFallbackTitle = "使用登录密码"

        var evalError: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &evalError) else {
            return .failure(.ownerGateUnavailable(evalError?.localizedDescription ?? "系统未配置可用的验证方式"))
        }

        do {
            try await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason)
            return .success(())
        } catch let laError as LAError {
            switch laError.code {
            case .userCancel, .appCancel, .systemCancel:
                return .failure(.cancelled)
            case .userFallback:
                return .failure(.fallbackRequested)
            case .biometryLockout:
                // `.deviceOwnerAuthentication` falls through to the account password
                // rather than locking the user out, so this only surfaces when that
                // failed too.
                return .failure(.lockedOut)
            default:
                return .failure(.failed(laError.localizedDescription))
            }
        } catch {
            return .failure(.failed(error.localizedDescription))
        }
    }
}
