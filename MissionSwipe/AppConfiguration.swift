import Foundation

enum LogCopyLineCount: Int, CaseIterable {
    case fifty = 50
    case hundred = 100
    case twoHundred = 200
    case fiveHundred = 500
    case all = 0   // 0 sentinel value = copy the entire log

    var displayLabel: (en: String, zh: String) {
        switch self {
        case .fifty:        return ("50 lines", "最近 50 行")
        case .hundred:      return ("100 lines", "最近 100 行")
        case .twoHundred:   return ("200 lines", "最近 200 行")
        case .fiveHundred:  return ("500 lines", "最近 500 行")
        case .all:          return ("Entire log", "完整日志")
        }
    }
}

enum SmartFitOverflowStrategy: String, CaseIterable {
    case minimize             // Default: minimize windows that don't fit cleanly
    case tolerateOverlap      // Keep all windows visible, accept some overlap
    case stackWithPeek        // Cascade all windows with peek edges as a fallback

    var displayLabel: (en: String, zh: String) {
        switch self {
        case .minimize:
            return ("Minimize overflow (default)", "最小化收纳(默认)")
        case .tolerateOverlap:
            return ("Tolerate light overlap", "允许轻度重叠(全部保留可见)")
        case .stackWithPeek:
            return ("Stack with peek edges", "堆叠 + 露边(错位叠放)")
        }
    }

    var detailText: (en: String, zh: String) {
        switch self {
        case .minimize:
            return (
                "When windows refuse to shrink and overlap, minimize the least-recently-used ones.",
                "窗口拒绝缩小并产生重叠时,把最久未用的几个最小化收纳。"
            )
        case .tolerateOverlap:
            return (
                "Keep every window on screen, even if some bleed into each other. Tune the tolerance below.",
                "每个窗口都留在屏幕上,允许它们轻微互相挤一下。用下面的容忍度调节。"
            )
        case .stackWithPeek:
            return (
                "Only kicks in when windows don't all fit tiled. Cascades them by size: big at the back, small on top, edges peek out.",
                "仅当窗口铺不下时触发。按大小错位叠放:大的在底层,小的在最上层,边缘露出便于点击切换。"
            )
        }
    }
}

// A picked layout describes both the geometry (what each window's normalized frame
// looks like inside a unit square) and how the picker should label it. Thumbnails
// in the Settings UI render directly from these normalized frames.

enum ThreeWindowLayout: String, CaseIterable {
    case primaryPlusTwo    // 1 big + 2 small stacked (default)
    case threeColumns      // 3 equal columns

    var displayLabel: (en: String, zh: String) {
        switch self {
        case .primaryPlusTwo: return ("1 big + 2 small", "1 大 + 2 小")
        case .threeColumns:   return ("3 equal columns", "3 列等宽")
        }
    }

    /// Frames in unit-square coordinates (0..1 in both axes, top-left origin).
    var thumbnailFrames: [CGRect] {
        switch self {
        case .primaryPlusTwo:
            return [
                CGRect(x: 0.00, y: 0.00, width: 0.50, height: 1.00),   // big left
                CGRect(x: 0.50, y: 0.00, width: 0.50, height: 0.50),   // top-right
                CGRect(x: 0.50, y: 0.50, width: 0.50, height: 0.50)    // bottom-right
            ]
        case .threeColumns:
            return [
                CGRect(x: 0.00, y: 0.00, width: 0.33, height: 1.00),
                CGRect(x: 0.34, y: 0.00, width: 0.33, height: 1.00),
                CGRect(x: 0.67, y: 0.00, width: 0.33, height: 1.00)
            ]
        }
    }
}

enum FourWindowLayout: String, CaseIterable {
    case grid2x2           // 2x2 (default)
    case primaryPlusThree  // 1 big + 3 stacked

    var displayLabel: (en: String, zh: String) {
        switch self {
        case .grid2x2:          return ("2×2 grid", "2×2 网格")
        case .primaryPlusThree: return ("1 big + 3 small", "1 大 + 3 小")
        }
    }

