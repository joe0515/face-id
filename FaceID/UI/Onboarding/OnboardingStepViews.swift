//
//  OnboardingStepViews.swift
//  Face ID
//
//  The screens of the notch-hosted onboarding flow. Each fills whatever panel size
//  OnboardingController reports for its step — sizing itself is the notch window's job.
//

import SwiftUI
import AppKit

// MARK: - 1. Intro

struct IntroStepView: View {
    let controller: OnboardingController

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Face ID")
                    .font(FIDTheme.Font.title)
                    .foregroundStyle(FIDTheme.textPrimary)
                Text("Mac 上的人脸解锁")
                    .font(FIDTheme.Font.button)
                    .foregroundStyle(FIDTheme.textSecondary)

                Spacer(minLength: 12)

                PillButton(title: "下一步") {
                    controller.advance()
                }
            }
            .padding(.leading, 4)
            Spacer(minLength: 4)
            FaceIDLogoView()
                .frame(width: 106, height: 106)
                .padding(.top, 4)
        }
        .onboardingContentPadding()
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(FIDTheme.panel)
        .onAppear {
            controller.playIntroSweepIfNeeded()
        }
    }
}

private struct FaceIDLogoView: View {
    var body: some View {
        // Video already bakes in its own white rounded-card background — no extra chrome needed.
        LoopingVideoView(resourceName: "logoanimation")
    }
}

// MARK: - 2. Permissions

struct PermissionsStepView: View {
    let controller: OnboardingController

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("权限")
                .font(FIDTheme.Font.title)
                .foregroundStyle(FIDTheme.textPrimary)
                .padding(.leading, 4)

            // Spacer(minLength: 0)

            PermissionRow(
                title: "辅助功能",
                detail: "允许 Face ID 解锁你的 Mac",
                granted: controller.accessibilityGranted
            ) { controller.grantAccessibility() }

            PermissionRow(
                title: "摄像头",
                detail: "允许 Face ID 识别你的人脸",
                granted: controller.cameraPermission == .granted
            ) { controller.grantCamera() }

            // Spacer(minLength: 0)

            HStack(spacing: 10) {
                PillButton(title: "返回", style: .secondary) {
                    controller.back()
                }
                PillButton(title: "下一步", isEnabled: controller.bothPermissionsGranted) {
                    controller.advance()
                }
            }
        }
        .onboardingContentPadding()
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(FIDTheme.panel)
    }
}

// MARK: - 2b. Permission review (launch-time replay)

/// What a user sees at launch when a grant went missing — after a reinstall, a
/// `tccutil reset`, or a rebuild that changed the ad-hoc cdhash.
///
/// Same panel, same rows, same wording as the first-run step. Two differences, both
/// deliberate: Accessibility is split into its two real privileges (the first-run
/// step only asks whether the process is trusted at all), and the footer offers no
/// way forward into setup — there is nothing left to set up.
struct PermissionReviewStepView: View {
    let controller: OnboardingController

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("权限")
                .font(FIDTheme.Font.title)
                .foregroundStyle(FIDTheme.textPrimary)
                .padding(.leading, 4)

            Text("这些权限没打开时，被锁定的应用可能直接显示出来。")
                .font(FIDTheme.Font.rowDetail)
                .foregroundStyle(FIDTheme.textDetail)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.leading, 4)

            // 「辅助功能」在系统设置里是**同一个列表、同一个勾选框**，却对应 TCC 的两个
            // 独立授权项。分成两行会让用户以为要授权两次（也确实会连点两次「授权」），
            // 所以这里合并成一行：点一次请求缺失的那一项，状态文案说清还缺什么。
            PermissionRow(
                title: "辅助功能",
                detail: controller.accessibilityDetail,
                granted: controller.accessibilityPrivileges.isFullyGranted
            ) { controller.grantMissingAccessibility() }

            PermissionRow(
                title: "摄像头",
                detail: "刷脸验证（缺了改用触控 ID）",
                granted: controller.cameraPermission == .granted
            ) { controller.grantCamera() }

            // One caption slot, two possible sources (see `permissionReviewHint`).
            // Both rows of Accessibility live in one System Settings list, so "I ticked
            // the box" reads as one permission while TCC counts two — which is why this
            // has to name the place instead of just saying "grant it".
            if let hint = controller.permissionReviewHint {
                Text(hint)
                    .font(FIDTheme.Font.rowDetail)
                    .foregroundStyle(FIDTheme.textDetail)
                    // Two lines is what the height allowance covers — see
                    // `permissionReviewHintHeight`. Unbounded wrapping here is what clipped
                    // the longer "restart to take effect" hint against the panel bottom.
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, 4)
            }

            HStack(spacing: 10) {
                // TCC decisions are pinned at launch, so granting without relaunching
                // changes nothing — this is the button that actually makes it stick.
                PillButton(title: "重启生效", style: .secondary) {
                    AppRelauncher.relaunch()
                }
                PillButton(title: "完成", isDefault: true) {
                    controller.finishPermissionReview()
                }
            }
        }
        .onboardingContentPadding()
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(FIDTheme.panel)
    }
}

