//
//  NoticeView.swift
//  Face ID
//
//  The plain-text body of `NotchOverlayController.Phase.notice`.
//
//  Used when the unlock path cannot proceed and the reason is something the user has
//  to deal with away from the lock screen. The panel is the only surface of ours that
//  is visible on the login window, so a sentence there is the difference between
//  "this feature is in a state" and "this feature is broken".
//

import SwiftUI

struct NoticeView: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(.white.opacity(0.92))
            .multilineTextAlignment(.center)
            .lineLimit(4)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .center)
    }
}

#Preview {
    ZStack {
        Color.black.ignoresSafeArea()
        NoticeView(text: "Face ID 已更新，需要重新授权钥匙串访问。请登录后从菜单栏「需要授权…」进入，在系统弹窗里选择「始终允许」。")
            .padding()
    }
    .frame(width: 420, height: 160)
}
