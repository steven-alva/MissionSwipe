import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let permissionManager = AccessibilityPermissionManager()
    private let hotkeyManager = GlobalHotkeyManager()
    private let windowCloser = WindowCloser()
    private let debugWindowDumper = DebugWindowDumper()
    private let trackpadGestureDetector = TrackpadGestureDetector()
    private let configuration = AppConfiguration.shared
    private var statusBarController: StatusBarController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        Logger.info("MissionSwipe launching")

        let statusBarController = StatusBarController()
        self.statusBarController = statusBarController

        statusBarController.onCloseWindow = { [weak self] in
            self?.closeMissionControlWindowUnderMouse(trigger: "menu item")
        }
        statusBarController.onToggleMissionControlMode = { [weak self] isEnabled in
            self?.configuration.enableMissionControlMode = isEnabled
            self?.statusBarController?.updateMissionControlMode(isEnabled: isEnabled)
        }
        statusBarController.onToggleSwipeUpToClose = { [weak self] isEnabled in
            self?.configuration.enableSwipeUpToClose = isEnabled
            self?.trackpadGestureDetector.isEnabled = isEnabled
            self?.statusBarController?.updateSwipeUpToClose(isEnabled: isEnabled)
        }
        statusBarController.onToggleDebugLogging = { [weak self] isEnabled in
            self?.configuration.enableDebugLogging = isEnabled
            self?.statusBarController?.updateDebugLogging(isEnabled: isEnabled)
        }
        statusBarController.onCopyLastCloseReport = { [weak self] in
            self?.copyLastCloseReport()
        }
        statusBarController.onDumpWindowList = { [weak self] in
            self?.debugWindowDumper.dumpWindowList()
        }
        statusBarController.onDumpAXWindows = { [weak self] in
            self?.debugWindowDumper.dumpAXWindows()
        }
        statusBarController.onOpenAccessibilitySettings = {
            AccessibilityPermissionManager.openAccessibilitySettings()
        }
        statusBarController.onRefreshPermission = { [weak self] in
            self?.refreshPermissionStatus(showPromptWhenMissing: false)
        }
        statusBarController.onQuit = {
            NSApp.terminate(nil)
        }

        refreshPermissionStatus(showPromptWhenMissing: true)
        statusBarController.updateMissionControlMode(isEnabled: configuration.enableMissionControlMode)
        statusBarController.updateSwipeUpToClose(isEnabled: configuration.enableSwipeUpToClose)
        statusBarController.updateDebugLogging(isEnabled: configuration.enableDebugLogging)
        registerHotkey()
        startTrackpadGestureDetector()
    }

    func applicationWillTerminate(_ notification: Notification) {
        Logger.info("MissionSwipe terminating")
        hotkeyManager.unregister()
        trackpadGestureDetector.stop()
    }

    private func registerHotkey() {
        hotkeyManager.register(controlOptionWHandler: { [weak self] in
            DispatchQueue.main.async {
                self?.closeMissionControlWindowUnderMouse(trigger: "Control+Option+W")
            }
        })
    }

    private func closeMissionControlWindowUnderMouse(trigger: String) {
        Logger.info("Mission Control close requested by \(trigger)")

        guard configuration.enableMissionControlMode else {
            Logger.info("Mission Control close is disabled; ignoring \(trigger)")
            refreshPermissionStatus(showPromptWhenMissing: false)
            return
        }

        windowCloser.closeMissionControlWindowUnderMouseIfActive()
        refreshPermissionStatus(showPromptWhenMissing: false)
    }

    private func startTrackpadGestureDetector() {
        trackpadGestureDetector.isEnabled = configuration.enableSwipeUpToClose
        trackpadGestureDetector.shouldBeginTracking = { [weak self] in
            guard let self else {
                return false
            }

            guard self.configuration.enableSwipeUpToClose else {
                Logger.info("Swipe-up close is disabled; refusing to arm gesture")
                return false
            }

            guard self.configuration.enableMissionControlMode else {
                Logger.info("Mission Control mode is disabled; refusing to arm swipe-up gesture")
                return false
            }

            return self.windowCloser.prepareMissionControlSwipeClose()
        }
        trackpadGestureDetector.onSwipeUpDetected = { [weak self] in
            DispatchQueue.main.async {
                self?.closeMissionControlWindowUnderMouseFromSwipe()
            }
        }
        trackpadGestureDetector.start()
    }

    private func closeMissionControlWindowUnderMouseFromSwipe() {
        guard configuration.enableSwipeUpToClose else {
            Logger.info("Swipe-up close is disabled; ignoring detected gesture")
            return
        }

        guard configuration.enableMissionControlMode else {
            Logger.info("Mission Control mode is disabled; ignoring swipe-up close")
            return
        }

        Logger.info("Close requested by trackpad swipe-up")
        windowCloser.closeMissionControlWindowUnderMouseIfActive(usePreparedSwipeDetection: true)
        refreshPermissionStatus(showPromptWhenMissing: false)
    }

    private func copyLastCloseReport() {
        guard let report = windowCloser.lastCloseReport else {
            Logger.info("No Mission Control close report is available yet")
            return
        }

        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(report, forType: .string)
        Logger.info("Copied last Mission Control close report to clipboard")
    }

    private func refreshPermissionStatus(showPromptWhenMissing: Bool) {
        let isTrusted = permissionManager.isAccessibilityTrusted
        Logger.info("Accessibility trusted: \(isTrusted)")
        statusBarController?.updateAccessibilityStatus(isTrusted: isTrusted)

        if !isTrusted && showPromptWhenMissing {
            permissionManager.logPermissionDiagnostics(reason: "Permission missing on launch")
            permissionManager.requestSystemAccessibilityPrompt()
        }
    }
}