// MARK: - 3. Security notice

struct SecurityNoticeStepView: View {
    let controller: OnboardingController

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Image(systemName: "exclamationmark.circle.fill")
                .font(.system(size: 40, weight: .semibold))
                .foregroundStyle(FIDTheme.textPrimary)
                .padding(.top, 25)
                .padding(.leading, 4)

            Text("Face ID 的安全性不如 Apple 的 Face ID 或触控 ID。")
                .font(FIDTheme.Font.title)
                .foregroundStyle(FIDTheme.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.leading, 4)

            Text("它使用 Mac 自带的普通摄像头，为便利而设计，并非高安全性认证。")
                .font(FIDTheme.Font.passwordCaption)
                .foregroundStyle(FIDTheme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.leading, 4)
                .padding(.bottom, 10)

            HStack(spacing: 10) {
                if controller.isPostUpdateNotice {
                    // Declining isn't a real option here — see `declinePostUpdateNotice()`.
                    PillButton(title: "不用了", style: .secondary) {
                        controller.declinePostUpdateNotice()
                    }
                } else {
                    PillButton(title: "返回", style: .secondary) {
                        controller.back()
                    }
                }
                PillButton(title: "我明白了", isDefault: true) {
                    controller.advance()
                }
            }
        }
        .onboardingContentPadding()
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(FIDTheme.panel)
    }
}

// MARK: - 4. Pre set-up

struct PreSetupStepView: View {
    let controller: OnboardingController

    var body: some View {
        VStack(spacing: 2) {
            HStack(alignment: .top, spacing: 2) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("设置\n人脸识别")
                        .font(FIDTheme.Font.title)
                        .foregroundStyle(FIDTheme.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)

                    Text("按照屏幕上的\n提示操作")
                        .font(FIDTheme.Font.button)
                        .foregroundStyle(FIDTheme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.top, 10)
                .padding(.leading, 4)
                Spacer(minLength: 0)
                UnlockGlyphView()
                    .frame(width: 120, height: 120)
            }
            Spacer(minLength: 4)

            HStack(spacing: 10) {
                PillButton(title: "返回", style: .secondary) {
                    controller.back()
                }
                PillButton(title: "下一步") {
                    controller.advance()
                }
            }
        }
        .onboardingContentPadding()
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(FIDTheme.panel)
    }
}

private struct UnlockGlyphView: View {
    var body: some View {
        LoopingVideoView(resourceName: "idleanimation")
    }
}

// MARK: - 5. Select camera

struct SelectCameraStepView: View {
    let controller: OnboardingController

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("选择摄像头")
                .font(FIDTheme.Font.title)
                .foregroundStyle(FIDTheme.textPrimary)
                .padding(.leading, 4)
                .padding(.top, 14)

            Text("用于人脸录入和解锁 Mac")
                .font(FIDTheme.Font.passwordCaption)
                .foregroundStyle(FIDTheme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.leading, 4)

            Spacer(minLength: 2)

            CameraSelectionPill(
                label: controller.cameraSelectionLabel,
                devices: controller.cameraDevices
            ) { id in
                controller.selectCamera(id: id)
            }

            Spacer(minLength: 4)

            HStack(spacing: 10) {
                PillButton(title: "返回", style: .secondary) {
                    controller.back()
                }
                PillButton(title: "下一步") {
                    controller.advance()
                }
            }
        }
        .onboardingContentPadding()
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(FIDTheme.panel)
        .onAppear {
            controller.refreshCameraDevices()
            controller.applyDisplayPinForCameraSelection()
        }
    }
}

// MARK: - 6-8. Guided enrollment (camera + tick ring + camera-complete)

struct EnrollStepView: View {
    let controller: OnboardingController
    @Environment(\.notchPanelStyle) private var style

