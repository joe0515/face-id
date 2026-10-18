# Face ID 合并项目实现计划书

> **目标**：把 `glance-main`（刘海屏 FaceID 式整机人脸解锁）与 `FaceGate-Mac-main`（按 App 加锁）合并为**一款 macOS 应用 —— Face ID**，以 glance 的界面语言为唯一视觉体系，并把 FaceGate 的「锁定其他 App」能力完整并入。
>
> **文档定位**：完整落地计划，可直接作为开发排期、任务拆分与验收依据。
> **技术栈**：Swift / SwiftUI / AppKit / Core ML / Vision / AVFoundation，macOS 15.0+（沿用 glance 基线）。
>
> 版本 **v3.0（Phase 0–7 全部完成）** · 编制日期 2026-09-28 · 项目空间 `/Users/joe/Vibe Coding/WorkBuddy/Face ID`

---

## 实施进度

| 阶段 | 状态 | 产出 |
|---|---|---|
| **Phase 0** 工程合并与骨架 | ✅ **已完成** | `Face ID.xcodeproj` + `FaceID/` 源码根；工程/目标/产品/Bundle ID 全部改为 Face ID；目录按 §5.2 重组；新增 `Constants/FIDConstants.swift`；**构建通过（0 error）** |
| **Phase 1** 人脸内核统一 | ✅ **已完成** | `FaceRecognitionPipeline` 冻结为唯一识别入口；`CameraArbiter` 落地并接入**全部 4 个消费方**；阈值/常量收敛到 `FIDConstants`；残留 `Glance*` 文件名清理 |
| **Phase 2** 加锁能力移植 | ✅ **已完成** | `Domain/AppLock/` 七个文件 + 安全层两件；Combine → Observation 全部改造；`FID.` 键命名空间落地；新增测试 target |
| **Phase 3** 窗口级遮罩子系统 | ✅ **已完成** | `WindowTracker` / `WindowShieldPanel` / `WindowShieldView` / `WindowShieldManager`（含全屏/空间切换/定位失败的自动回落） |
| **Phase 4** 刘海 UI 融合 | ✅ **已完成** | `Content` 新增 `.appLock` + `AppLockContent`；`presentAppLock(_:onRetry:)`；`AppLockContentView`；`setScanMedia` 媒体保留规则；**40 用例 / 6 套件全绿，干净构建 0 error / 7 警告（与基线一致）** |
| **Phase 5** 编排与认证整合 | ✅ **已完成** | `AppUnlockCoordinator`（全链路串联）+ `AuthenticationCoordinator`（人脸→触控 ID→应用密码三级阶梯）+ `AttemptLedger` + `ChallengePasswordPanel`；`WindowShieldManager.shield` 改 async 并加入窗口结算；`AppLocker.block` 承接呈现权；刘海面板支持持久挑战与 Esc 逃生口；**47 用例 / 7 套件全绿，干净构建 0 error / 7 警告（与基线一致）** |
| **Phase 6** 设置与引导整合 | ✅ **已完成** | `LockedAppsSettingsPage`（总开关 / 呈现方式 / 被锁列表 / 会话时长 / 定时窗口 / 权限提示）+ `AppPickerSheet` + 菜单栏 `App Locking On·Paused·Off` 与暂停子菜单 + 引导新增 `appLocking` 步骤 |
| **Phase 7** 联调、测试、打包 | ✅ **已完成** | `Makefile`（build/test/run/release/clean）+ `scripts/package-dmg.sh`（Release + 验签 + DMG 暂存）+ `docs/验收测试清单.md`（12 组约 60 条真机验收项）；**52 用例 / 8 套件全绿，干净构建 0 error / 7 警告**；Release DMG 生成成功（14 MB） |

> ⚠️ **Phase 7 的"联调"由用户执行**：单元测试只覆盖纯逻辑与时序，凡牵涉窗口服务器、TCC 权限、摄像头、跨进程行为的部分无法自动化。计划书不再声称这些已验证，改为交付一份可执行的验收清单。

### Phase 6 实施明细

**1. 设置页不镜像任何配置**

`LockedAppsSettingsPage` 的每个值都直接读写**执行路径本身用的那几个类型**——`LockedAppsStore`、`AppLockSessionManager`、`AppScheduleManager`、`WindowShieldManager`。没有任何一项被复制进 `FIDSettings`（那是整机配置）。这样设置页与"实际执行的规则"不可能漂移。

代价是几个属性是**计算属性 + `UserDefaults`**（`sessionTimeout`、`sessionTimerFromFocus`、`requestedMode`），Observation 看不见它们变化，因此页面上用 `@State` 镜像并作为唯一写回入口。`lockWindow` / `unlockWindow` / `lockedApps` 是存储属性，直接用 `@Bindable`。

**2. 三个非显而易见的取舍**

- **选择器用 sheet 而非设置子页**：它是一次有明确终点的模态选择（"加入这几个"），且需要整窗宽度容纳几百行。
- **菜单栏暂停由 `AppMonitor` 存储**：它是真正需要遵守暂停的组件，且**自过期**——忘了点恢复也不会让 Mac 一直不设防。
- **引导新增步骤是纯说明性的**：不提供开关。真正的控制在 Apps 页，在这里复制一份开关只会让引导流程凭空依赖 `AppUnlockCoordinator`。该步骤**刻意没有 Back 按钮**——它前面的 `.password` 已在 `finish(password:)` 中提交了人脸录入，返回会二次提交、录入重复人脸。

**3. `SessionWindow` 的回退语义（本阶段唯一的真陷阱）**

"Stay unlocked for" 的档位包含两个哨兵值（`0` = 立即锁定、`-1` = 永久）。若某个已存储的秒数不在当前档位表里（例如曾经提供过 2 小时档），回退到 `allCases[0]` 会让界面读成 **"Immediately"**——比用户当初选的**严格得多**。因此回退到 `.fiveMinutes`（出厂默认），并为此单写了一条测试。

**结果**：干净构建 0 error / 7 警告（与基线一致）。

### Phase 7 实施明细

**1. `Makefile` 是 `xcodebuild` 的薄封装，不是第二套构建系统**

工程已能从 Xcode 构建，另立的构建逻辑只会成为又一个要与 `project.pbxproj` 同步的东西。两个沙箱适配开关通过 `SANDBOX_FIX`（默认开）注入，**不写入工程文件**，可用 `SANDBOX_FIX=0` 关掉以保留完整编译器隔离。

**2. 打包的签名问题是硬约束，不是可选项**

`keychain-access-groups` 权限需要真实团队标识。未签名 / ad-hoc 构建**写不进 Keychain**，会卡在引导的密码步骤——所以 `package-dmg.sh` 无 `TEAM_ID` 时明确打印"仅供本地检视"，而不是假装产出了可分发产物。

**3. 为什么不自动化"联调"**

牵涉窗口服务器、TCC 权限、摄像头、跨进程行为的部分没有可编程断言；强行写"集成测试"只会得到一批不稳定、且失败原因无法定位的用例。改为交付 `docs/验收测试清单.md`，把**每条的预期现象与失败判读**写清楚——尤其标注了两处一旦失败即属安全缺陷的条目（窗口遮罩是否真的生效、Mission Control / Space 是否露出内容）。

**结果**：`make test` 52 用例 / 8 套件全绿；`make release` Release 构建成功、DMG 14 MB。
> `hdiutil create` 在当前 beta 上有弃用提示并推荐 `diskutil image create`，但后者新于本工程 macOS 15 的下限，故保留 `hdiutil`（脚本内已注明）。

### Phase 1 实施明细

**1.1 识别入口冻结**
- 全项目仅 `FaceRecognitionPipeline` 构造 embedder（`ArcFaceEmbedder` / 回退 `VisionFeaturePrintEmbedder`），无第二套识别路径。
- FaceGate 的 `FaceAuth/*` 识别链自 Phase 0 起即未移植，无需删除。

**1.2 `CameraArbiter` 摄像头仲裁（新增 `Coordination/CameraArbiter.swift`）**
- 性质：**带优先级的租约**，非队列。`systemUnlock(40) > onboarding(30) > appLock(20) > faceLab(10) > preview(5)`；高优先级可抢占，同级/更低则返回 `false` 让调用方跳过本轮。
- 契约：`register(owner:stopper:)` 注册抢占回调；`stopper` 可安全调用 `release`（仲裁器随后立即重新指派持有者）；`release` 仅在持有者匹配时生效，避免被抢占方的迟到释放覆盖新持有者。
- 接入范围（**4/4 消费方全部接入**）：整机解锁、人脸录入、Face Lab、设置相机预览。
  - 每个 `camera.start()` 前必有 `acquire`，每个 `camera.stop()` 后必有 `release`（已脚本核验配对）。
  - 各消费方新增成对辅助方法：`stopCapture()` / `releaseCamera()` / `startCameraThroughArbiter()` / `startPreview()`。
- 作用：消除"两台 `AVCaptureSession` 抢同一设备"导致的相机占用失败与画面抖动（FaceLab 源码里原本就有相关注释）。

**1.3 阈值收敛为单一真源**
| 参数 | 收敛前 | 收敛后 |
|---|---|---|
| 匹配阈值默认值 | `FIDSettings` 0.66 / UI 档 0.63 / FaceLab 0.6 / FaceGate 0.65 | `FIDConstants.matchThreshold` = **0.63** |
| 匹配阈值档位 | UI 内联字面量 | `FIDConstants.thresholdPresets` = 0.58/0.63/0.68 |
| 人脸最小宽度默认值 | 0.21（**不落在任何档位上**） | `FIDConstants.defaultMinimumFaceWidth` = **0.19** |
| 人脸宽度档位 | UI 内联字面量 | `FIDConstants.minimumFaceWidthPresets` = 0.23/0.19/0.15 |
| 旁观者硬下限 | 0.18 字面量 | `FIDConstants.minimumProminentFaceWidthFloor` |
| 录入宽度下限 | 0.2 字面量 | `FIDConstants.enrollmentMinimumFaceWidthFloor` |
- `FIDConstants` 声明为 `nonisolated enum`——否则其 `static let` 会继承默认 `MainActor` 隔离，无法被 `nonisolated` 的识别管线读取（会产生编译警告）。

**1.4 相似度实现去重**
- 全项目仅 `FaceEmbedding.cosineSimilarity` / `l2Normalized` / `average` 一套实现，无重复。FaceGate 的 `VectorMath` 未移植，无需合并。

**1.5 附带清理**：`GlanceSettings.swift` → `FIDSettings.swift`、`GlanceTheme.swift` → `FIDTheme.swift`、`glance-logo.svg` → `faceid-logo.svg`。仅 `glanceicon.icon` 留待 Phase 6 视觉收尾。

### Phase 2 实施明细

**移植清单（`FaceID/Domain/`）**

