//
//  POCController.swift
//  Face ID
//
//  Orchestration for credential storage: wires SecureCredentialManager to
//  KeystrokeInjector and exposes session/password status for Settings.
//

import Foundation
import Observation

@Observable
@MainActor
final class POCController {
    var accessibilityGranted: Bool = KeystrokeInjector.isAccessibilityTrusted()

    var hasStoredPassword: Bool = SecureCredentialManager.hasStoredPassword()
    var isSessionUnlocked: Bool = SecureCredentialManager.isSessionUnlocked
    var sessionError: String? = nil

    /// Bound to the setup SecureField. Cleared immediately after a successful save.
    var passwordInput: String = ""

    var statusMessage: String = "空闲"

    func refreshAccessibilityStatus() {
        accessibilityGranted = KeystrokeInjector.isAccessibilityTrusted()
    }

    func requestAccessibility() {
        KeystrokeInjector.promptForAccessibility()
    }

    func refreshCredentialStatus() {
        hasStoredPassword = SecureCredentialManager.hasStoredPassword()
        isSessionUnlocked = SecureCredentialManager.isSessionUnlocked
    }

    // MARK: - Session (Touch ID gate)

    /// Must succeed before `savePassword()` or `injectStoredPassword()` will do anything.
    func unlockSession() async {
        sessionError = nil
        do {
            try await Task.detached(priority: .userInitiated) {
                try await SecureCredentialManager.unlockSession(reason: "验证身份以设置或使用 Face ID")
            }.value
            isSessionUnlocked = true
        } catch {
            isSessionUnlocked = false
            sessionError = error.localizedDescription
        }
    }

    func lockSession() {
        SecureCredentialManager.lockSession()
        isSessionUnlocked = false
    }

    // MARK: - Setup flow

    /// Encrypts and stores `passwordInput`. Requires the session to already
    /// be unlocked (Touch ID happens in `unlockSession()`, not here).
    func savePassword() async {
        guard !passwordInput.isEmpty else {
            statusMessage = "请先输入密码。"
            return
        }
        let plaintext = passwordInput
        passwordInput = ""

        do {
            try await Task.detached(priority: .userInitiated) {
                guard var bytes = plaintext.data(using: .utf8) else {
                    throw SecureCredentialError.emptyPassword
                }
                defer { bytes.resetBytes(in: 0..<bytes.count) }
                try SecureCredentialManager.savePassword(bytes)
            }.value
            statusMessage = "密码已保存并加密。"
            hasStoredPassword = true
        } catch {
            statusMessage = "保存失败：\(error.localizedDescription)"
        }
    }

    // MARK: - Injection

    /// Reads + decrypts + injects the stored password, zeroing the plaintext
    /// buffer before returning. When `requireAuthoritativeLock` is true (the
    /// auto-trigger path), refuses to inject unless the CGSession dictionary
    /// confirms the screen is actually locked.
    ///
    /// - Returns: whether the keystrokes were actually posted. The caller shows the
    ///   success animation **before** calling this (injecting is what unlocks the Mac,
    ///   which tears the panel down), so it needs to know when to walk that back.
    @discardableResult
    func injectStoredPassword(requireAuthoritativeLock: Bool = false) async -> Bool {
        guard KeystrokeInjector.isAccessibilityTrusted() else {
            statusMessage = "未获得辅助功能权限 —— 请在系统设置中启用 Face ID。"
            return false
        }
        guard SecureCredentialManager.isSessionUnlocked else {
            statusMessage = "会话已锁定 —— 请先用触控 ID 验证。"
            return false
        }

        if requireAuthoritativeLock {
            guard LockMonitor.isScreenActuallyLocked() else {
                statusMessage = "已跳过：CGSession 报告屏幕并未真正锁定。"
                return false
            }
        }

        // 读密码走的是钥匙串里**另一个**条目，它的 ACL 与本构建的 cdhash 未必匹配。
        // 一旦在这里读，系统会当场弹「想要使用你储存在钥匙串的…」并要求输入登录密码
        // —— 而它出现在扫脸成功之后，且我们持有 key window 时那个框可能收不到键盘
        // （现场表现：密码框弹出，但打不了字）。所以宁可这次不注入，也不能把它弹出来。
        guard !KeychainTrust.needsAuthorization else {
            UnlockDiagnostics.log("injectStoredPassword: 钥匙串尚未对本构建授权，拒绝读取（避免扫脸后弹出无法输入的密码框）")
            statusMessage = "需要先授权钥匙串访问 —— 请登录后从菜单栏「需要授权…」完成，选择「始终允许」。"
            return false
        }

        statusMessage = "正在输入…"
        do {
            try await Task.detached(priority: .userInitiated) {
                var bytes = try SecureCredentialManager.readPassword()
                defer { bytes.resetBytes(in: 0..<bytes.count) }
                try KeystrokeInjector.typeAndReturn(bytes)
            }.value
            statusMessage = "已在 \(Date().formatted(date: .omitted, time: .standard)) 输入存储的密码并回车"
            return true
        } catch {
            statusMessage = "输入失败：\(error.localizedDescription)"
            return false
        }
    }
}
