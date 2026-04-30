import Foundation

final class AppConfiguration {
    static let shared = AppConfiguration()

    private let defaults: UserDefaults
    private let missionControlModeKey = "EnableMissionControlMode"
    private let swipeUpToCloseKey = "EnableSwipeUpToClose"
    private let swipeDownToMinimizeKey = "EnableSwipeDownToMinimize"
    private let debugLoggingKey = "EnableDebugLogging"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
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
                return false
            }
            return defaults.bool(forKey: swipeDownToMinimizeKey)
        }
        set {
            defaults.set(newValue, forKey: swipeDownToMinimizeKey)
            Logger.info("EnableSwipeDownToMinimize set to \(newValue)")
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
}
