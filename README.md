<div align="center">

# Face ID

<img src="https://img.shields.io/badge/platform-macOS%2015%2B-000000?style=flat-square" alt="macOS 15+">
<img src="https://img.shields.io/badge/swift-6-F5A623?style=flat-square" alt="Swift 6">
<img src="https://img.shields.io/badge/license-MIT-green?style=flat-square" alt="MIT License">
<img src="https://img.shields.io/badge/界面-简体中文-blue?style=flat-square" alt="简体中文">

**给 Mac 一个「看一眼就解锁」的体验** —— 整机刷脸解锁 + 单个 App 加锁，全部在设备端完成。

[下载 v1.0](https://github.com/joe0515/face-id/releases/latest) · [功能](#功能) · [安装](#安装) · [构建](#构建)

</div>

---

## 🙏 致谢

这个项目**不是从零写出来的**，它站在两个优秀的开源项目之上：

| 项目 | 作者 | 许可 | 取自它什么 |
|---|---|---|---|
| [**glance**](https://github.com/jonnyoo/glance) | Jonathan Zhou | MIT | 刘海（Dynamic Island）界面与整机刷脸解锁 |
| [**FaceGate-Mac**](https://github.com/dweep-desai/FaceGate-Mac) | Dweep Desai | MIT | 应用加锁内核（锁定规则、隐藏应用、认证阶梯） |

**感谢 Jonathan Zhou 与 Dweep Desai 把这么完整的作品以 MIT 许可开源出来。** 没有这两份代码就不会有这个应用 —— 我们做的绝大部分工作是「把两者合并到同一套内核之下」。两份许可证要求的版权声明已收录在 [`LICENSE`](LICENSE) 中。

> 请到上游仓库为作者点个 star：[jonnyoo/glance](https://github.com/jonnyoo/glance) · [dweep-desai/FaceGate-Mac](https://github.com/dweep-desai/FaceGate-Mac)

---

## 功能

| 能力 | 说明 |
|---|---|
| **整机解锁** | 唤醒 / 锁屏时看一眼，验证通过自动输入系统密码 |
| **应用加锁** | 指定 App 被打开或切到前台时，**隐藏该应用**并弹出人脸验证；通过后恢复，取消则结束该 App |
| **认证阶梯** | 人脸 → 触控 ID → 应用密码，任一级通过即可 |
| **人脸录入** | 11 个姿势 × 2 帧 + 远 / 中 / 近三档距离，共 22 个样本，阈值按嵌入器自动取表 |
| **隐私** | 全程设备端，帧只在内存中处理，人脸数据不落盘、不联网 |
| **刘海 UI** | 提示、引导、挑战都呈现在刘海面板（Dynamic Island 风格），不另开窗口 |

---

## 安装

1. 下载 [Face ID 1.0.dmg](https://github.com/joe0515/face-id/releases/latest)，把 **Face ID** 拖进「应用程序」
2. 首次打开若提示「无法验证开发者」：**右键 → 打开**（本包为 ad-hoc 签名，未做公证）
3. 按刘海引导完成授权（摄像头、**辅助功能**）并录入人脸 —— **授权后请退出并重新打开 Face ID**，TCC 的授权结果在进程启动时固定，重启才生效

> 系统设置里那个「辅助功能」其实是**两个独立授权项**（读取窗口 / 发送按键事件），应用会分别显示它们的状态。

---

## 使用须知

- **重启或重装后需要一次触控 ID / 登录密码**：人脸模板用只存在于内存的会话密钥加密，进程重启后要先解锁会话，之后整段会话内刷脸可用。
- **Esc 是逃生口**：在遮罩或刘海面板按 Esc 表示放弃，**会直接结束**被锁的 App；认证失败则保持锁定，悬停面板可重开一轮。
- **暂停与退出要验证身份**：状态栏菜单里的「暂停应用加锁」「退出 Face ID」需通过触控 ID 或登录密码。
- **已知边界**：锁定时被锁的应用会被**整体隐藏**（这是有意为之 —— 只有 `hide()` 能在应用被激活的同一轮就生效，窗口级遮罩总有几帧会让内容先露出来）；因关闭 App Sandbox 并依赖辅助功能与私有 SkyLight API，**不能上架 App Store**。
- **ad-hoc 签名的代价**：每次重新编译 cdhash 都会变，辅助功能与钥匙串授权需重新勾选。用 `TEAM_ID=… make release` 真实团队签名可解除。

---

## 构建

```bash
make build      # Debug 构建
make test       # 单元测试（57 用例 / 9 套件）
make release    # Release 构建 + DMG → build/dist/
```

用真实团队签名（可解除上面的授权失效问题）：

```bash
TEAM_ID=XXXXXXXXXX make release
```

要求 macOS 15.0+ / Xcode 26+。若构建报 `sandbox-exec` 相关错误或 `@Observable` 宏无法展开，是本机无法应用编译器沙箱所致，`make` 默认已带上适配（`SANDBOX_FIX=0` 可关闭）。

---

## 结构

```
Face ID.xcodeproj
├── FaceID/                源码根
│   ├── App/               入口、AppDelegate、AppEnvironment、Updater
│   ├── Domain/            领域层（Face / Liveness / Camera / Security /
│   │                      SystemUnlock / System / AppLock）
│   ├── Coordination/      编排层（解锁、认证、摄像头仲裁）
│   ├── UI/                Notch / Shield / AppLock / Onboarding / Settings / FaceLab
│   ├── Constants/         FIDConstants（常量单一真源）
│   └── Models · Resources · Assets.xcassets
├── FaceIDTests/           单元测试（Swift Testing）
├── Makefile · scripts/package-dmg.sh
└── docs/                  实现计划书 · 验收测试清单
```

---

## 文档

- [`docs/Face ID 项目实现计划书.md`](docs/Face%20ID%20项目实现计划书.md) —— 完整设计与实施记录
- [`docs/验收测试清单.md`](docs/验收测试清单.md) —— 真机目视验收（12 组 92 条 + R1–R22）

单元测试只覆盖纯逻辑与时序；窗口服务器、TCC 权限、摄像头与跨进程行为需按清单目视验收。

---

## 许可

本项目以 **MIT** 许可发布，合并自两个同样以 MIT 许可发布的项目：

- **glance** © 2026 Jonathan Zhou — MIT
- **FaceGate-Mac** © 2026 Dweep Desai — MIT

> ⚠️ *Face ID* 为 Apple 注册商标。个人 / 开源自用无碍，商业化分发建议改名。