    var thumbnailFrames: [CGRect] {
        switch self {
        case .grid2x2:
            return [
                CGRect(x: 0.00, y: 0.00, width: 0.50, height: 0.50),
                CGRect(x: 0.50, y: 0.00, width: 0.50, height: 0.50),
                CGRect(x: 0.00, y: 0.50, width: 0.50, height: 0.50),
                CGRect(x: 0.50, y: 0.50, width: 0.50, height: 0.50)
            ]
        case .primaryPlusThree:
            return [
                CGRect(x: 0.00, y: 0.00, width: 0.50, height: 1.00),
                CGRect(x: 0.50, y: 0.00, width: 0.50, height: 0.33),
                CGRect(x: 0.50, y: 0.34, width: 0.50, height: 0.33),
                CGRect(x: 0.50, y: 0.67, width: 0.50, height: 0.33)
            ]
        }
    }
}

enum FiveWindowLayout: String, CaseIterable {
    case threeOverTwoEqual            // top 3 + bottom 2 with equal row heights (default)
    case leftTwoBigRightThreeSmall    // left half: 2 stacked big, right half: 3 stacked small
    case bottomTwoBigTopThreeSmall    // top row 3 small (40% height), bottom row 2 big (60% height)

    var displayLabel: (en: String, zh: String) {
        switch self {
        case .threeOverTwoEqual:           return ("3 over 2 (balanced)", "3+2 排(均等)")
        case .leftTwoBigRightThreeSmall:   return ("Left 2 big + right 3 small", "左 2 大 + 右 3 小")
        case .bottomTwoBigTopThreeSmall:   return ("Bottom 2 big + top 3 small", "下 2 大 + 上 3 小")
        }
    }

    var thumbnailFrames: [CGRect] {
        switch self {
        case .threeOverTwoEqual:
            return [
                CGRect(x: 0.00, y: 0.00, width: 0.33, height: 0.50),
                CGRect(x: 0.34, y: 0.00, width: 0.33, height: 0.50),
                CGRect(x: 0.67, y: 0.00, width: 0.33, height: 0.50),
                CGRect(x: 0.00, y: 0.50, width: 0.50, height: 0.50),
                CGRect(x: 0.50, y: 0.50, width: 0.50, height: 0.50)
            ]
        case .leftTwoBigRightThreeSmall:
            return [
                CGRect(x: 0.00, y: 0.00, width: 0.50, height: 0.50),
                CGRect(x: 0.00, y: 0.50, width: 0.50, height: 0.50),
                CGRect(x: 0.50, y: 0.00, width: 0.50, height: 0.33),
                CGRect(x: 0.50, y: 0.34, width: 0.50, height: 0.33),
                CGRect(x: 0.50, y: 0.67, width: 0.50, height: 0.33)
            ]
        case .bottomTwoBigTopThreeSmall:
            return [
                CGRect(x: 0.00, y: 0.00, width: 0.33, height: 0.40),
                CGRect(x: 0.34, y: 0.00, width: 0.33, height: 0.40),
                CGRect(x: 0.67, y: 0.00, width: 0.33, height: 0.40),
                CGRect(x: 0.00, y: 0.40, width: 0.50, height: 0.60),
                CGRect(x: 0.50, y: 0.40, width: 0.50, height: 0.60)
            ]
        }
    }
}

struct SmartFitCapacityProfile: Equatable {
    var compact: Int   // ≤15"
    var laptop: Int    // 16"-20" (covers 16-17" laptops + the 18-20 gap)
    var desktop: Int   // 21"-24"
    var large: Int     // 25"-29" (~27")
    var huge: Int      // >29" (32"+ / ultrawide)

    static let `default` = SmartFitCapacityProfile(compact: 5, laptop: 6, desktop: 6, large: 9, huge: 9)
}

enum AppLanguage: String, CaseIterable {
    case english = "en"
    case simplifiedChinese = "zh-Hans"

    var displayName: String {
        switch self {
        case .english:
            return "English"
        case .simplifiedChinese:
            return "中文"
        }
    }

    static var systemDefault: AppLanguage {
        Locale.preferredLanguages.first?.hasPrefix("zh") == true ? .simplifiedChinese : .english
    }
}

final class AppConfiguration {
    static let shared = AppConfiguration()