    var body: some View {
        VStack(spacing: 0) {
            cameraCluster
                .padding(.top, cameraTopPadding)
            Spacer(minLength: 8)
            instructionLabel
                .padding(.horizontal, OnboardingMetrics.enrollInstructionHorizontalPadding)
                .padding(.bottom, OnboardingMetrics.enrollInstructionBottomPadding)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay(alignment: .topTrailing) {
            if showsCloseButton {
                EnrollmentCloseButton {
                    controller.back()
                }
                .padding(OnboardingMetrics.enrollCloseButtonEdgePadding)
            }
        }
        .background(FIDTheme.panel)
    }

    private var showsCloseButton: Bool {
        !controller.enrollmentComplete && !controller.showCheckmark
    }

    private var cameraTopPadding: CGFloat {
        style == .pill
            ? OnboardingMetrics.enrollCameraTopPaddingPill
            : OnboardingMetrics.enrollCameraTopPaddingNotch
    }

    private var cameraCluster: some View {
        ZStack {
            EnrollmentRingView(controller: controller)

            CameraPreviewView(session: controller.camera.session, faces: [])
                .frame(
                    width: OnboardingMetrics.cameraCircleDiameter,
                    height: OnboardingMetrics.cameraCircleDiameter
                )
                .clipShape(Circle())
                .opacity(controller.cameraPreviewVisible ? 1 : 0)
                .animation(
                    .easeInOut(duration: OnboardingMetrics.previewFadeOut),
                    value: controller.cameraPreviewVisible
                )
                .overlay {
                    if controller.isTooFar && controller.cameraPreviewVisible && !controller.showCheckmark {
                        EnrollmentTooFarChevron()
                            .transition(.opacity)
                    }
                }
                .animation(.easeInOut(duration: 0.2), value: controller.isTooFar)

            if controller.showCheckmark {
                AnimatedCheckmark(color: FIDTheme.accent, lineWidth: 8)
                    .frame(width: 70, height: 59)
                    .transition(.opacity)
                    .padding(.top, 4)
            }
        }
        .frame(
            width: OnboardingMetrics.enrollCameraClusterDiameter,
            height: OnboardingMetrics.enrollCameraClusterDiameter
        )
    }

    private var instructionLabel: some View {
        Text(controller.enrollmentInstruction)
            .font(FIDTheme.Font.instruction)
            .foregroundStyle(.white)
            .multilineTextAlignment(.center)
            .lineLimit(2)
            .minimumScaleFactor(0.8)
            .id(controller.enrollmentInstruction)
            .transition(.opacity)
            .animation(.easeInOut(duration: 0.2), value: controller.enrollmentInstruction)
            .opacity(controller.guideVisible ? 1 : 0)
            .animation(
                .easeInOut(
                    duration: controller.guideVisible
                        ? OnboardingMetrics.enrollInstructionFadeIn
                        : OnboardingMetrics.enrollInstructionFadeOut
                ),
                value: controller.guideVisible
            )
    }
}

private struct EnrollmentCloseButton: View {
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: "xmark")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white.opacity(isHovering ? 1 : 0.8))
                .frame(
                    width: OnboardingMetrics.enrollCloseButtonSize,
                    height: OnboardingMetrics.enrollCloseButtonSize
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .accessibilityLabel("关闭")
    }
}

private struct EnrollmentTooFarChevron: View {
    var body: some View {
        Image(systemName: "chevron.up.2")
            .font(.system(size: OnboardingMetrics.enrollTooFarChevronSize, weight: .semibold))
            .foregroundStyle(.white)
            .shadow(color: .black.opacity(0.45), radius: 6, y: 1)
            .symbolEffect(.bounce.up.byLayer, options: .repeating)
            .accessibilityHidden(true)
    }
}

// MARK: - 9. Name

/// Asks who was just captured — for a recapture, pre-filled with the existing name so
/// this doubles as rename.
struct NameStepView: View {
    @Bindable var controller: OnboardingController

