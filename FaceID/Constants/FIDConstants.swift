//
//  FIDConstants.swift
//  Face ID
//
//  Single source of truth for cross-cutting constants. Anything two features
//  must agree on — thresholds, paths, timeouts, key prefixes — lives here and
//  is never re-declared as a literal at the call site.
//

import Foundation

/// Face ID 的全局常量单一真源。
///
/// `nonisolated` 是刻意的：项目的默认隔离是 `MainActor`，而这些常量必须能被
/// 后台任务里的 `nonisolated` 代码读取（例如检测/嵌入管线）。
nonisolated enum FIDConstants {

    // MARK: - 身份 Identity

    /// 产品显示名。
    static let appName = "Face ID"

    /// Bundle 标识符（须与 project.pbxproj 的 PRODUCT_BUNDLE_IDENTIFIER 一致）。
    static let bundleIdentifier = "com.joeqiao.faceid"

    /// Keychain service 名。整机解锁与应用加锁共用同一命名空间。
    static let keychainService = "com.joeqiao.faceid"

    // MARK: - 命名空间 Namespacing

    /// UserDefaults 键前缀。所有新增键都必须以此开头。
    static let defaultsPrefix = "FID."

    /// 设置项键前缀（原 `glance` 的 `GlanceSettings.*`）。
    static let defaultsSettingsPrefix = "FID.settings."

    // MARK: - 人脸识别 Face recognition

    /// ArcFace 输出嵌入维度。
    static let embeddingDimension = 512

    /// 模型输入边长，正方形、像素。
    static let modelInputSize = 112

    /// 默认余弦相似度阈值（宽松 / 标准 / 严格三档中的「标准」）。
    ///
    /// **两套数值，按当前嵌入器选取** —— 余弦相似度只有在同一个嵌入空间里才可比：
    /// ArcFace 同人一对通常落在 0.45–0.8、异人 0.0–0.3（`FaceEmbedding` 的注释也写
    /// 着典型切点 0.28–0.40）；Vision Feature Print 整体偏高。早期沿用 Vision 时代的
    /// 0.63 去卡 ArcFace，会让大量本人照片够不到阈值，表现为「经常验证不过」。
    static var matchThreshold: Float { thresholdPresets[1] }

    /// ArcFace `w600k_mbf` 的三档切点（宽松 / 标准 / 严格）。
    static let arcFaceThresholdPresets: [Float] = [0.36, 0.43, 0.50]

    /// Vision Feature Print 的三档切点 —— 旧值原样保留，回退到该嵌入器时不能变松。
    static let visionThresholdPresets: [Float] = [0.58, 0.63, 0.68]

    /// 旧版本只存过这组绝对值，`FIDSettings` 用它把用户已选的严格度换算到新表。
    static let legacyThresholdPresets: [Float] = [0.58, 0.63, 0.68]

    /// 「匹配严格度」三档滑块的所有可选值，由窄到宽解释为 宽松 → 标准 → 严格。
    /// 设置界面与 `FIDSettings` 默认值都必须取自这里，禁止再写字面量。
    static var thresholdPresets: [Float] {
        usesArcFace ? arcFaceThresholdPresets : visionThresholdPresets
    }

    /// 模型随包分发时才有 ArcFace；缺失时 `FaceRecognitionPipeline` 会回落 Vision，
    /// 阈值必须跟着换表，否则回落后的识别会变得过松。
    static var usesArcFace: Bool {
        Bundle.main.url(forResource: "ArcFace", withExtension: "mlmodelc") != nil
    }

    /// 单样本最近邻与整体模板之间允许的落差。
    ///
    /// 只要求「有一个样本像」会太松，只要求「平均模板像」又会让多角度/多距离录入
    /// 白白稀释掉真实匹配 —— 所以主判据取 top-k 均值，平均模板只做一道更低的兜底。
    static let centroidSimilaritySlack: Float = 0.12

    /// top-k 均值的 k。k 太小退化成最近邻（易被单帧噪声命中），太大又接近平均模板。
    static let matchTopKSampleCount = 3

    /// 默认「人脸最小宽度」——人脸框宽度占画面宽度的比例，越大越要求靠近镜头。
    static let defaultMinimumFaceWidth: Float = 0.19

    /// 「检测距离」三档滑块的取值：近 / 标准 / 远。
    static let minimumFaceWidthPresets: [Float] = [0.23, 0.19, 0.15]

    /// 判定「这是路人而非镜头前的人」的硬性下限。
    /// 低于此值的人脸一律不参与识别（比 `defaultMinimumFaceWidth` 更宽松，
    /// 用于让「站得远」被识别为可提示而非直接无人）。
    static let minimumProminentFaceWidthFloor: Float = 0.18

    /// 单次扫描窗口时长（秒）——从**首帧**开始计算，不是从调用 `start()` 开始。
    static let scanWindowSeconds = 5

    /// 相机冷启动宽限（秒）。`AVCaptureSession.startRunning()` 到第一帧之间通常要
    /// 0.8–2 秒，休眠唤醒后更久；这段等待过去被算进了扫描窗口，于是窗口还没真正
    /// 看到人就到期了。现在窗口从首帧起算，这个值只是"最多等多久才开始计分"。
    static let cameraWarmupAllowance: TimeInterval = 4

    /// 首帧之后至少经过这么久，才允许把"认不出本人"判成失败。
    ///
    /// 用户刚坐下、刚唤醒、或刚把视线从别处转过来时，前几百毫秒的人脸往往没对正。
    /// 这段宽限期内只累计分数、不累计失败，避免"一开扫就判错"。
    static let wrongFaceGraceDuration: TimeInterval = 1.2

    /// 同时要求至少这么多帧真正参与打分，才算"确实不是本人"。
    /// 与时间宽限取「与」关系：两个条件都满足才允许判定失败。
    static let wrongFaceMinScoredFrames = 15

    /// 持续识别不到本人多久后提前放弃本轮（秒）。
    ///
    /// 超过宽限期后先只做记录、继续扫描 —— 用户可能只是转了下头，后面还有机会匹配上。
    /// 但真遇到陌生人时不该让他等满整个窗口，所以持续错这么久才提前结束。
    static let wrongFaceAbortDuration: TimeInterval = 2.5

    /// 选取采集格式时要求的最低帧率。
    ///
    /// 只按分辨率挑会选中 4K@5fps 这类格式：管线每帧都要跑 Vision + ArcFace，
    /// 帧率不足会直接表现为"扫不到人"。
    static let preferredMinimumFrameRate: Double = 24

    /// 录入时要求的人脸最小宽度下限——比解锁更严格：
    /// 坐在椅子上够解锁，但不足以生成可靠的模板。
    static let enrollmentMinimumFaceWidthFloor: Float = 0.2

    /// 录入姿势总数：9 个头姿 + 2 个距离阶段（近 / 稍远）。
    /// 距离阶段用的是同一套采集循环，只是人脸宽度区间不同。
    static let enrollmentPoseCount = 11

    /// 每个姿势的录入样本数（11 × 2 = 22）。
    static let enrollmentSamplesPerPose = 2

    // MARK: - 应用加锁 App locking

    /// 单个被锁 App 的默认解锁会话时长（秒）。
    static let defaultAppSessionTimeout: TimeInterval = 300

    /// 「永久解锁」哨兵值。
    static let indefiniteSessionValue: TimeInterval = -1

    /// 解锁后的重锁冷却（秒）——防止「立即锁定」模式下陷入自锁循环。
    static let reLockCooldown: TimeInterval = 1.0

    /// 要求被锁 App 自行退出时的宽限期（秒），超时后强制终止。
    static let terminateGracePeriod: TimeInterval = 1.0

    /// 连续多少帧判定为「非本人」才触发失败。单帧误判不该弹失败动画。
    /// 整机解锁与应用加锁共用一处，避免两条链路各自调参后行为不一致。
    static let wrongFaceStreakThreshold = 6

    // MARK: - 窗口级遮罩 Window shield (D2)

    /// 被锁 App 的锁定呈现方式。
    enum ShieldMode: String, CaseIterable, Identifiable {
        /// 只覆盖该 App 自己的窗口，其余屏幕照常可用（默认）。
        case windowShield
        /// 直接隐藏该 App——最强隔离，也是窗口定位失败时的兜底。
        case hidden

        var id: String { rawValue }

        var title: String {
            switch self {
            case .windowShield: return "只遮罩应用窗口"
            case .hidden: return "隐藏应用"
            }
        }
    }

    /// 窗口几何轮询兜底间隔（秒）。AX 事件为主，轮询只用于防止漏事件。
    static let windowTrackPollInterval: TimeInterval = 0.15

    /// 铺遮罩前，等待被锁 App 首个可见窗口出现的最长时间（秒）。
    ///
    /// 刚启动的 App 会在窗口布局完成之前就被报告为「已激活」，此时读到的窗口
    /// 列表是空的。若立刻据此回落到隐藏模式，窗口遮罩对"新启动"这一类场景就
    /// 永远失效了 —— 短暂等待能让它拿到真实窗口。
    static let windowSettleTimeout: TimeInterval = 0.35

    /// 检测到「被锁应用到了前台」后，最多等这么久看它是否真的画出窗口。
    ///
    /// 关掉窗口仍留在后台的微信被系统激活时（例如刚退出照片），既没有窗口也没有内容 ——
    /// 此时弹认证、铺遮罩都是噪音。反过来，窗口稍后才出现的应用要在这个宽限内接住。
    static let windowAppearGrace: TimeInterval = 0.45

    /// 应急全屏遮罩的最短在屏时长（秒）。
    ///
    /// 对**已在运行**的应用，`shield` 第一次读窗口就能拿到几何，遮罩会在同一个
    /// runloop 轮次里被建好又撤掉 —— 窗口服务器一帧都没画，用户看到的就是
    /// 「没有全屏遮罩、界面先露出来」。约 4 帧，足以让它真正合成一次。
    static let emergencyCoverMinimumOnScreen: TimeInterval = 0.06

    /// 应急全屏遮罩在「窗口遮罩尚未合成」时最多继续停留的时长（秒）。
    ///
    /// 撤销条件不只是「显示够久」：新建的窗口遮罩面板 `orderFront` 之后，窗口
    /// 服务器还要一两个轮次才真正合成。若此时就撤掉全屏遮罩，中间那一帧会露出
    /// App 界面 —— 即「全屏遮罩消失、界面先露出来」。因此等窗口遮罩全部可见再撤，
    /// 但用这个上界兜底，绝不能无限挡屏。
    static let emergencyCoverMaxWait: TimeInterval = 0.5

    /// 进程启动多久之内算「冷启动」（秒）。
    ///
    /// 用于区分两种「没有屏上窗口」：冷启动时窗口还没建出来（必须立刻铺全屏
    /// 遮罩，否则用户会先看到界面）；而一个几小时前启动、窗口只是被关掉的进程
    /// （微信）被系统激活时，铺遮罩只会造成黑闪与无意义认证。
    static let freshLaunchThreshold: TimeInterval = 5.0

    /// 「等窗口出现」轮询的步长（秒）。约一帧，尽量缩短「窗口已画出但遮罩未上」
    /// 的可见时间。
    static let windowProbeInterval: TimeInterval = 0.016

    /// 遮罩面板相对目标窗口的外扩量（点），保留窗口自身阴影边缘。
    static let shieldPanelOutset: CGFloat = 0

    /// 遮罩的暗化强度（0–1）。压在被模糊后的窗口内容之上。
    static let shieldDimOpacity: Double = 0.45

    /// 窗口覆盖达到单块屏幕的这个比例，就判定为「全屏」。
    /// 此时窗口没有可供遮罩"贴附"的可辨别边界，且会占据独立 Space，
    /// 因此直接回落隐藏模式。
    static let fullScreenCoverageThreshold: CGFloat = 0.95

    /// 单个 App 允许被贴附遮罩的最大窗口数。防御性上限：AX 偶发返回
    /// 大量非标准窗口时，不至于为它们铺满整屏面板。
    static let maxShieldedWindows = 12

    // MARK: - 安全 Security

    /// 连续失败多少次后进入锁定。
    static let maxFailedAttempts = 5

    /// 锁定时长（秒）。
    static let lockoutDuration: TimeInterval = 60

    // MARK: - 键与账号 Keys & accounts

    /// UserDefaults 键。**新增键一律加在这里**，调用点不得写字符串字面量，
    /// 否则就会重新出现 Phase 1 之前那种"多处默认值各说各话"的问题。
    enum Defaults {
        // 应用加锁列表与会话
        static let lockedApps = "FID.appLock.lockedApps"
        static let appLockSessionTimeout = "FID.appLock.sessionTimeout"
        static let appLockSessionTimerFromFocus = "FID.appLock.sessionTimerFromFocus"
        static let appLockTouchIDEnabled = "FID.appLock.touchIDEnabled"
        static let appLockShieldMode = "FID.appLock.shieldMode"

        // 会话密钥的保护方式 —— 见 `SecureCredentialManager.SessionKeyProtection`
        static let sessionKeyProtection = "FID.settings.sessionKeyProtection"

        // 定时锁 / 解锁窗口（每个窗口整体作为一个 JSON blob 持久化，
        // 因为它们始终一起读写，拆成 5 个标量键反而容易写坏中间态）
        static let lockSchedule = "FID.appLock.schedule.lock"
        static let unlockSchedule = "FID.appLock.schedule.unlock"
        static let scheduleUserOverrides = "FID.appLock.schedule.userOverrides"

        // 行为
        static let appLockEnabled = "FID.appLock.enabled"
        static let lockAppsOnSleep = "FID.appLock.lockOnSleep"
        static let launchAtLogin = "FID.launchAtLogin"

        // 临时暂停保护（菜单栏「暂停 N 分钟」）
        static let protectionTemporarilyDisabled = "FID.appLock.protectionDisabled"
        static let protectionDisableExpiry = "FID.appLock.protectionDisableExpiry"
    }

    /// Keychain 账户名。所有条目共用 `keychainService` 这一个 service。
    enum KeychainAccount {
        /// 应用密码的 SHA-256 摘要（加了随机盐）。
        static let appPasswordHash = "appPasswordHash"
        /// 应用密码的随机盐。
        static let appPasswordSalt = "appPasswordSalt"
    }

    // MARK: - 定时窗口默认值 Schedule defaults

    /// 默认「锁定时段」起 = 22:00，止 = 07:00（跨午夜）。
    static let defaultLockScheduleStartHour = 22
    static let defaultLockScheduleEndHour = 7
    /// 默认「解锁时段」起 = 07:00，止 = 22:00。
    static let defaultUnlockScheduleStartHour = 7
    static let defaultUnlockScheduleEndHour = 22

    /// 定时器周期（秒）—— 评估锁/解锁窗口。
    static let scheduleEvaluationInterval: TimeInterval = 30

    // MARK: - 路径 Paths

    /// `~/Library/Application Support/` 下的数据目录名。
    static let appSupportFolderName = "Face ID"

    /// 加密人脸库文件名。
    static let faceStoreFileName = "face-identities.enc"

    /// 应用数据目录；不存在时创建。
    static var appSupportDirectory: URL {
        let fm = FileManager.default
        let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = base.appendingPathComponent(appSupportFolderName, isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    // MARK: - 编译开关 Build flags

    /// 私有 SkyLight API（让刘海面板在锁屏时可见）总开关。
    ///
    /// 默认**开启**（D1 决策：保留整机解锁的锁屏可见能力）。
    /// 代价是丧失 Mac App Store 上架资格；定义 `FID_DISABLE_SKYLIGHT`
    /// 编译条件即可关闭该能力并恢复上架资格。
    static var isSkyLightEnabled: Bool {
        #if FID_DISABLE_SKYLIGHT
        return false
        #else
        return true
        #endif
    }
}