    private let defaults: UserDefaults
    private let languageKey = "Language"
    private let missionControlModeKey = "EnableMissionControlMode"
    private let swipeUpToCloseKey = "EnableSwipeUpToClose"
    private let swipeDownToMinimizeKey = "EnableSwipeDownToMinimize"
    private let blankAreaSwipeUpToArrangeKey = "EnableBlankAreaSwipeUpToArrange"
    private let previewLayoutGesturesKey = "EnablePreviewLayoutGestures"
    private let smartFitArrangeKey = "EnableSmartFitArrange"
    private let largeScreenWindowCapacityKey = "LargeScreenWindowCapacity"
    private let smartFitCapacityCompactKey = "SmartFitCapacityCompact"
    private let smartFitCapacityLaptopKey = "SmartFitCapacityLaptop"
    private let smartFitCapacityDesktopKey = "SmartFitCapacityDesktop"
    private let smartFitCapacityLargeKey = "SmartFitCapacityLarge"
    private let smartFitCapacityHugeKey = "SmartFitCapacityHuge"
    private let smartFitOverflowStrategyKey = "SmartFitOverflowStrategy"
    private let smartFitOverlapToleranceKey = "SmartFitOverlapTolerance"
    private let threeWindowLayoutKey = "SmartFitThreeWindowLayout"
    private let fourWindowLayoutKey = "SmartFitFourWindowLayout"
    private let fiveWindowLayoutKey = "SmartFitFiveWindowLayout"
    private let recentLogLineCountKey = "DiagnosticsRecentLogLineCount"
    private let secondMissionControlSwipeUpToArrangeKey = "EnableSecondMissionControlSwipeUpToArrange"
    private let missionControlGestureProbeKey = "EnableMissionControlGestureProbe"
    private let inputEventProbeKey = "EnableInputEventProbe"
    private let debugLoggingKey = "EnableDebugLogging"
    private let hideStatusBarIconKey = "HideStatusBarIcon"
    private let secondMissionControlSwipeUpToArrangeFeatureEnabled = false

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var language: AppLanguage {
        get {
            guard let rawValue = defaults.string(forKey: languageKey),
                  let language = AppLanguage(rawValue: rawValue) else {
                return .systemDefault
            }
            return language
        }
        set {
            defaults.set(newValue.rawValue, forKey: languageKey)
            Logger.info("Language set to \(newValue.rawValue)")
        }
    }

    var enableMissionControlMode: Bool {
        get {
            if defaults.object(forKey: missionControlModeKey) == nil {
                return true
            }
            return defaults.bool(forKey: missionControlModeKey)
        }
        set {
            defaults.set(newValue, forKey: missionControlModeKey)
            Logger.info("EnableMissionControlMode set to \(newValue)")
        }
    }

    var enableSwipeUpToClose: Bool {
        get {
            if defaults.object(forKey: swipeUpToCloseKey) == nil {
                return true
            }
            return defaults.bool(forKey: swipeUpToCloseKey)
        }
        set {
            defaults.set(newValue, forKey: swipeUpToCloseKey)
            Logger.info("EnableSwipeUpToClose set to \(newValue)")
        }
    }

    var enableSwipeDownToMinimize: Bool {
        get {
            if defaults.object(forKey: swipeDownToMinimizeKey) == nil {
                return true
            }
            return defaults.bool(forKey: swipeDownToMinimizeKey)
        }
        set {
            defaults.set(newValue, forKey: swipeDownToMinimizeKey)
            Logger.info("EnableSwipeDownToMinimize set to \(newValue)")
        }
    }

    var enableBlankAreaSwipeUpToArrange: Bool {
        get {
            if defaults.object(forKey: blankAreaSwipeUpToArrangeKey) == nil {
                return true
            }
            return defaults.bool(forKey: blankAreaSwipeUpToArrangeKey)
        }
        set {
            defaults.set(newValue, forKey: blankAreaSwipeUpToArrangeKey)
            Logger.info("EnableBlankAreaSwipeUpToArrange set to \(newValue)")
        }
    }