    private var trimmedName: String {
        controller.pendingName.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("给这张人脸命名")
                .font(FIDTheme.Font.title)
                .foregroundStyle(FIDTheme.textPrimary)
                .padding(.leading, 4)

            Text("当这台 Mac 上录入了多个人脸时，用它来区分。")
                .font(FIDTheme.Font.passwordCaption)
                .foregroundStyle(FIDTheme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.leading, 4)

            Spacer(minLength: 2)

            PillTextField(placeholder: "输入名称…", text: $controller.pendingName, autofocus: true) {
                controller.confirmName()
            }

            if let error = controller.nameError {
                Text(error)
                    .font(FIDTheme.Font.rowDetail)
                    .foregroundStyle(FIDTheme.statusDenied)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 10) {
                PillButton(title: "返回", style: .secondary) {
                    controller.back()
                }
                PillButton(title: controller.nameStepPrimaryTitle, isEnabled: !trimmedName.isEmpty, isDefault: true) {
                    controller.confirmName()
                }
            }
        }
        .onboardingContentPadding()
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(FIDTheme.panel)
    }
}

// MARK: - 10. Password

struct PasswordStepView: View {
    let controller: OnboardingController

    @State private var password = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("输入密码")
                .font(FIDTheme.Font.title)
                .foregroundStyle(FIDTheme.textPrimary)
                .padding(.leading, 4)

            Text("解锁 Mac 需要用到你的密码。它会被加密后保存在本机。Face ID 完全离线运行，密码不会离开这台 Mac。")
                .font(FIDTheme.Font.passwordCaption)
                .foregroundStyle(FIDTheme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.leading, 4)

            Spacer(minLength: 2)

            PillSecureField(placeholder: "输入密码…", text: $password, autofocus: true) {
                guard !password.isEmpty, !controller.isSavingPassword else { return }
                Task { _ = await controller.finish(password: password) }
            }

            if let error = controller.passwordError {
                Text(error)
                    .font(FIDTheme.Font.rowDetail)
                    .foregroundStyle(FIDTheme.statusDenied)
            }

            // Spacer(minLength: 0)

            HStack(spacing: 10) {
                PillButton(title: "返回", style: .secondary) {
                    controller.back()
                }
                PillButton(
                    title: controller.isSavingPassword ? "正在保存…" : "确认",
                    isEnabled: !password.isEmpty && !controller.isSavingPassword,
                    isDefault: true
                ) {
                    Task { _ = await controller.finish(password: password) }
                }
            }
        }
        .onboardingContentPadding()
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(FIDTheme.panel)
    }
}

// MARK: - 11. App locking

/// Closing screen of setup: the whole-machine unlock has just been configured, and this
/// introduces the *other* half of the product — per-app locking.
///
/// Purely informational, and deliberately so: the feature's real controls (which apps,
/// how they're presented, session length, schedule) live on the Apps settings page, and
/// duplicating a switch here would mean injecting `AppUnlockCoordinator` into a flow that
/// otherwise has no reason to know about it. The step exists so people discover the
/// feature at all — after this, Settings opens on the tab bar where "Apps" sits.
struct AppLockingStepView: View {
    let controller: OnboardingController

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Image(systemName: "lock.shield.fill")
                .font(.system(size: 34, weight: .semibold))
                .foregroundStyle(FIDTheme.textPrimary)
                .padding(.top, 18)
                .padding(.leading, 4)

            Text("也可以锁定应用")
                .font(FIDTheme.Font.title)
                .foregroundStyle(FIDTheme.textPrimary)
                .padding(.leading, 4)

            Text("当你选定的应用切到前台时，Face ID 可以要求刷脸 —— 信息、邮件，任何有窗口的应用都行。它只遮住那个应用，屏幕其余部分照常可用。")
                .font(FIDTheme.Font.passwordCaption)
                .foregroundStyle(FIDTheme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.leading, 4)

            Text("在「设置 → 应用」里挑选要锁定的应用。默认关闭，选中后才会生效。")
                .font(FIDTheme.Font.rowDetail)
                .foregroundStyle(FIDTheme.textDetail)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.leading, 4)

            Spacer(minLength: 4)

            PillButton(title: "继续") {
                controller.advance()
            }
        }
        .onboardingContentPadding()
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(FIDTheme.panel)
    }
}

// MARK: - 12. Complete

struct CompleteStepView: View {
    var body: some View {
        HStack(spacing: 12) {
            Text("全部设置完成")
                .font(FIDTheme.Font.title)
                .foregroundStyle(FIDTheme.textPrimary)
            Spacer(minLength: 4)
            AnimatedCheckmark(color: .white, lineWidth: 5)
                .frame(width: 20, height: 15)
        }
        .onboardingContentHorizontalPadding()
        .padding(.top, 18)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        .background(FIDTheme.panel)
    }
}