| 新文件 | 来源 | 改造要点 |
|---|---|---|
| `AppLock/LockedApp.swift` | Models/LockedApp | 保留手写 `init(from:)`（缺 `isLocked` 时 fail-safe 为 true）；`iconCache` 标 `@MainActor` |
| `AppLock/LockedAppsStore.swift` | Core/LockedAppsManager | `@Observable`；`private(set) lockedApps` + 显式 mutator；注入 `UserDefaults`；新增 `overrideNotifier` 缝 |
| `AppLock/AppLockSessionManager.swift` | Core/SessionManager | 改名以区别于 `SessionAutoLocker`；注入 `store` + `defaults`；计时器回调改 `Task { @MainActor }` |
| `AppLock/AppScheduleManager.swift` | Core/AppScheduleManager | Combine → Observation；5 个散标量/窗口收敛为 `ScheduleWindow` 值类型；去掉 50ms debounce |
| `AppLock/AppMonitor.swift` | Core/AppMonitor | `@Observable`；回调改闭包属性；`MainActor.assumeIsolated` 用于 `.main` 队列通知；暂停保护改为可读写的静态 API |
| `AppLock/AppLocker.swift` | Core/AppLocker | **移除 `showOverlays`/`AuthOverlayPanel`**（Phase 3/4 接管呈现）；`terminate()` 兜底改 `Task.sleep` |
| `AppLock/InstalledAppsScanner.swift` | Utilities/InstalledAppsScanner | `@MainActor`；排除项改 `FIDConstants.bundleIdentifier`；图标缩略图改 `NSImage(size:flipped:drawingHandler:)` |
| `Security/TouchIDAuth.swift` | Auth/TouchIDAuth | 改 `async`（用 `evaluatePolicy` 原生 async 重载）；`TouchIDError` 加 `Equatable`；默认启用（原为关闭，避免"人脸失败即锁死"） |
| `Security/AppPasswordAuth.swift` | Auth/PasswordAuth | 改用 `KeychainManager`（弃 `KeychainHelper`）；`CommonCrypto` → `CryptoKit`；`enum` + 静态方法 |

**刻意不移植**（避免与 glance 重复实现，符合 P5 单一真源）

| 未移植 | 原因 |
|---|---|
| `Utilities/CryptoHelper.swift` | `SecureCredentialManager` 已提供通用 AES-GCM 加解密；再引入一套即是重复实现 |
| `Utilities/KeychainHelper.swift` | `KeychainManager` 是其超集（含 Touch ID 访问控制） |
| `Utilities/VectorMath.swift` | `FaceEmbedding.cosineSimilarity/l2Normalized` 已覆盖 |
| `Auth/AuthenticationManager.swift` | 延后至 Phase 5，改写为 `Coordination/AuthenticationCoordinator` |
| `Core/GlobalHotkeyManager.swift` | P2 优先级，且依赖 `AppDelegate.shared` 单例；延后至 Phase 6 与菜单栏一并处理 |
| `ML/FaceEmbedding.mlmodelc` | 人脸内核已统一到 ArcFace |

**键与账号集中化（`FIDConstants` 新增）**
- `Defaults` 嵌套枚举收纳全部 UserDefaults 键（`FID.appLock.*`、`FID.launchAtLogin`），调用点零字面量。
- `KeychainAccount` 收纳 `appPasswordHash` / `appPasswordSalt`。
- 定时窗口以两个 JSON blob 持久化（`FID.appLock.schedule.lock` / `.unlock`），不再拆 10 个标量键。

**测试基础设施（新增）**
- 新增 `FaceIDTests/` target（Swift Testing），`PRODUCT_MODULE_NAME = FaceID` 以支持 `@testable import FaceID`。
- **23 个用例 / 4 套件，全绿**：`ScheduleWindow`（边界 / 跨午夜 / 空窗口 / Codable）、`LockedApp`（Codable / 缺字段 fail-safe）、`LockedAppsStore`（CRUD / 持久化 / 未知项 no-op）、`AppLockSessionManager`（0 / -1 / 正数三种超时语义、过期、全局改超时、失焦计时）。
- **测试发现并修复了一个真实 bug**：`ScheduleWindow.contains` 未处理空窗口（`start == end`），会把该分钟误判为命中——现在先 `guard !isEmpty`。
- 测试宿主短路：`AppDelegate.applicationDidFinishLaunching` 检测 `XCTestConfigurationFilePath` 后直接返回，避免宿主启动菜单栏/引导/更新器导致连接超时。

**构建与测试结果**：干净构建 0 error、7 警告（与 Phase 0 基线持平，无新增）；`xcodebuild test` **TEST SUCCEEDED**。
> 已知环境约束：测试**必须**先 `rm -rf build/DerivedData`，增量 DerivedData 下 `xcodebuild test` 会报 `The test runner hung before establishing connection.`（未签名宿主 + Xcode beta 的环境问题，Xcode 内 `Cmd+U` 不受影响）。Debug 配置已关闭 Hardened Runtime，否则测试包无法注入未签名宿主。

### Phase 3 实施明细

**新增文件（4 个）**

| 文件 | 职责 |
|---|---|
| `Domain/AppLock/WindowTracker.swift` | AX 枚举目标 App 的标准窗口、读取 frame、坐标转换（AX 左上原点 → Cocoa 左下原点）、`AXObserver` 事件 + 150ms 轮询兜底 |
| `Domain/AppLock/WindowShieldManager.swift` | 面板增删与窗口 diff、全屏/空间切换/定位失败的自动回落 |
| `UI/Shield/WindowShieldPanel.swift` | 无边框 `nonactivatingPanel`，`level = .floating`，**接收鼠标事件且可成为 key**（否则键盘仍能打进被锁 App，遮罩就只是装饰） |
| `UI/Shield/WindowShieldView.swift` | 模糊（`.behindWindow` 采样下层窗口内容）+ 暗化 + App 图标/名称 + Esc 取消提示 |

**关键技术点**

1. **窗口身份**：`AXUIElement` 是 CF 类型，Swift 不给 `Equatable`/`Hashable`。用 `CFEqual`/`CFHash` 包装成 `AXWindowKey` —— 这正是"同一窗口的两次封装应相等"的语义。
2. **坐标转换**：AX 以主屏**左上角**为原点、y 向下；Cocoa 以主屏**左下角**为原点、y 向上。`cocoaY = primaryDisplayHeight - axRect.maxY`。该式对**位于主屏上方**的显示器同样成立（AX y 为负 → Cocoa y 超过主屏高度）。
3. **事件优先 + 轮询兜底**：`AXObserver` 在拖拽窗口时连续触发，保证遮罩即时跟随；150ms 轮询覆盖子进程新建窗口、Space 切换期间的几何变化、以及 App 未完整发送通知的情况。轮询定时器加入 `.common` 模式，否则拖拽/按住菜单时会停摆。
4. **只在真正变化时发布**：轮询约 7 次/秒，若每次都重发相同快照会让所有观察者空转。
5. **自动回落（D2 的核心安全设计）**：以下任一情况立即放弃窗口遮罩、改为**隐藏 App**——
   - 未授予辅助功能权限 / 无法启动 AX 观察 / 找不到可覆盖窗口
   - 任意窗口达到全屏覆盖阈值（`0.95`）
   - **Space 切换**（`NSWorkspace.activeSpaceDidChangeNotification`）
   
   原因：遮罩面板是"画在上面"，而 **Mission Control 缩略图与其它 Space 由窗口服务器直绘、不含我们的面板**。隐藏 App 是唯一能同时从这些界面移除它的手段。
6. **有意的层间依赖**：`Domain` 的 `WindowShieldManager` 会引用 `UI/Shield/` 的两个视图类型。这是刻意的——遮罩面板是"机制"而非"产品呈现"（产品呈现是刘海面板，由编排层驱动），它完全可以是一个纯色矩形。已在文件头注明该决定。

**测试（新增 12 个用例，累计 35）**：`cocoaRect` 坐标翻转（含主屏上方显示器、尺寸不变性）、`coversWholeScreen`（精确铺满 / 单轴达标不算 / 多屏任一 / 退化输入）、`isStandardWindow` 子角色筛选。测试再次发挥作用——它抓出了我自己写错的期望值（AX y=0 高 300 应为 Cocoa y=780，我写了 680），实现本身是对的。

**结果**：干净构建 0 error、7 警告（与基线一致）；`xcodebuild test` **TEST SUCCEEDED**（35 用例 / 5 套件）。
> 更正：上一版报告中"Phase 2 干净构建 7 警告、无新增"的说法有误——当时并未真正执行干净构建核对。Phase 3 首次干净构建暴露了 3 条由 Phase 2 引入的警告（两处 Timer 闭包把 `weak self` 捕获进并发闭包、一处 `activateIgnoringOtherApps` 已弃用），均已修复，现基线确为 7 条。

**尚未接入**：`WindowShieldManager` 已进入 `AppEnvironment`，但尚未被调用——把「拦截 → 遮罩 → 刘海面板 → 放行/终止」串起来是 Phase 5 的 `AppUnlockCoordinator`。因此本阶段的端到端目视验证（拖动窗口跟随、Mission Control 不露出）需在 Phase 5 后进行。

### Phase 4 实施明细

**新增文件**：`UI/Notch/AppLockContentView.swift`（含 `AppLockContent` 载荷与视图）；改动 `NotchOverlayController`、`NotchOverlayView`、`NotchGeometry`。

**1. `.appLock` 复用 minimal 剪影，而非全尺寸扫描面板**

面板布局是 `[应用图标][缺口][扫描视频]`，直接沿用 `MinimalUnlockView` 的槽位宽度与 `NotchGeometry` 的 minimal 度量。原因：应用加锁**不该在用户想拿回 App 时反过来挡住屏幕**——宽矮胶囊已足以表达"这个 App 被锁住了"，全尺寸方形扫描面板是给整机解锁用的。

`NotchOverlayView` 因此新增 `usesMinimalSilhouette`（= `.appLock` 存在 ∨ `isMinimalScan`）并用于 `openBodySize` / `topRadius` / `bottomRadius` 三处几何计算。

**2. `AppLockContent` 自带 `ScanMedia` —— 这是本阶段最容易踩的坑**

原 `Content` 只有 `.scan(ScanMedia)` 承载视频。若沿用这个结构，`finish(success:)` 把内容改成 `.scan(.success)` 的一瞬间，**App 的图标与名称会被抹掉**，用户最后看到的是一个通用扫描面板。

因此让 `.appLock` 载荷自带 media，并把所有"重置视频"的路径（`beginScanning` / `activate` / `finish` / `collapse` / `disarm` / `dismissImmediately`）统一改走 `setScanMedia(_:)`：

| 当前内容 | `setScanMedia` 行为 |
|---|---|
| `.appLock` | 保留标识，只换视频 |
| `.onboarding` | **原样返回**——引导流程拥有面板，不得覆盖 |
| `.scan` | 换成新媒体 |

**行为变更**：`beginScanning()` 此前会无条件写入 `.scan(.idle)`，从而**驱逐进行中的引导流程**；现在改为不动 `.onboarding`。这是严格更安全的（实践中二者不会并发）。

**3. `arm()` 保持显式接管**：整机解锁 `arm()` 仍显式写入 `.scan(.idle)`——被 arm 即意味着锁屏路径接管面板。Phase 5 的编排器会串行化两条挑战路径，不会出现并发。

**4. 悬停重试需要面板可交互**：`updateInteractivity()` 原判据是 `isArmed || .failure || .onboarding`。应用加锁没有 armed 状态，若不加 `.appLock`，面板全程 `ignoresMouseEvents`，**悬停重试——失败后唯一的回头路——永远不会触发**。已把 `hasAppLockContent` 纳入判据（但不设为 key，key 由遮罩面板持有）。

**5. `presentAppLock(_:onRetry:)` 自带扫描超时**：与 `present()` 不同（后者由调用方决定何时 `beginScanning`），应用加锁的挑战必定有扫描窗口，因此它内部完成"展示 → 开始扫描（含超时自动收起）"，Phase 5 一次调用即可。