    var enablePreviewLayoutGestures: Bool {
        get {
            if defaults.object(forKey: previewLayoutGesturesKey) == nil {
                return false
            }
            return defaults.bool(forKey: previewLayoutGesturesKey)
        }
        set {
            defaults.set(newValue, forKey: previewLayoutGesturesKey)
            Logger.info("EnablePreviewLayoutGestures set to \(newValue)")
        }
    }

    var enableSmartFitArrange: Bool {
        get {
            if defaults.object(forKey: smartFitArrangeKey) == nil {
                return true
            }
            return defaults.bool(forKey: smartFitArrangeKey)
        }
        set {
            defaults.set(newValue, forKey: smartFitArrangeKey)
            Logger.info("EnableSmartFitArrange set to \(newValue)")
        }
    }

    var smartFitCapacityProfile: SmartFitCapacityProfile {
        get {
            let defaultProfile = SmartFitCapacityProfile.default
            // Migrate the legacy LargeScreenWindowCapacity key into the new huge slot,
            // so anyone who tweaked the old field doesn't lose their preference.
            let legacyHuge: Int? = (defaults.object(forKey: largeScreenWindowCapacityKey) as? NSNumber).map { $0.intValue }

            let compact = readCapacity(forKey: smartFitCapacityCompactKey, default: defaultProfile.compact)
            let laptop = readCapacity(forKey: smartFitCapacityLaptopKey, default: defaultProfile.laptop)
            let desktop = readCapacity(forKey: smartFitCapacityDesktopKey, default: defaultProfile.desktop)
            let large = readCapacity(forKey: smartFitCapacityLargeKey, default: defaultProfile.large)
            let huge = readCapacity(
                forKey: smartFitCapacityHugeKey,
                default: legacyHuge.map { min(max($0, 1), 30) } ?? defaultProfile.huge
            )

            return SmartFitCapacityProfile(
                compact: compact,
                laptop: laptop,
                desktop: desktop,
                large: large,
                huge: huge
            )
        }
        set {
            writeCapacity(newValue.compact, forKey: smartFitCapacityCompactKey)
            writeCapacity(newValue.laptop, forKey: smartFitCapacityLaptopKey)
            writeCapacity(newValue.desktop, forKey: smartFitCapacityDesktopKey)
            writeCapacity(newValue.large, forKey: smartFitCapacityLargeKey)
            writeCapacity(newValue.huge, forKey: smartFitCapacityHugeKey)
            Logger.info("SmartFitCapacityProfile set: compact=\(newValue.compact), laptop=\(newValue.laptop), desktop=\(newValue.desktop), large=\(newValue.large), huge=\(newValue.huge)")
        }
    }

    var smartFitOverflowStrategy: SmartFitOverflowStrategy {
        get {
            guard let raw = defaults.string(forKey: smartFitOverflowStrategyKey),
                  let strategy = SmartFitOverflowStrategy(rawValue: raw) else {
                return .minimize
            }
            return strategy
        }
        set {
            defaults.set(newValue.rawValue, forKey: smartFitOverflowStrategyKey)
            Logger.info("SmartFitOverflowStrategy set to \(newValue.rawValue)")
        }
    }

    var threeWindowLayout: ThreeWindowLayout {
        get {
            guard let raw = defaults.string(forKey: threeWindowLayoutKey),
                  let value = ThreeWindowLayout(rawValue: raw) else {
                return .primaryPlusTwo
            }
            return value
        }
        set {
            defaults.set(newValue.rawValue, forKey: threeWindowLayoutKey)
            Logger.info("ThreeWindowLayout set to \(newValue.rawValue)")
        }
    }

    var fourWindowLayout: FourWindowLayout {
        get {
            guard let raw = defaults.string(forKey: fourWindowLayoutKey),
                  let value = FourWindowLayout(rawValue: raw) else {
                return .grid2x2
            }
            return value
        }
        set {
            defaults.set(newValue.rawValue, forKey: fourWindowLayoutKey)
            Logger.info("FourWindowLayout set to \(newValue.rawValue)")
        }
    }

