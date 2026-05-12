import Foundation

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
            defaults.bool(forKey: debugLoggingKey)
        }
        set {
            defaults.set(newValue, forKey: debugLoggingKey)
            Logger.info("EnableDebugLogging set to \(newValue)")
        }
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