**测试（新增 5 个用例，累计 40）**：媒体保留规则（成功/失败/重置为 idle 三种路径都不得丢失标识）、`AppLockContent` 相等性（区分 bundleID / 名称 / 视频）、跨类型不相等（守住 `default: return false` 分支，否则视图会停止重渲染）。
> **未覆盖**：`.onboarding` 的"原样返回"分支无单测——构造 `OnboardingController` 会牵动相机与状态观察，在测试宿主里有引发连接超时的风险（Phase 2 踩过）。该分支依赖代码审阅，已在上面记录其行为契约。

**结果**：干净构建 0 error、7 警告（与基线一致）；`xcodebuild test` **TEST SUCCEEDED**（40 用例 / 6 套件）。
> 过程中新增的 1 条警告（`ScanMedia` 的 `Equatable` 是主 actor 隔离，不能在 `nonisolated` 的 `AppLockContent` 里使用）已通过把 `AppLockContent` 改为主 actor 隔离消除——它本就属于 UI 层。

### Phase 5 实施明细

**新增文件**：`Coordination/AuthenticationCoordinator.swift`（含 `AuthenticationMethod` / `AuthenticationOutcome` / `AttemptLedger` / `AppLockChallengePresenting`）、`Coordination/AppUnlockCoordinator.swift`、`UI/AppLock/ChallengePasswordPanel.swift`。

**1. 三层职责重新划分**（本阶段最实质的设计变更）

移植初期的分工是「`AppLocker` 隐藏 App」，但窗口遮罩要求 App **必须可见**才有窗口可覆盖 —— 两者在构造上互斥。重新划分后：

| 类型 | 职责 |
|---|---|
| `AppMonitor` | 检测（只读，不做任何呈现） |
| `WindowShieldManager` | **执行拦截**：铺遮罩面板，或回落隐藏 App |
| `AppLocker` | 只维护「当前被扣住的是谁」的状态，以及放行 / 终止两条出路（`block(hidesApp:)` 由遮罩层告知是否已隐藏） |

连带约束已写进 `WindowShieldManager` 的文件头：**调用方不得在 `shield` 之前隐藏 App** —— 隐藏后 App 没有屏幕上的窗口，遮罩会一无所获并静默降级为隐藏模式。

**2. 窗口结算（`settleForWindows`）**

`AppMonitor` 在窗口布局完成之前就会收到「已激活」。若此时立刻因窗口列表为空而回落隐藏，**窗口遮罩对「新启动」这类场景将永远失效**，Phase 3 的整套子系统也就成了死代码。`shield` 因此改为 `async`，在放弃前最多等 `windowSettleTimeout`（0.35 s），由 tracker 的 150 ms 轮询补齐。

**3. 认证阶梯**（`AuthenticationCoordinator` + `AttemptLedger`）

- 顺序固定为 人脸 → 触控 ID → 应用密码；**人脸是唯一需要摄像头的环节**，租约拿不到就跳过该级而非开启第二条 session。
- 人脸超时（镜头前没人）**不计失败**，只有「非本人 / 活体拒绝 / 触控 ID 失败 / 密码错误」才计数；否则离开工位办公就会把用户锁在门外。
- 锁定算术独立成 `AttemptLedger`，返回 `nil` / 剩余秒数，**读取即清理过期锁定**。
- 触控 ID 被用户取消 → 本轮结束但**不**弹密码框，也不终止 App —— 刚拒绝生物识别就弹密码框是反着来的。
- 呈现通过 `AppLockChallengePresenting` 协议注入，阶梯本身不产生任何 UI 主张。

**4. 四种结局**

| 结局 | 处理 |
|---|---|
| `.success` | 收遮罩 → 开解锁会话 → 恢复并激活 App |
| `.cancelled` | 用户按 Esc 明确放弃 → 收遮罩 → **结束**被锁 App |
| `.retryable` | 梯子跑完仍未通过 → **保持锁定**，面板停在失败帧，悬停重开一轮 |
| `.lockedOut` | 冻结 `lockoutDuration`，自动解冻 |

`.retryable` 的存在是为了「一次角度不好不该赔上正在运行的 App」——只有明确取消才结束进程。

**5. 三处必要的既有层改造**（都不是可选项，缺一个链路就断）

- **刘海面板支持持久挑战**：`collapse()` 在持有 `.appLock` 载荷时不再隐藏面板，而是留在屏上（`presentAppLock` 预先停靠胶囊）。否则失败帧超时后面板消失，用户**再无重试入口**，被锁 App 永久不可达。`endAppLockChallenge()` 负责收尾。
- **`activate()` 豁免 `retryOnHover`**：该开关面向锁屏浮层，若应用加锁也遵守它，用户关掉这一项就等于关掉了唯一的重试路径。
- **通用逃生口**：`.hidden` 兜底模式下没有遮罩面板，Esc 无处可按。`NotchWindow` 新增 Esc 处理，`NotchWindowController.makePanelKey()` 让面板**取 key 但不激活 Face ID**（`NSApp.activate` 会把被锁 App 顶下去，且会惊动 `AppMonitor`）。两种模式因此都有明确的退出通道。

**6. 尚未做端到端目视验证的部分**（重要）

本轮只做了静态核验（接线一致性 + 单元测试）。以下必须真机跑一次才能确认：拖动窗口时遮罩跟随、Mission Control / 切换 Space 时不露出内容、`.hidden` 模式下 Esc 逃生、密码弹窗与遮罩面板的 key 交接、以及 `hide()` 后的 App 其窗口是否仍被 AX 报告（这决定 `.windowShield` 到底能否生效）。

**结果**：干净构建 0 error、7 警告（与基线一致）；`xcodebuild test` **TEST SUCCEEDED**（47 用例 / 7 套件）。
> 过程中新增的 1 条警告（`TouchIDError.localizedDescription` 来自 `LocalizedError`，本非可选，多余的 `??` 被编译器指出）已修正，警告回到 7 条基线。

---

## 目录