    var recentLogLineCount: LogCopyLineCount {
        get {
            if defaults.object(forKey: recentLogLineCountKey) == nil {
                return .fifty
            }
            let raw = defaults.integer(forKey: recentLogLineCountKey)
            return LogCopyLineCount(rawValue: raw) ?? .fifty
        }
        set {
            defaults.set(newValue.rawValue, forKey: recentLogLineCountKey)
            Logger.info("DiagnosticsRecentLogLineCount set to \(newValue.rawValue)")
        }
    }

    var fiveWindowLayout: FiveWindowLayout {
        get {
            guard let raw = defaults.string(forKey: fiveWindowLayoutKey),
                  let value = FiveWindowLayout(rawValue: raw) else {
                return .threeOverTwoEqual
            }
            return value
        }
        set {
            defaults.set(newValue.rawValue, forKey: fiveWindowLayoutKey)
            Logger.info("FiveWindowLayout set to \(newValue.rawValue)")
        }
    }

    var smartFitOverlapTolerance: Double {
        get {
            if defaults.object(forKey: smartFitOverlapToleranceKey) == nil {
                return 0.06
            }
            let value = defaults.double(forKey: smartFitOverlapToleranceKey)
            return min(max(value, 0.06), 0.50)
        }
        set {
            let clamped = min(max(newValue, 0.06), 0.50)
            defaults.set(clamped, forKey: smartFitOverlapToleranceKey)
            Logger.info("SmartFitOverlapTolerance set to \(clamped)")
        }
    }

    private func readCapacity(forKey key: String, default fallback: Int) -> Int {
        guard defaults.object(forKey: key) != nil else {
            return fallback
        }
        let value = defaults.integer(forKey: key)
        return min(max(value, 1), 30)
    }

    private func writeCapacity(_ value: Int, forKey key: String) {
        let clamped = min(max(value, 1), 30)
        defaults.set(clamped, forKey: key)
    }

    var enableSecondMissionControlSwipeUpToArrange: Bool {
        get {
            guard secondMissionControlSwipeUpToArrangeFeatureEnabled else {
                return false
            }
            if defaults.object(forKey: secondMissionControlSwipeUpToArrangeKey) == nil {
                return false
            }
            return defaults.bool(forKey: secondMissionControlSwipeUpToArrangeKey)
        }
        set {
            guard secondMissionControlSwipeUpToArrangeFeatureEnabled else {
                defaults.set(false, forKey: secondMissionControlSwipeUpToArrangeKey)
                Logger.info("EnableSecondMissionControlSwipeUpToArrange ignored because the feature is hidden")
                return
            }
            defaults.set(newValue, forKey: secondMissionControlSwipeUpToArrangeKey)
            Logger.info("EnableSecondMissionControlSwipeUpToArrange set to \(newValue)")
        }
    }

    var enableMissionControlGestureProbe: Bool {
        get {
            defaults.bool(forKey: missionControlGestureProbeKey)
        }
        set {
            defaults.set(newValue, forKey: missionControlGestureProbeKey)
            Logger.info("EnableMissionControlGestureProbe set to \(newValue)")
        }
    }

    var enableInputEventProbe: Bool {
        get {
            defaults.bool(forKey: inputEventProbeKey)
        }
        set {
            defaults.set(newValue, forKey: inputEventProbeKey)
            Logger.info("EnableInputEventProbe set to \(newValue)")
        }
    }

    var enableDebugLogging: Bool {
        get {
            if defaults.object(forKey: debugLoggingKey) == nil {
                return Self.debugLoggingDefault
            }
            return defaults.bool(forKey: debugLoggingKey)
        }
        set {
            defaults.set(newValue, forKey: debugLoggingKey)
            Logger.info("EnableDebugLogging set to \(newValue)")
        }
    }

    static var debugLoggingDefault: Bool {
        #if MISSION_SWIPE_DEV_BUILD
        return true
        #else
        return false
        #endif
    }

    static var isDevBuild: Bool {
        #if MISSION_SWIPE_DEV_BUILD
        return true
        #else
        return false
        #endif
    }

    var hideStatusBarIcon: Bool {
        get {
            defaults.bool(forKey: hideStatusBarIconKey)
        }
        set {
            defaults.set(newValue, forKey: hideStatusBarIconKey)
            Logger.info("HideStatusBarIcon set to \(newValue)")
        }
    }
}