1. [项目概述与目标](#一项目概述与目标)
2. [已定案的四项决策](#二已定案的四项决策)
3. [现状分析：双项目能力矩阵](#三现状分析双项目能力矩阵)
4. [合并后产品定义](#四合并后产品定义)
5. [目标架构设计](#五目标架构设计)
6. [模块合并映射表](#六模块合并映射表)
7. [关键机制改造设计](#七关键机制改造设计)
8. [新建代码清单（含接口契约）](#八新建代码清单含接口契约)
9. [分阶段实施计划](#九分阶段实施计划)
10. [权限、安全与合规](#十权限安全与合规)
11. [风险登记册与对策](#十一风险登记册与对策)
12. [测试计划](#十二测试计划)
13. [验收标准与交付物](#十三验收标准与交付物)

---

## 一、项目概述与目标

### 1.1 背景

两个开源项目解决的是**两个不同层级**的"锁"问题，天然互补：

| | **glance** | **FaceGate** |
|---|---|---|
| 解决的问题 | **整机**解锁（锁屏/唤醒时刷脸，自动输入密码） | **单个 App** 加锁（打开被锁 App 时拦截验证） |
| 用户价值 | 免手输密码，iPhone FaceID 体验搬到 Mac | 给敏感 App 加一道"门" |
| 交互载体 | 屏幕刘海的 Dynamic Island 动画 | 全屏半透明遮罩 + 菜单栏弹窗 |
| 技术基石 | Vision 5 点对齐 + ArcFace 512 维 + 5 路活体 | NSWorkspace 事件监听 + hide App + NSPanel 遮罩 |

### 1.2 合并目标（Definition of Done）

产出一款名为 **Face ID** 的应用，**同时**具备以下能力，且**全程只有一套视觉语言（glance 的刘海 UI）**：

1. **整机解锁**（继承 glance）：唤醒/锁屏/空格键触发刷脸，验证通过自动输入系统密码解锁。
2. **按 App 加锁**（移植 FaceGate）：指定 App 被打开或切到前台时，用**窗口级遮罩**锁住该 App 界面并弹出人脸验证；验证通过放行，失败/取消则终止该 App。
3. **统一人脸内核**：整机解锁与 App 加锁**共用同一套**人脸识别 + 活体检测 + 人脸库（不进两套模型、不录两次人脸）。
4. **统一认证编排**：人脸 → Touch ID → 应用密码的优先级与失败锁定策略全局一致。
5. **统一设置界面**：在设置窗口内扩展「被锁应用（Locked Apps）」标签页，风格与现有页面完全一致。
6. **统一持久化与权限模型**：单一 Bundle ID、单一 Keychain 命名空间、单一用户数据目录。
7. **全新录入**：不做旧版本数据迁移，首次启动走完整引导重新录入人脸。

### 1.3 核心设计原则（贯穿全程的 6 条铁律）

| # | 原则 | 说明 |
|---|---|---|
| P1 | **glance 为基座，FaceGate 为能力源** | 不"平均合并"。以 glance 工程为主干，FaceGate 只贡献无 UI 的加锁内核。 |
| P2 | **一套人脸内核，两处调用** | 删除 FaceGate 的 `FaceAuth/*`，统一走 glance 的 `FaceRecognitionPipeline`（精度更高）。 |
| P3 | **一个 UI 入口** | 所有浮层表现（扫描/成功/失败/引导/App加锁）都经 `NotchOverlayController` 统一调度。 |
| P4 | **统一并发模型** | 全面采用 Swift Observation（`@Observable`）+ `MainActor` 默认隔离，淘汰 FaceGate 的 Combine + `DispatchQueue` 风格。 |
| P5 | **单一真源** | 阈值、超时、Key、路径都收敛到唯一常量源，杜绝"多个默认值打架"。 |
| P6 | **逐步可回滚** | 分阶段交付，每阶段可独立编译运行并验收，不做"大爆炸式"一次性重写。 |

### 1.4 命名规范（全项目统一）

| 项 | 取值 |
|---|---|
| 产品名 / 显示名 | **Face ID** |
| Xcode 工程 | `Face ID.xcodeproj` |
| Target / Scheme | `Face ID` |
| 源码根目录 | `FaceID/`（**无空格**，便于 Makefile / `xcodebuild` 脚本调用） |
| Bundle ID | `com.<你的组织>.faceid` |
| 数据目录 | `~/Library/Application Support/Face ID/` |
| Keychain service | `com.<你的组织>.faceid` |
| Swift 常量前缀 | `FIDConstants`、`FID.`（UserDefaults 键前缀） |
| 编译开关 | `FID_ENABLE_SKYLIGHT`（私有 API 总开关） |

> **说明**：源码目录刻意用 `FaceID/`（不带空格）以避免构建脚本路径转义问题；这与"项目名为 Face ID"不冲突——工程名、产品名、显示名均为 **Face ID**。
>
> ⚠️ **合规提示**：Apple 对 "Face ID" 拥有注册商标。作为个人/开源项目自用没有问题，但**若要商业化分发建议改名**（如 FaceUnlock / FaceGate 等），以免商标争议。可按你的意愿随时替换（本计划中的名称均为可批量替换的标识）。

---

## 二、已定案的四项决策

| # | 事项 | **定案** | 影响 |
|---|---|---|---|
| **D1** | 是否保留整机解锁 | ✅ **保留**（glance 原功能完整保留） | 需要辅助功能权限 + 私有 SkyLight API；放弃 Mac App Store 上架（保留编译开关可关） |
| **D2** | App 加锁的锁定呈现 | ✅ **窗口级遮罩为主 + 隐藏为兜底**（见 §7.4） | 需新增「窗口跟踪面板」子系统；辅助功能权限已有 |
| **D3** | 旧数据迁移 | ✅ **不做迁移，全新录入** | 省去迁移器；首启强制走完整引导；不兼容旧 FaceGate/glance 数据 |
| **D4** | 产品命名 | ✅ **Face ID**（全项目统一） | 见 §1.4 |

> **D2 结论先行**：经技术判定，**"只遮罩被锁 App 的窗口界面"是可以实现的**——macOS 无公开 API 能直接给别的进程窗口套遮罩，但可用「窗口跟踪面板」（AX 读取窗口 frame + 无边框 NSPanel 精确贴附 + `AXObserver` 实时跟随）等价达成。因此 D2 取「窗口遮罩为主、隐藏为兜底」的混合方案。详见 §7.4。

---

## 三、现状分析：双项目能力矩阵

### 3.1 功能对比与归属决策

| 能力 | glance | FaceGate | 合并后归属 |
|---|:---:|:---:|---|
| 人脸识别（有 landmark 对齐） | ✅ 强 | ⚠️ 弱（无对齐） | **glance 内核** |
| 人脸识别（无对齐，仅裁剪） | — | ✅ | 丢弃 |
| 活体检测：5 cue（几何/眩光/设备/景深/眨眼） | ✅ | — | **glance** |
| 活体检测：转头挑战 | — | ✅ | 可选保留（增强模式） |
| 多身份（多人/多造型） | ✅ | ✅（最多3张） | **glance** |
| 刘海 Dynamic Island UI | ✅ | — | **glance（唯一主 UI）** |
| 引导录入流程（9 姿势） | ✅ | ✅（3方向） | **glance** |
| 整机解锁（密码注入） | ✅ | — | **glance 保留** |
| 按 App 加锁（拦截） | — | ✅ | **FaceGate 移植** |
| 被锁 App 的**窗口级遮罩** | — | ⚠️ 全屏遮罩 | **★新建（窗口跟踪面板）** |
| 被锁 App 列表管理 | — | ✅ | **FaceGate 移植** |
| 按 App 会话计时（超时/失焦计时/永久） | — | ✅ | **FaceGate 移植** |
| 定时锁/解锁窗口 | — | ✅ | **FaceGate 移植（P1）** |
| 多因子认证编排（人脸/TouchID/密码） | ⚠️ 仅密码 | ✅ | **FaceGate 移植 + 融合** |
| 应用密码（SHA-256+盐） | — | ✅ | **FaceGate 移植** |
| 锁屏/唤醒事件监听 | ✅ | ✅ | **glance（`LockMonitor` 更权威）** |
| 会话空闲自动重锁 | ✅ | ⚠️ per-app | 两者语义区分保留 |
| 菜单栏常驻 | ✅ | ✅ | **glance 风格** |
| Sparkle 自动更新 | ✅ | ✅ | **保留一个（glance 的 2.9.6）** |
| 卸载保护（immutable bundle） | — | ✅ | 可选保留（P2） |
| 紧急退出热键 | — | ✅ | 可选保留（P2） |

### 3.2 技术栈对比

| 维度 | glance | FaceGate | 合并策略 |
|---|---|---|---|
| 最低系统 | macOS 15.0 | macOS 14.0 | **15.0**（放弃 14，换取 glance 的并发与 API） |
| Swift 版本 | 5.0（Swift 6 并发语义） | 5.9 | **glance 配置** |
| 默认隔离 | `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` | 无 | **glance 配置** |
| 状态管理 | `@Observable` + Observation | `ObservableObject` + Combine | **Observation** |
| 工程格式 | `objectVersion 77` + 文件系统同步组 | XcodeGen（`project.yml`） | **文件系统同步组**（新文件自动入 target） |
| 依赖 | Sparkle 2.9.6 | Sparkle 2.9.3 | **2.9.6** |
| 沙盒 | 关闭 | 关闭 | **关闭** |
| 加固运行时 | 开启 | 关闭 | **开启**（并设 `disable-library-validation`） |
| Bundle ID | `com.jonathan.glance` | `com.dweep.FaceGate` | **`com.<组织>.faceid`** |
| 人脸模型 | `ArcFace.mlpackage`（112², 512维, 带预处理） | `FaceEmbedding.mlmodelc`（112², 512维, 手工归一化） | **只用 ArcFace** |
| 匹配阈值 | 0.66（存）/0.63（UI档）/0.6（Lab） | 0.65 | **收敛为单一 0.63** |
| 单元测试 | 无 | 无 | **新增测试目标** |

### 3.3 关键冲突点清单（合并必须处理）

| # | 冲突 | 影响 | 处置 |
|---|---|---|---|
| C1 | 两套人脸模型/两套识别代码 | 双倍模型体积、需录两次脸 | 统一 glance 内核，删 FaceGate `FaceAuth/*` + `ML/*` |
| C2 | 两套持久化命名空间（`GlanceSettings.*` vs 裸 key） | 数据互相覆盖 | 统一迁入 `FID.` 前缀（§7.7） |
| C3 | 两套并发模型 | 混用导致数据竞态、UI 不刷新 | 统一 Observation（§7.8） |
| C4 | 两套"锁"语义（整机 vs 应用） | 事件/会话互相干扰 | 编排层按域隔离（§7.2、§7.6） |
| C5 | 遮罩策略不同（刘海 vs 全屏） | 视觉不统一、焦点抢占 | 统一「窗口遮罩 + 刘海面板」（§7.4） |
| C6 | 两套 Keychain service | 密钥不共享 | 建立新 service（不做迁移，§7.7） |
| C7 | 两个 Sparkle 更新器 | 双更新、feed 冲突 | 只保留 glance 的 |
| C8 | `LSUIElement` + accessory 焦点抢占 | App 遮罩抢不到焦点 | 见 §7.4、风险 R3 |

### 3.4 阈值/常量统一（单一真源表）

| 参数 | 当前值 | 合并后（`FIDConstants`） |
|---|---|---|
| 人脸匹配阈值 | 0.66 / 0.63 / 0.65 | **0.63**（可 0.58/0.63/0.68 三档） |
| 扫描窗口时长 | 3–10s（默认5） | **5s** |
| 活体模式 | light / heavy | **light**（默认） |
| 失败次数阈值 | FaceGate 5 次 | **5 次** |
| 锁定时长 | 60s | **60s** |
| 应用会话默认超时 | 300s | **300s** |
| 永久解锁哨兵 | -1 | **-1** |
| 录入样本数 | glance 18 / FaceGate 9 | **18（9姿势×2）** |
| 模型输入 / 维度 | 112×112 / 512 | **112×112 / 512** |
| 窗口跟踪轮询间隔 | — | **150ms**（AX 事件为主 + 轮询兜底） |

---

## 四、合并后产品定义

### 4.1 产品定位

**一句话**：一款以刘海动画为交互核心的 macOS 安全助手 —— 刷脸解锁整机，也刷脸给敏感 App 开门（只遮住那个 App 的界面）。

**双模架构**（同一内核，两个触发域）：

```
                        ┌─────────────────────────────┐
                        │   人脸内核（共享）            │
                        │  Detector→Aligner→ArcFace→  │
                        │  Matcher + Liveness          │
                        └──────────▲──────────┬───────┘
                                   │          │
                 ┌─────────────────┘          └──────────────────┐
                 │                                                │
        ┌────────┴─────────┐                          ┌───────────┴──────────┐
        │  整机解锁域        │                          │  应用加锁域            │
        │  LockMonitor 触发  │                          │  AppMonitor 触发       │
        │  → 输入系统密码    │                          │  → 窗口遮罩 / 放行      │
        └────────┬─────────┘                          └───────────┬──────────┘
                 │                                                │
                 └───────────────┬────────────────────────────────┘
                                 ▼
                    ┌──────────────────────────┐
                    │  NotchOverlayController   │ ← 唯一 UI 出口
                    │  （刘海面板 / 胶囊面板）    │
                    └──────────────────────────┘
```

### 4.2 功能优先级（MoSCoW）

| 优先级 | 功能 | 说明 |
|---|---|---|
| **P0 必须** | 人脸录入/识别 + 活体 | 共享内核 |
| **P0 必须** | 刘海 UI（扫描/成功/失败） | 视觉核心 |
| **P0 必须** | 整机解锁（唤醒/锁屏触发） | glance 主功能 |
| **P0 必须** | 按 App 加锁（拦截 + **窗口遮罩** + 验证放行/终止） | 合并新功能 |
| **P0 必须** | 被锁 App 管理界面（在设置内） | 合并新功能 |
| **P0 必须** | 多因子认证（人脸→TouchID→密码） | 安全底线 |
| **P1 应做** | 按 App 会话计时（超时/失焦/永久/立即） | 体验 |
| **P1 应做** | 锁定呈现模式切换（窗口遮罩 / 隐藏） | D2 衍生 |
| **P1 应做** | 菜单栏状态与控制 | 可达性 |
| **P1 应做** | 定时锁/解锁窗口；锁屏/睡眠重置会话 | FaceGate 增强 |
| **P2 可做** | 紧急退出热键、卸载保护、空格键触发、Face Lab | 工具箱 |
| **P3 不做** | 旧数据迁移（D3）、转头挑战活体（默认关）、App Store 上架 | 见 §10 |

### 4.3 核心用户旅程

**旅程 A — 整机解锁**（继承 glance）
```
合盖→开盖 → LockMonitor 捕获 wake → 刘海面板滑出（closed）
  → 自动扫描 → 人脸匹配 + 活体确认 → 成功动画 → 注入系统密码 → 解锁
                                    ↘ 失败/超时 → 失败动画 → 悬停可重试
```

**旅程 B — App 加锁**（合并新增，窗口遮罩版）
```
用户双击「微信」→ NSWorkspace.didLaunch/didActivate
  → AppMonitor 判定该 App 在被锁列表且无有效会话
  → WindowShieldManager: 定位微信全部窗口 → 每窗贴一个跟踪遮罩面板（模糊+锁标识）
  → NotchOverlayController 叠加 .appLock 内容（微信图标 + 名称 + 扫描动画）
  → 人脸验证成功 → 移除遮罩 + 微信恢复可交互 + 建立会话（按时长）
  ↘ 验证失败/取消 → 移除遮罩 → 隐藏并终止微信进程
```

**旅程 C — 首次配置**（融合，无迁移）
```
检测到首次启动（无已录入人脸）→ 强制完整引导
  引导：intro → 权限（摄像头/辅助功能）→ 安全声明 → 人脸录入（9姿势）
      → 命名 → 系统密码（整机解锁用）→ 应用密码（App 锁兜底）
      → 【新增步骤】选择要加锁的 App → 完成
```

---

## 五、目标架构设计

### 5.1 分层架构

```
┌──────────────────────────────────────────────────────────────────┐
│ 表现层 Presentation                                                │
│  ├─ Notch/           刘海面板（唯一浮层出口）                       │
│  ├─ Shield/          窗口跟踪遮罩面板（★新建，D2）                  │
│  ├─ Onboarding/      首次引导                                      │
│  └─ Settings/        设置窗口（含 Locked Apps 标签页）              │
├──────────────────────────────────────────────────────────────────┤
│ 编排层 Coordination                                                │
│  ├─ FaceUnlockCoordinator    整机解锁编排（glance）                 │
│  ├─ AppUnlockCoordinator     应用加锁编排（★新建）                  │
│  └─ AuthenticationCoordinator 多因子认证编排（移植+融合）            │
├──────────────────────────────────────────────────────────────────┤
│ 领域层 Domain                                                      │
│  ├─ Face/      识别内核（glance）                                   │
│  ├─ Liveness/  活体内核（glance）                                   │
│  ├─ AppLock/   加锁内核（FaceGate）+ WindowTracker（★新建）          │
│  ├─ SystemUnlock/ 整机解锁基础设施（glance）                        │
│  └─ Security/  Keychain / 加密存储（两者融合）                      │
├──────────────────────────────────────────────────────────────────┤
│ 基础设施 Infrastructure                                            │
│  ├─ Camera/           摄像头采集                                   │
│  ├─ Persistence/      设置与数据持久化（统一命名空间）               │
│  └─ FIDConstants.swift 单一真源常量                                │
└──────────────────────────────────────────────────────────────────┘
```

**依赖方向**：表现层 → 编排层 → 领域层 → 基础设施；**禁止反向依赖**。领域层各子域之间**互不直接依赖**，只通过编排层协作（尤其 `AppLock` 与 `SystemUnlock` 之间零耦合）。

### 5.2 目标目录结构

```
Face ID/                                   ← 合并后工程根
├── Face ID.xcodeproj
├── FaceID/                                 ← 源码根（无空格；文件系统同步组）
│   ├── App/
│   │   ├── FaceIDApp.swift                  ← 原 glanceApp.swift 重命名
│   │   ├── AppDelegate.swift                ← 融合：菜单栏 + 更新器 + 首启门禁 + 加锁装配
│   │   └── AppEnvironment.swift             ← 扩展：+ appLockStore / appUnlockCoordinator / shieldManager
│   ├── Domain/
│   │   ├── Face/                            ← 全部来自 glance（7 文件）
│   │   ├── Liveness/                        ← 全部来自 glance（9 文件）
│   │   ├── AppLock/                         ← ★来自 FaceGate（去 UI/Combine）
│   │   │   ├── AppMonitor.swift
│   │   │   ├── AppLocker.swift
│   │   │   ├── LockedAppsStore.swift         ← 原 LockedAppsManager，改 @Observable
│   │   │   ├── AppLockSessionManager.swift   ← 原 SessionManager
│   │   │   ├── AppScheduleManager.swift
│   │   │   ├── GlobalHotkeyManager.swift
│   │   │   ├── InstalledAppsScanner.swift
│   │   │   ├── LockedApp.swift
│   │   │   ├── WindowTracker.swift           ★新建：AX 读窗口 frame + 事件
│   │   │   └── WindowShieldManager.swift     ★新建：跟踪面板增删与同步
│   │   ├── SystemUnlock/                    ← 来自 glance
│   │   │   ├── LockMonitor.swift
│   │   │   ├── SessionAutoLocker.swift
│   │   │   ├── SpaceKeyMonitor.swift
│   │   │   └── KeystrokeInjector.swift
│   │   ├── Security/                        ← 融合
│   │   │   ├── KeychainManager.swift         (glance)
│   │   │   ├── SecureCredentialManager.swift (glance)
│   │   │   ├── AppPasswordAuth.swift         ← FaceGate PasswordAuth
│   │   │   ├── TouchIDAuth.swift             ← FaceGate TouchIDAuth
│   │   │   └── CryptoHelper.swift            ← FaceGate CryptoHelper
│   │   └── Camera/                          ← 来自 glance
│   │       ├── CameraManager.swift
│   │       ├── CameraDeviceCatalog.swift
│   │       └── CameraPreviewView.swift
│   ├── Coordination/                        ← ★新建编排层
│   │   ├── FaceUnlockCoordinator.swift       (glance)
│   │   ├── AppUnlockCoordinator.swift        ★新建
│   │   ├── CameraArbiter.swift               ★新建（摄像头互斥）
│   │   └── AuthenticationCoordinator.swift   ← 改造自 FaceGate AuthenticationManager
│   ├── UI/
│   │   ├── Notch/                           ← 来自 glance + ★扩展
│   │   │   ├── NotchOverlayController.swift  ★Content 新增 .appLock
│   │   │   ├── NotchOverlayView.swift        ★新增 .appLock 渲染分支
│   │   │   ├── AppLockContentView.swift      ★新建（App 图标+名称+扫描）
│   │   │   ├── NotchWindow / NotchWindowController / NotchShape / NotchGeometry
│   │   │   ├── NotchPanelStyle / NotchSkyLight
│   │   │   └── ScanAnimationView / MinimalUnlockView
│   │   ├── Shield/                          ★新建（D2）
│   │   │   ├── WindowShieldPanel.swift       无边框跟踪面板
│   │   │   └── WindowShieldView.swift        模糊/暗化 + 锁标识
│   │   ├── Onboarding/                      ← 来自 glance + ★一步（选择加锁 App）
│   │   ├── Settings/                        ← 来自 glance + ★一页
│   │   │   └── Pages/LockedAppsSettingsPage.swift  ★新建
│   │   └── MenuBar/                         ← glance 菜单栏逻辑（扩展）
│   ├── Models/
│   │   └── ArcFace.mlpackage                ← 唯一人脸模型
│   ├── Resources/                           ← glance 视频/图 + 新图标
│   └── Constants/
│       └── FIDConstants.swift               ★新建，单一真源
├── Face ID.entitlements
└── README.md / SECURITY.md
```

> **工程便利性**：glance 的 `project.pbxproj` 使用 **PBXFileSystemSynchronizedRootGroup**（`objectVersion 77`），`FaceID/` 目录下新增的 `.swift` 会**自动纳入编译**，无需手工维护工程文件——极大降低移植 FaceGate 文件的成本。**注意**：pbxproj 中存在 `PBXFileSystemSynchronizedBuildFileExceptionSet`（例外集），若需排除某些文件，要在此登记。

### 5.3 关键设计决策（ADR）

| ADR | 决策 | 理由 |
|---|---|---|
| **ADR-1** | 采用 glance 作为主干工程 | UI 风格来源、人脸内核更强、工程格式更现代 |
| **ADR-2** | 删除 FaceGate 的 `FaceAuth/*` 与 `FaceEmbedding.mlmodelc` | 避免双模型双维护；glance 有 landmark 对齐，精度更高 |
| **ADR-3** | App 加锁采用**窗口级遮罩**为主、**隐藏**为兜底 | 满足"只遮罩软件界面"诉求；全屏/Mission Control 场景自动降级 |
| **ADR-4** | 浮层统一走 `NotchOverlayController` | 单一 UI 出口，视觉语言统一 |
| **ADR-5** | 保持沙盒关闭、加固运行时开启 | 跨进程 hide / 窗口定位的前提；Sparkle/私有框架需 library-validation 例外 |
| **ADR-6** | 并发模型统一为 Observation + MainActor | 与 glance 现有一致 |
| **ADR-7** | 保留整机解锁（Accessibility 依赖）为**可选可剥离模块** | D1 定案；设计为可用编译开关整体关闭 |
| **ADR-8** | 不做旧数据迁移，首启强制完整引导 | D3 定案 |

---

## 六、模块合并映射表

### 6.1 直接保留（glance 资产）

| glance 文件/目录 | 处置 | 备注 |
|---|---|---|
| `FaceDetector / FaceAligner / LandmarkGeometry` | 保留 | 检测 + 5 点对齐 |
| `ArcFaceEmbedder / FaceEmbedder / FaceRecognitionPipeline` | 保留 | 512 维管线 |
| `FaceEnrollmentStore / SecureFaceStore` | 保留 | 人脸库 |
| `Liveness/*`（9 文件） | 保留 | 活体 |
| `CameraManager / CameraDeviceCatalog / CameraPreviewView` | 保留 | 采集 |
| `KeychainManager / SecureCredentialManager` | 保留 | 密钥 |
| `LockMonitor / SpaceKeyMonitor / KeystrokeInjector` | 保留 | 整机解锁链路 |
| `NotchOverlay/*` | 保留并扩展 | 主 UI |
| `Onboarding/*` | 保留并加一步 | 引导 |
| `Settings/*` | 保留并加一页 | 设置 |
| `Models/ArcFace.mlpackage` | 保留 | 唯一模型 |
| `Updater/UpdaterController`、`LaunchAtLogin` | 保留 | 基础设施 |

### 6.2 移植（FaceGate 能力内核，去掉 UI/Combine）

| FaceGate 文件 | 目标位置 | 改造点 |
|---|---|---|
| `Core/AppMonitor.swift` | `Domain/AppLock/AppMonitor.swift` | `ObservableObject`→`@Observable`；回调改 `async`/Stream |
| `Core/AppLocker.swift` | `Domain/AppLock/AppLocker.swift` | `showOverlays()` 改调 `WindowShieldManager` + `NotchOverlayController` |
| `Core/LockedAppsManager.swift` | `Domain/AppLock/LockedAppsStore.swift` | 改 `@Observable`；key 迁 `FID.` |
| `Core/SessionManager.swift` | `Domain/AppLock/AppLockSessionManager.swift` | 改名避免与 `SessionAutoLocker` 混淆；key 迁移 |
| `Core/AppScheduleManager.swift` | `Domain/AppLock/AppScheduleManager.swift` | 同上（P1） |
| `Core/GlobalHotkeyManager.swift` | `Domain/AppLock/GlobalHotkeyManager.swift` | Carbon 热键；解耦 `AppDelegate.shared`（P2） |
| `Auth/PasswordAuth.swift` | `Domain/Security/AppPasswordAuth.swift` | 重命名；Keychain service 迁移 |
| `Auth/TouchIDAuth.swift` | `Domain/Security/TouchIDAuth.swift` | 基本原样 |
| `Auth/AuthenticationManager.swift` | `Coordination/AuthenticationCoordinator.swift` | 人脸分支改调 glance 内核（§7.5） |
| `Models/LockedApp.swift` | `Domain/AppLock/LockedApp.swift` | 原样（`Codable`） |
| `Utilities/Constants.swift` | 拆入 `Constants/FIDConstants.swift` | 仅保留 App 锁相关 key |
| `Utilities/KeychainHelper.swift` | 并入 `Domain/Security/KeychainManager.swift` | 能力重叠，取并集 |
| `Utilities/CryptoHelper.swift` | `Domain/Security/CryptoHelper.swift` | AES-256-GCM |
| `Utilities/VectorMath.swift` | `Domain/Face/VectorMath.swift` | 如 glance 已有则复用 |
| `Utilities/InstalledAppsScanner.swift` | `Domain/AppLock/InstalledAppsScanner.swift` | 扫描可锁 App |

### 6.3 新建（桥接层与融合件）

| 新建文件 | 职责 |
|---|---|
| `Coordination/AppUnlockCoordinator.swift` | 应用加锁主循环 |
| `Coordination/CameraArbiter.swift` | 摄像头互斥（两域不打架） |
| `Domain/AppLock/WindowTracker.swift` | AX 读取/监听目标 App 窗口几何 |
| `Domain/AppLock/WindowShieldManager.swift` | 跟踪遮罩面板的增删与同步 |
| `UI/Shield/WindowShieldPanel.swift` / `WindowShieldView.swift` | 窗口遮罩外观 |
| `UI/Notch/AppLockContentView.swift` | 刘海内容：App 图标 + 名称 + 扫描 |
| `UI/Settings/Pages/LockedAppsSettingsPage.swift` | 被锁 App 管理页 |
| `UI/Onboarding/` 新增 `LockedAppsStepView` | 引导内选择加锁 App |
| `Constants/FIDConstants.swift` | 单一真源常量 |

### 6.4 丢弃（FaceGate 的 UI 与冗余）

| 丢弃文件 | 原因 |
|---|---|
| `UI/MenuBarView.swift`、`UI/SettingsView.swift`（2006 行）、`UI/SetupView.swift` | 由 glance 对应界面替代 |
| `UI/FaceEnrollmentView.swift`、`UI/AppPickerView.swift` | 由 glance 引导 + 新设置页替代 |
| `UI/AuthOverlayPanel.swift` / `AuthOverlayView.swift` / `ActionAuthWindow.swift` | 由窗口遮罩 + 刘海面板替代 |
| `UI/CameraPreviewView.swift`、`UI/Components/*` | glance 已有 / 被替代 |
| `Utilities/ViewExtensions.swift` 中 `FGColor/FGCard/...` | FaceGate 视觉令牌作废 |
| `FaceAuth/*`（7 文件）+ `ML/FaceEmbedding.mlmodelc` | 由 glance 内核替代 |
| `App/FaceGateApp.swift` 的 `MenuBarExtra` 外壳 | 由 glance `App` 外壳替代 |
| `Resources/Assets.xcassets` 中 FaceGate 品牌图标 | 换新品牌 |
| `project.yml`、`FaceGate.xcodeproj` | 不再使用 XcodeGen |

### 6.5 命名与隔离清单

| 项 | 现状 | 合并后 |
|---|---|---|
| UserDefaults 前缀 | `GlanceSettings.*` / 裸 `"lockedApps"` | 统一 `FID.`（`FID.lockedApps`、`FID.settings.*`） |
| Keychain service | `com.jonathan.glance` / `com.dweep.FaceGate` | `com.<组织>.faceid`（单一） |
| 数据目录 | `.../glance/` / `.../FaceGate/` | `.../Face ID/` |
| 人脸库文件 | `face-identities.enc` / `face_data.encrypted` | `face-identities.enc`（glance 格式） |
| 登录项标识 | `SMAppService.mainApp` | 沿用 |
| 单例风格 | 混杂 `static let shared` | 保留单例，但**统一由 `AppEnvironment` 持有**，禁止散落调用 `.shared` |

---

## 七、关键机制改造设计

### 7.1 人脸内核统一

**删除** FaceGate 的整条识别链（`FaceAuth/*` + `FaceEmbedding.mlmodelc`），**统一调用** glance 的：

```swift
// Domain/Face/FaceRecognitionPipeline.swift（沿用）
func recognize(in image: CIImage, preferNear: CGRect?) throws -> FaceRecognitionResult
func score(_ embedding: FaceEmbedding, against ids: [FaceIdentity]) -> [ScoredIdentity]
func bestMatch(in scored: [ScoredIdentity], threshold: Float) -> ScoredIdentity?
```

**收益**：模型体积从 ~13MB 降到 ~6.6MB；识别精度提升（landmark 对齐 + 双阈值 centroid/max-sample）；人脸只录一次、两处共用。

### 7.2 应用加锁编排（★核心新建）

仿 `FaceUnlockCoordinator` 结构，新建 `AppUnlockCoordinator`，把「触发源换成 AppMonitor、目标换成解锁 bundleID」：

```swift
@Observable @MainActor
final class AppUnlockCoordinator {
    private let store: LockedAppsStore
    private let locker: AppLocker
    private let session: AppLockSessionManager
    private let auth: AuthenticationCoordinator
    private let shield: WindowShieldManager      // ★D2
    private let arbiter: CameraArbiter
    let pipeline = FaceRecognitionPipeline()

    func start()                                                    // 注册到 AppMonitor
    func handleDetected(bundleID: String, app: NSRunningApplication)
    func retryCurrent() async
    func cancelCurrent()                                            // → 隐藏并终止
    private func runCycle(bundleID: String, app: NSRunningApplication) async
}
```

**关键点**：
- **会话检查**：进入前先查 `session.hasActiveSession(for:)`，有则直接放行（不弹面板）。
- **冷却**：解锁后 1 秒内不重复加锁（沿用 FaceGate `recordUnlock`）。
- **摄像头串行化**：`CameraArbiter` 确保整机解锁与应用加锁不会同时占摄像头。
- **终止语义**：取消/失败 → 移除遮罩 → `app.hide()` → `terminate()` + 1s 兜底 `forceTerminate()`。

### 7.3 刘海 UI 扩展（Content 枚举）

现有 `NotchOverlayController.Content` 只有两个 case，**扩展为三个**：

```swift
enum Content: Equatable {
    case scan(ScanMedia)
    case onboarding(OnboardingController)
    case appLock(AppLockContent)          // ★新增

    static func == (lhs: Content, rhs: Content) -> Bool {
        switch (lhs, rhs) {
        case (.scan(let a), .scan(let b)): return a == b
        case (.onboarding(let a), .onboarding(let b)): return a === b
        case (.appLock(let a), .appLock(let b)): return a == b   // ★
        default: return false
        }
    }
}

struct AppLockContent: Equatable {
    let bundleID: String
    let displayName: String
    let icon: NSImage?
}
```

**控制器新增方法**（**不新增 phase**，复用整条 `.scanning/.success/.failure/.collapsing` 动画状态机）：

```swift
func presentAppLock(_ content: AppLockContent, onRetry: (() -> Void)? = nil)
```

`NotchOverlayView` 增加并列渲染分支；`AppLockContentView` 复用 `MinimalUnlockView` 的 `[左图标][间隙][视频]` 布局，把锁图标换成**被锁 App 的图标**，右侧仍播放 `unlockanimation.mp4` 等资源——视觉与整机解锁完全同族。

### 7.4 锁定呈现策略（★D2 定案：窗口级遮罩）

#### 7.4.1 可行性判定

**结论：可实现。** macOS **没有**公开 API 能让 A 进程给 B 进程的窗口"套一层遮罩"（跨进程不得操作他人 NSWindow）。但存在一条工程上完全可行的等价路径 —— **窗口跟踪面板（Window-Tracking Overlay）**：

> 不用"附着"到目标窗口，而是**在目标窗口正上方精确叠一个属于自己进程的面板**，其 frame 实时等于目标窗口 frame。视觉上完全等同于"这个 App 的界面被遮住了"。

#### 7.4.2 技术实现路径

```
① 定位目标 App 的窗口
   AXUIElementCreateApplication(pid)
     → kAXWindowsAttribute       取全部窗口
     → 过滤 subrole == kAXStandardWindowSubrole / 排除浮窗
     → 每窗读 kAXPositionAttribute + kAXSizeAttribute（全局屏幕坐标）
        （注：AX 坐标为左上原点，需转换为 Cocoa 左下原点）

② 在每个窗口上方贴一个面板
   WindowShieldPanel : NSPanel
     styleMask = [.borderless, .nonactivatingPanel]
     level     = .floating            （高于被锁 App 的普通窗口）
     frame     = 目标窗口 frame（精确等大）
     ignoresMouseEvents = false       （接收点击 → 挡住下层交互）
     contentView = NSHostingView(WindowShieldView())  ← 模糊/暗化 + 锁标识

③ 实时跟随（事件为主 + 轮询兜底）
   AXObserverAddNotification(app, window,
       kAXWindowMovedNotification / kAXWindowResizedNotification /
       kAXWindowCreatedNotification / kAXWindowMiniaturizedNotification)
     → 立即同步 frame / 增删面板
   兜底：每 150ms 用 kAXWindowsAttribute 重新枚举并 diff（防漏事件）

④ 与此同时，刘海面板叠加 glance 风格扫描动画（.appLock 内容）
```

**坐标系转换**（关键细节）：
```swift
let cocoaY = (NSScreen.screens.first?.frame.maxY ?? 0) /* 主屏最大Y */ - axRect.maxY
```
实际实现用 `NSScreen.screens` 的并集高度做翻转，并用 `NSScreen.screens.first(where: { $0.frame.contains(center) })` 判断所在屏。

#### 7.4.3 为什么它能满足"只遮罩软件界面"

- 遮罩面板 frame ≡ 目标窗口 frame → 只覆盖那个 App 的界面区域，其余屏幕照常可见可用。
- 面板接收点击 → 目标窗口收不到鼠标事件（挡住交互）。
- 直接**不调用** `hide()` → App 仍在原位（视觉上"看得见但被锁住"，比整屏消失更友好）。

#### 7.4.4 已知边界与兜底（务必实现）

| 场景 | 问题 | 兜底策略 |
|---|---|---|
| **全屏 Space**（App 进入全屏） | 窗口 frame = 全屏，AX 几何可能异常 | 自动切换「**隐藏模式**」（`hide()` + 刘海面板） |
| **Mission Control / Exposé** | 系统缩略图由窗口服务直绘，不含我们的面板 → **可能露出内容** | 检测到空间切换事件时临时 `hide()`（见下） |
| **多 Space / 窗口在别的空间** | 面板不会跟随到其他 Space | 面板 `collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]`；仍异常则降级隐藏 |
| **App 不支持 AX**（极少数） | 读不到窗口 | 降级隐藏模式 |
| **App 弹出新窗口 / sheet / popover** | 新窗口未被覆盖 | `kAXWindowCreatedNotification` + 150ms 轮询 diff 补齐 |
| **多显示器** | 坐标归属不同屏 | 按窗口中心点选屏，逐屏管理 |

**Mission Control 泄漏的缓解**：`NotchOverlay` 已有 `NSWorkspace` 观察能力，可监听空间切换（`NSWorkspace.activeSpaceDidChangeNotification`）—— 一旦检测到空间切换/全屏切换，**临时 `hide()` 被锁 App**（切回后如仍在锁定态则恢复遮罩）。这是"体验优先"与"安全优先"之间的折中。

#### 7.4.5 最终呈现模式（写入设置）

| 模式 | 行为 | 适用 |
|---|---|---|
| **窗口遮罩（默认）** | 不隐藏；跟踪面板覆盖窗口 + 刘海扫描 | 常规单/多窗口 App，体验最好 |
| **隐藏应用（最强）** | `hide()` + 刘海扫描 | 高安全诉求 / 全屏场景自动回落 |

- 自动回落：窗口遮罩模式下，若定位失败或进入全屏/Mission Control → **自动切隐藏模式**。
- 设置项：「锁定呈现」= 窗口遮罩（默认）/ 隐藏应用。

### 7.5 认证编排统一

保留 FaceGate 的优先级设计，**人脸分支替换为 glance 内核**：

```swift
@Observable @MainActor
final class AuthenticationCoordinator {
    enum Method { case face, touchID, appPassword }
    func authenticate(reason: String) async -> AuthOutcome
    // face 分支：调用共享 pipeline + liveness 的扫描循环
    // touchID：LAContext
    // appPassword：AppPasswordAuth.verifyPassword()
}
```

- 失败计数与锁定（5 次 / 60s）从 `AuthenticationManager` 原样迁移。
- **人脸超时/取消不计失败**（沿用 FaceGate 逻辑，便于退回 fallback）。
- 敏感操作（打开设置、退出、暂停保护）统一走 `authenticate(reason:)`，展示在刘海面板。

### 7.6 会话与计时合并

| 会话 | 归属 | 触发 | 语义 |
|---|---|---|---|
| `AppLockSessionManager`（原 FaceGate `SessionManager`） | 应用加锁域 | App 解锁后 | per-app 解锁有效期（300s/自定义/失焦计时/永久/立即） |
| `SessionAutoLocker`（glance） | 整机解锁域 | 空闲超时 | 凭据会话重锁（1/7/14/30 天） |

**联动**：`LockMonitor` 捕获 `willSleep`/`screenLocked` 时，**同时** `appLockSessionManager.revokeAllSessions()`（沿用 FaceGate `lockOnSleep` 开关）→ 保留"合盖即全锁"语义。

### 7.7 持久化与 Keychain（不做迁移）

| 项 | 方案 |
|---|---|
| UserDefaults | 统一 `FID.` 前缀；`GlanceSettings.Key.*` 改为 `FID.settings.*` |
| Keychain service | `com.<组织>.faceid`；`keychain-access-groups` 同步 |
| 数据目录 | `~/Library/Application Support/Face ID/` |
| 人脸库 | 采用 glance 的 `face-identities.enc`（AES-GCM + session key） |
| 应用密码 | FaceGate 的 `SHA-256 + 32 字节盐` → 存 Keychain |
| **迁移** | **不做**（D3）。首启检测到无已录入人脸 → 强制完整引导；旧版本遗留数据一律忽略 |

### 7.8 并发模型统一

| FaceGate 现状 | 合并后 |
|---|---|
| `class X: ObservableObject` + `@Published` | `@Observable final class X`（+ `@MainActor`） |
| `DispatchQueue.main.async { ... }` | `Task { @MainActor in ... }` / `await` |
| 闭包回调 `completion: (Bool)->Void` | `async -> Result` |
| Combine `Timer` | `Task.sleep` 循环或保留 `Timer` |

**迁移注意**：`SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` 下所有类型默认主 actor 隔离；`nonisolated` 计算（如 `FaceRecognitionPipeline` 的静态属性）需显式标注。FaceGate 的 `static let shared = X()` 若含重活（如 Keychain 读取）应改懒加载。

### 7.9 权限与构建配置统一

合并后的 `Face ID.entitlements`：

```xml
<key>com.apple.security.app-sandbox</key><false/>
<key>com.apple.security.device.camera</key><true/>
<key>com.apple.security.cs.disable-library-validation</key><true/>
<key>keychain-access-groups</key>
<array><string>$(AppIdentifierPrefix)com.&lt;org&gt;.faceid</string></array>
```

**TCC 运行时权限**：摄像头、**辅助功能**（整机解锁密码注入 **+ 窗口级遮罩定位**，D2 依赖）、输入监控（空格键触发，可选）。

---

## 八、新建代码清单（含接口契约）

### 8.1 `Domain/AppLock/WindowTracker.swift`（★D2 核心）

```swift
@MainActor
final class WindowTracker {
    struct TargetWindow: Hashable {
        let windowID: CGWindowID        // 或用 AXUIElement 引用
        let element: AXUIElement
        var frame: CGRect               // Cocoa 坐标
        var isMinimized: Bool
    }

    /// 枚举目标 App 的全部标准窗口
    func windows(forPID pid: pid_t) -> [TargetWindow]

    /// 注册 AX 通知 + 150ms 轮询兜底；回调在主线程
    func startObserving(pid: pid_t, onChange: @escaping ([TargetWindow]) -> Void)
    func stopObserving(pid: pid_t)

    static func isAccessibilityTrusted() -> Bool
}
```

### 8.2 `Domain/AppLock/WindowShieldManager.swift`（★D2 核心）

```swift
@MainActor
final class WindowShieldManager {
    enum Mode { case windowShield, hidden }

    private var panels: [CGWindowID: WindowShieldPanel] = [:]
    private var tracker = WindowTracker()

    /// 对目标 App 施加遮罩（默认窗口遮罩，失败自动回落隐藏）
    func shield(pid: pid_t, appName: String, icon: NSImage?)
    /// 移除全部遮罩面板
    func unshield()
    /// 当前实际生效的模式（可能因回落与请求值不同）
    private(set) var effectiveMode: Mode
}
```

### 8.3 `Coordination/AppUnlockCoordinator.swift`

```swift
@Observable @MainActor
final class AppUnlockCoordinator {
    func start()
    func handleDetected(bundleID: String, app: NSRunningApplication)
    func retryCurrent() async
    func cancelCurrent()
    private func runCycle(bundleID: String, app: NSRunningApplication) async
}
```

### 8.4 `UI/Shield/WindowShieldPanel.swift` / `WindowShieldView.swift`

```swift
final class WindowShieldPanel: NSPanel {
    init(frame: CGRect, content: WindowShieldView)
    // styleMask [.borderless, .nonactingPanel]; level .floating
    // collectionBehavior [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
    // ignoresMouseEvents = false（挡住交互）
}

struct WindowShieldView: View {
    let appName: String
    let icon: NSImage?
    // 半透明暗化 + 高斯模糊感 + 居中「锁」图标 + App 名 + "Face ID 已锁定"
}
```

### 8.5 `UI/Notch/AppLockContentView.swift`

```swift
struct AppLockContentView: View {
    let content: AppLockContent
    let media: ScanMedia
    let pulseScale: CGFloat
    let pulseOpacity: Double
    // 布局：[AppIcon 40pt][gap 12][ScanAnimationView(media)]，与 MinimalUnlockView 同族
}
```

### 8.6 `UI/Settings/Pages/LockedAppsSettingsPage.swift`

复用 glance 的 `SettingsRow/Group/GlanceToggle/SettingsActionRow`。列出已锁 App（图标+名称+开关+计时配置），「+ 添加应用」调 `InstalledAppsScanner`，支持搜索；新增「锁定呈现」模式选择（窗口遮罩 / 隐藏）。

### 8.7 `Constants/FIDConstants.swift`

```swift
enum FIDConstants {
    enum NS { static let prefix = "FID." }
    static let matchThreshold: Float = 0.63
    static let thresholdPresets: [Float] = [0.58, 0.63, 0.68]
    static let defaultAppSessionTimeout: TimeInterval = 300
    static let indefiniteSessionValue: TimeInterval = -1
    static let maxFailedAttempts = 5
    static let lockoutDuration: TimeInterval = 60
    static let windowTrackPollInterval: TimeInterval = 0.15
    static var appSupportDirectory: URL { ... }      // .../Face ID
    static let keychainService = "com.<org>.faceid"
}
```

---

## 九、分阶段实施计划

> **总原则**：每阶段结束必须「可编译 + 可运行 + 通过该阶段验收」，再进入下一阶段。

### Phase 0 — 工程合并与骨架

| 任务 | 产出 |
|---|---|
| 0.1 复制 `glance-main` 为 `Face ID/`，源码根重命名 `FaceID/` | 新工程 |
| 0.2 重命名 target/product 为 `Face ID`，bundle id `com.<org>.faceid`，更新 entitlements/Info.plist | 可独立编译运行 |
| 0.3 建立 `Domain/`、`Coordination/`、`UI/Shield/`、`Constants/` 骨架 | 空目录 + 占位 |
| 0.4 新增 `FIDConstants.swift`，建立 `FID.` 命名空间 | 常量真源 |
| 0.5 验证文件系统同步组：新增文件自动入 target | 编译通过 |

**验收**：原 glance 功能全量回归通过，工程改名无残留。

### Phase 1 — 人脸内核统一

| 任务 | 产出 |
|---|---|
| 1.1 冻结 `FaceRecognitionPipeline` 为唯一识别入口 | 接口冻结 |
| 1.2 增加 `CameraArbiter` 串行化 | 互斥可用 |
| 1.3 阈值三档统一桥接（`FIDConstants` → `GlanceSettings`） | 单一真源 |
| 1.4 `VectorMath`/相似度去重 | 一套数学工具 |

**验收**：识别 + 活体在 Face Lab 数值正常；无 FaceGate 残留模型被引用。

### Phase 2 — 加锁能力移植（无 UI 内核）

| 任务 | 产出 |
|---|---|
| 2.1 移植 `AppMonitor`（`@Observable` + MainActor） | Domain/AppLock |
| 2.2 移植 `LockedAppsStore`（改 `@Observable`，key 迁 `FID.`） | 数据层 |
| 2.3 移植 `AppLockSessionManager` | 会话层 |
| 2.4 移植 `AppLocker`（去掉 overlay） | 执行层 |
| 2.5 移植 `InstalledAppsScanner`、`LockedApp` | 支撑 |
| 2.6 移植 `AppPasswordAuth`、`TouchIDAuth`、`CryptoHelper` | 安全层 |
| 2.7 移植 `AppScheduleManager`（P1）、`GlobalHotkeyManager`（P2） | 增强 |

**验收**：可用调试入口锁定某 App 并触发拦截逻辑；单元测试覆盖 store CRUD 与会话计时。

### Phase 3 — 窗口级遮罩子系统（★D2 交付）

| 任务 | 产出 |
|---|---|
| 3.1 实现 `WindowTracker`：AX 枚举 + 坐标转换 + AXObserver 监听 + 轮询兜底 | 窗口定位 |
| 3.2 实现 `WindowShieldPanel` / `WindowShieldView` | 遮罩外观 |
| 3.3 实现 `WindowShieldManager`：增删/同步/diff | 管理器 |
| 3.4 实现**自动回落**：全屏/Mission Control/定位失败 → 隐藏模式 | 兜底 |
| 3.5 监听 `activeSpaceDidChangeNotification`，空间切换时临时隐藏 | 防泄漏 |
| 3.6 多显示器坐标归属与逐屏管理 | 兼容 |

**验收**：锁定某 App，其每个窗口被独立遮罩；拖动/缩放窗口遮罩实时跟随；进入全屏自动回落隐藏；Mission Control 中不露出内容。

### Phase 4 — 刘海 UI 融合

| 任务 | 产出 |
|---|---|
| 4.1 `NotchOverlayController.Content` 新增 `.appLock` | 内容枚举 |
| 4.2 新增 `presentAppLock(_:onRetry:)`，复用扫描状态机 | 控制器 |
| 4.3 新建 `AppLockContentView`，复用 `ScanAnimationView` | 视图 |
| 4.4 `NotchOverlayView` 增加 `.appLock` 渲染分支 | 渲染 |
| 4.5 验证点击穿透矩形在 `.appLock` 下正确 | 交互 |
| 4.6 遮罩 + 刘海叠加的层级/焦点实测 | 联调 |

**验收**：双击被锁 App → 窗口被遮罩 + 刘海面板滑出显示 App 图标与扫描 → 刷脸成功 → 遮罩消失、App 恢复可交互。

### Phase 5 — 编排与认证整合

| 任务 | 产出 |
|---|---|
| 5.1 新建 `AppUnlockCoordinator` | 编排层 |
| 5.2 改造 `AuthenticationManager` → `AuthenticationCoordinator` | 认证层 |
| 5.3 `AppDelegate` 接线：`AppMonitor.onDetected → AppUnlockCoordinator` | 装配 |
| 5.4 `LockMonitor` 事件联动 App 会话重锁 | 联动 |
| 5.5 失败计数/锁定/冷却统一 | 安全策略 |

**验收**：多因子 fallback 正常；失败 5 次锁定 60s；合盖/锁屏后所有 App 会话重置。

### Phase 6 — 设置与引导整合

| 任务 | 产出 |
|---|---|
| 6.1 新建 `LockedAppsSettingsPage`，加入 `SettingsTab` | 设置页 |
| 6.2 引导新增「选择加锁 App」步骤；首启强制完整引导（D3） | 引导 |
| 6.3 菜单栏增加"锁定全部/解锁全部"与当前状态 | 菜单 |
| 6.4 设置内「锁定呈现」模式切换（窗口遮罩 / 隐藏） | D2 开关 |

**验收**：设置内可增删被锁 App、配置计时与呈现模式；引导完整走通；菜单栏可控。

### Phase 7 — 联调、测试、打包

| 任务 | 产出 |
|---|---|
| 7.1 全链路回归（§12） | 测试报告 |
| 7.2 性能：CPU/内存/模型加载/摄像头/窗口跟踪开销 | 性能基线 |
| 7.3 边界：多显示器、外接摄像头、无刘海 Mac、休眠唤醒、全屏 | 兼容性 |
| 7.4 Sparkle 更新源配置、DMG 打包、签名策略 | 发布件 |
| 7.5 文档：README、SECURITY、权限说明 | 交付文档 |

**验收**：§13 验收标准全绿。

---

## 十、权限、安全与合规

### 10.1 权限矩阵

| 权限 | 用途 | 类型 | 是否必需 |
|---|---|---|---|
| 摄像头 | 取脸 | entitlement + TCC | ✅ |
| 密钥链 | 存密钥/密码哈希 | entitlement | ✅ |
| **辅助功能（Accessibility）** | 整机解锁注入密码 **+ 窗口遮罩定位** | TCC 运行时 | ✅（两项功能都依赖） |
| 输入监控（Input Monitoring） | 空格键触发 | TCC（经 Accessibility 隐式） | ⚠️ 可选 |
| 触摸 ID | 会话密钥门控 | LAContext | ✅（有硬件时） |
| App 沙盒 | — | **必须关闭** | ✅ |
| 加固运行时 | — | 开启 | ✅ |
| `disable-library-validation` | Sparkle + SkyLight | entitlement | ✅ |

> **D2 带来的变化**：辅助功能权限从"仅整机解锁需要"变为**两项功能都强依赖**（窗口定位与跟随靠 AX）。首次引导需明确说明。

### 10.2 安全边界（必须写进产品说明）

- 本产品是**便利层**，非抗定向攻击的强安全方案（2D 摄像头无景深）。
- 活体可挡打印照片、手机屏幕照片；**不可靠地挡视频重放**。
- 人脸嵌入 AES-GCM 加密落盘，密钥由触摸 ID 门控，仅授权会话期间在内存。
- **窗口遮罩模式的安全说明（诚实告知）**：遮罩为"覆盖式"，在原 App 窗口上方叠面板。极端情况下（Mission Control 缩略图、全屏空间切换瞬间）**可能短暂露出内容**；已在实现中对空间切换做临时隐藏缓解。**若需最强保证，请在设置中选「隐藏应用」模式**。
- 零遥测；仅 Sparkle 每日检查更新（可关）。

### 10.3 私有 API 与上架

- `NotchSkyLight`（`dlopen` SkyLight.framework）用于"锁屏时刘海面板可见"，**会导致无法上架 Mac App Store**。
- **处置**：默认保留（代价：仅直发/DMG）；提供编译开关 `FID_ENABLE_SKYLIGHT`，关闭即恢复上架能力（锁屏时面板不可见）。

### 10.4 商标提示

Apple 对 "Face ID" 拥有注册商标。个人/开源自用无碍；**若商业化分发建议改名**。所有命名在本计划中均为可批量替换的标识。

---

## 十一、风险登记册与对策

| ID | 风险 | 概率 | 影响 | 对策 |
|---|---|---|---|---|
| R1 | 两套并发模型混用致数据竞态/UI 不刷新 | 高 | 高 | 按 §7.8 逐文件改造；禁止 `DispatchQueue` 与 Observation 混用 |
| R2 | 摄像头被两个域同时占用 | 中 | 高 | `CameraArbiter` 串行化 |
| R3 | 遮罩面板与目标窗口层级/焦点冲突 | 中 | 中 | 面板 `level = .floating` + `nonactivatingPanel`；持续校验重贴 |
| **R4** | **窗口遮罩在 Mission Control/全屏下露出内容** | 中 | 高 | 空间切换监听 + 自动回落隐藏模式；设置可强制隐藏模式 |
| **R5** | **目标 App 不支持 AX / 窗口几何异常** | 中 | 中 | 检测失败即回落隐藏模式；AX 信任状态前置检查 |
| R6 | Swift 6 默认 MainActor 隔离与 FaceGate 代码冲突 | 高 | 中 | 逐文件加 `@MainActor`；重活移 `nonisolated`/`Task.detached` |
| R7 | 私有 SkyLight API 在新系统失效致崩溃 | 低 | 高 | 加载失败即退化；编译开关可整体关闭 |
| R8 | 双 Sparkle 更新器冲突 | 中 | 中 | 仅保留 glance 的 `UpdaterController` |
| R9 | 最小系统从 14 升到 15 丢用户（D1 已确认） | 确定 | 低 | 明确产品说明 |
| R10 | 阈值/常量不统一致行为漂移 | 中 | 中 | 单一真源 `FIDConstants`；一致性测试 |
| R11 | 无单元测试，回归靠手工 | 确定 | 中 | 新建测试 target（§12） |
| R12 | 窗口跟踪轮询带来 CPU 占用 | 中 | 低 | 事件优先 + 150ms 轮询；无锁定态时不轮询 |
| R13 | 产品名 "Face ID" 商标争议 | 低 | 中 | 见 §10.4；命名可批量替换 |
| R14 | `CONTRIBUTING.md`/README 与实际实现不符误导后续开发 | 低 | 中 | 以源码为准（已校正：FaceGate 实为 hide 而非 SIGKILL；embedding 实为 512 非 128） |

---

## 十二、测试计划

### 12.1 测试分层

| 层 | 手段 | 覆盖 |
|---|---|---|
| 单元测试（新建 target） | XCTest / Swift Testing | `LockedAppsStore` CRUD、`AppLockSessionManager` 计时（含 -1/0）、阈值匹配、`VectorMath`、**AX 坐标转换** |
| 集成测试 | 无 UI 逻辑链路 | AppMonitor 事件 → 判定 → 会话检查；认证优先级；`WindowTracker` diff |
| UI/手动测试 | 手动清单 | 刘海动画、窗口遮罩跟随、引导、设置页、多显示器 |
| 端到端 | 真机场景 | 整机解锁、App 加锁全链路 |

### 12.2 关键回归用例（必测）

**整机解锁域**
1. 唤醒触发刷脸 → 本人通过 → 密码注入成功解锁。
2. 他人/照片 → 失败动画 → 悬停重试。
3. 活体 light/heavy 切换行为差异。
4. 无刘海 Mac → 胶囊样式正常。

**应用加锁域（窗口遮罩）**
5. 锁定微信 → 双击打开 → **仅微信窗口被遮罩** + 刘海面板扫描 → 刷脸通过 → 遮罩消失、微信恢复。
6. **拖动/缩放被锁 App 窗口 → 遮罩实时跟随，无错位**。
7. **被锁 App 新开窗口/sheet → 新窗口被自动补上遮罩**。
8. **进入全屏 → 自动回落隐藏模式**；退出全屏 → 恢复窗口遮罩。
9. **触发 Mission Control → 被锁 App 不露出内容**。
10. 多显示器：窗口在副屏 → 遮罩出现在副屏且坐标正确。
11. 会话内切换走再切回 → 不重复弹面板；会话过期 → 重新弹。
12. "立即锁定"模式解锁后 1 秒冷却生效（不循环弹）。
13. 取消/验证失败 → 遮罩移除 → 微信被隐藏并终止（含 1s 兜底 forceTerminate）。
14. 合盖/锁屏 → 所有 App 会话重置 → 唤醒后重新拦截。
15. 切换「隐藏应用」模式 → 行为符合预期。
16. 目标 App 不支持 AX（构造用例）→ 自动回落隐藏模式。

**交叉场景**
17. 整机解锁扫描中同时触发 App 加锁 → 摄像头串行，不冲突。
18. 被锁 App 在后台被激活（通知点击）→ 正确拦截。

### 12.3 性能基线（目标）

| 指标 | 目标 |
|---|---|
| 冷启动到菜单栏就绪 | < 2s |
| 模型加载 | < 500ms（可预热） |
| 单帧识别延迟 | < 60ms（ANE） |
| 窗口跟踪开销（锁定态） | CPU < 3%，无锁定态 0 |
| 空闲 CPU / 内存 | < 1% / < 150MB |

---

## 十三、验收标准与交付物

### 13.1 验收标准（Definition of Done）

- [ ] 一款名为 **Face ID** 的 App，同时具备整机解锁 + 按 App 加锁，共用同一人脸库与内核。
- [ ] 全程只有一套视觉语言（刘海 UI），App 加锁弹窗与整机解锁同族。
- [ ] **App 加锁默认只遮罩被锁 App 的窗口**，窗口移动/缩放实时跟随；异常场景自动回落隐藏模式。
- [ ] 多因子认证（人脸→TouchID→密码）+ 失败锁定 + 冷却完整可用。
- [ ] 设置内可管理被锁 App 与呈现模式；引导完整；菜单栏可控。
- [ ] **首次启动强制完整引导、全新录入人脸**（不做迁移）。
- [ ] 常量/阈值/命名空间单一真源；权限/安全说明齐备；私有 API 有开关可关。
- [ ] 关键回归用例（§12.2，共 18 条）全绿。
- [ ] 可打包为 DMG 并可安装运行。

### 13.2 交付物清单

| 交付物 | 说明 |
|---|---|
| `Face ID.xcodeproj` | 合并后工程 |
| 可运行 `.app` / `.dmg` | 构建产物 |
| `README.md` + `SECURITY.md` | 使用与安全说明 |
| 测试 target 与用例 | 自动化回归 |
| 本计划书 | 实施依据（持续更新） |

---

## 十四、下一步

四项决策已全部定案，**可以立即进入 Phase 0**：

1. 复制 `glance-main` → 建立 `Face ID/` 工程，源码根 `FaceID/`；
2. 重命名 target / bundle id / entitlements / Info.plist 为 Face ID；
3. 建立 `Domain/`、`Coordination/`、`UI/Shield/`、`Constants/` 骨架 + `FIDConstants.swift`；
4. 编译验证骨架可运行（原 glance 功能回归）。

随后按 Phase 1 → 7 顺序推进，每个 Phase 结束交付可运行版本供验收。

---

*本计划书基于对两个项目源码的逐文件剖析（含 `Core/`、`Auth/`、`FaceAuth/`、`NotchOverlay/`、`Onboarding/`、`Settings/` 等全部模块）编写，并已校正两处上游文档与实际实现的偏差：FaceGate 的加锁实现为 `NSRunningApplication.hide()` 而非进程终止；人脸嵌入维度为 512 而非 README 所述的 128。*
