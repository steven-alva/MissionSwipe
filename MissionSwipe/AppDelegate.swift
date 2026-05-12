import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let permissionManager = AccessibilityPermissionManager()
    private let hotkeyManager = GlobalHotkeyManager()
    private let windowCloser = WindowCloser()
    private let windowArranger = WindowArranger()
    private let debugWindowDumper = DebugWindowDumper()
    private let trackpadGestureDetector = TrackpadGestureDetector()
    private let missionControlGestureProbe = MissionControlGestureProbe()
    private let secondMissionControlSwipeMonitor = MissionControlJitterProbe()
    private let inputEventProbe = InputEventProbe()
    private let configuration = AppConfiguration.shared
    private var statusBarController: StatusBarController?
    private var isArrangingFromSecondMissionControlSwipe = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        Logger.info("MissionSwipe launching")
        NSApp.setActivationPolicy(.accessory)

        if configuration.hideStatusBarIcon {
            Logger.info("Menu bar icon is hidden by user preference")
        } else {
            let statusBarController = StatusBarController()
            self.statusBarController = statusBarController
            configureStatusBarController(statusBarController)
        }

        guard refreshPermissionStatus(showPromptWhenMissing: true) else {
            return
        }
        statusBarController?.updateMissionControlMode(isEnabled: configuration.enableMissionControlMode)
        statusBarController?.updateSwipeUpToClose(isEnabled: configuration.enableSwipeUpToClose)
        statusBarController?.updateSwipeDownToMinimize(isEnabled: configuration.enableSwipeDownToMinimize)
        statusBarController?.updateBlankAreaSwipeUpToArrange(isEnabled: configuration.enableBlankAreaSwipeUpToArrange)
        statusBarController?.updateSecondMissionControlSwipeUpToArrange(isEnabled: configuration.enableSecondMissionControlSwipeUpToArrange)
        statusBarController?.updateMissionControlGestureProbe(isEnabled: configuration.enableMissionControlGestureProbe)
        statusBarController?.updateInputEventProbe(isEnabled: configuration.enableInputEventProbe)
        statusBarController?.updateDebugLogging(isEnabled: configuration.enableDebugLogging)
        registerHotkey()
        startTrackpadGestureDetector()
        configureSecondMissionControlSwipeMonitor()
        updateMissionControlGestureProbeEnabledState()
        updateSecondMissionControlSwipeMonitorEnabledState()
        updateInputEventProbeEnabledState()
    }

    func applicationWillTerminate(_ notification: Notification) {
        Logger.info("MissionSwipe terminating")
        hotkeyManager.unregister()
        trackpadGestureDetector.stop()
        missionControlGestureProbe.stop()
        secondMissionControlSwipeMonitor.stop()
        inputEventProbe.stop()
    }

    private func configureStatusBarController(_ statusBarController: StatusBarController) {
        statusBarController.onCloseWindow = { [weak self] in
            self?.closeMissionControlWindowUnderMouse(trigger: "menu item")
        }
        statusBarController.onToggleMissionControlMode = { [weak self] isEnabled in
            self?.configuration.enableMissionControlMode = isEnabled
            self?.statusBarController?.updateMissionControlMode(isEnabled: isEnabled)
        }
        statusBarController.onToggleSwipeUpToClose = { [weak self] isEnabled in
            self?.configuration.enableSwipeUpToClose = isEnabled
            self?.updateTrackpadGestureDetectorEnabledState()
            self?.statusBarController?.updateSwipeUpToClose(isEnabled: isEnabled)
        }
        statusBarController.onToggleSwipeDownToMinimize = { [weak self] isEnabled in
            self?.configuration.enableSwipeDownToMinimize = isEnabled
            self?.updateTrackpadGestureDetectorEnabledState()
            self?.statusBarController?.updateSwipeDownToMinimize(isEnabled: isEnabled)
        }
        statusBarController.onToggleBlankAreaSwipeUpToArrange = { [weak self] isEnabled in
            self?.configuration.enableBlankAreaSwipeUpToArrange = isEnabled
            self?.updateTrackpadGestureDetectorEnabledState()
            self?.statusBarController?.updateBlankAreaSwipeUpToArrange(isEnabled: isEnabled)
        }
        statusBarController.onToggleSecondMissionControlSwipeUpToArrange = { [weak self] isEnabled in
            self?.configuration.enableSecondMissionControlSwipeUpToArrange = isEnabled
            self?.statusBarController?.updateSecondMissionControlSwipeUpToArrange(isEnabled: isEnabled)
            self?.updateSecondMissionControlSwipeMonitorEnabledState()
        }
        statusBarController.onToggleMissionControlGestureProbe = { [weak self] isEnabled in
            self?.configuration.enableMissionControlGestureProbe = isEnabled
            self?.statusBarController?.updateMissionControlGestureProbe(isEnabled: isEnabled)
            self?.updateMissionControlGestureProbeEnabledState()
        }
        statusBarController.onToggleInputEventProbe = { [weak self] isEnabled in
            self?.configuration.enableInputEventProbe = isEnabled
            self?.statusBarController?.updateInputEventProbe(isEnabled: isEnabled)
            self?.updateInputEventProbeEnabledState()
        }
        statusBarController.onArrangeVisibleWindows = { [weak self] in
            self?.arrangeVisibleWindows(trigger: "menu item")
        }
        statusBarController.onUndoLastArrange = { [weak self] in
            self?.windowArranger.undoLastArrange()
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
        statusBarController.onHideMenuBarIcon = { [weak self] in
            self?.hideMenuBarIcon()
        }
        statusBarController.onQuit = {
            NSApp.terminate(nil)
        }
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
        updateTrackpadGestureDetectorEnabledState()
        trackpadGestureDetector.shouldBeginTracking = { [weak self] in
            guard let self else {
                return false
            }

            guard self.configuration.enableSwipeUpToClose ||
                    self.configuration.enableSwipeDownToMinimize ||
                    self.configuration.enableBlankAreaSwipeUpToArrange else {
                Logger.info("Swipe gestures are disabled; refusing to arm gesture")
                return false
            }

            guard self.configuration.enableMissionControlMode else {
                Logger.info("Mission Control mode is disabled; refusing to arm swipe gesture")
                return false
            }

            return self.windowCloser.prepareMissionControlSwipeAction()
        }
        trackpadGestureDetector.onSwipeUpDetected = { [weak self] in
            DispatchQueue.main.async {
                self?.closeMissionControlWindowUnderMouseFromSwipe()
            }
        }
        trackpadGestureDetector.onSwipeDownDetected = { [weak self] in
            DispatchQueue.main.async {
                self?.minimizeMissionControlWindowUnderMouseFromSwipe()
            }
        }
        trackpadGestureDetector.start()
    }

    private func configureSecondMissionControlSwipeMonitor() {
        secondMissionControlSwipeMonitor.onSecondMissionControlSwipeInferred = { [weak self] in
            DispatchQueue.main.async {
                self?.arrangeFromSecondMissionControlSwipe()
            }
        }
    }

    private func updateTrackpadGestureDetectorEnabledState() {
        trackpadGestureDetector.detectsSwipeUp = configuration.enableSwipeUpToClose || configuration.enableBlankAreaSwipeUpToArrange
        trackpadGestureDetector.detectsSwipeDown = configuration.enableSwipeDownToMinimize
        trackpadGestureDetector.isEnabled = configuration.enableSwipeUpToClose ||
            configuration.enableSwipeDownToMinimize ||
            configuration.enableBlankAreaSwipeUpToArrange
    }

    private func updateMissionControlGestureProbeEnabledState() {
        if configuration.enableMissionControlGestureProbe {
            missionControlGestureProbe.start()
        } else {
            missionControlGestureProbe.stop()
        }
    }

    private func updateSecondMissionControlSwipeMonitorEnabledState() {
        if configuration.enableSecondMissionControlSwipeUpToArrange {
            secondMissionControlSwipeMonitor.start()
        } else {
            secondMissionControlSwipeMonitor.stop()
        }
    }

    private func updateInputEventProbeEnabledState() {
        if configuration.enableInputEventProbe {
            inputEventProbe.start()
        } else {
            inputEventProbe.stop()
        }
    }

    private func closeMissionControlWindowUnderMouseFromSwipe() {
        guard configuration.enableSwipeUpToClose || configuration.enableBlankAreaSwipeUpToArrange else {
            Logger.info("Swipe-up actions are disabled; ignoring detected gesture")
            return
        }

        guard configuration.enableMissionControlMode else {
            Logger.info("Mission Control mode is disabled; ignoring swipe-up close")
            return
        }

        Logger.info("Close requested by trackpad swipe-up")
        if configuration.enableBlankAreaSwipeUpToArrange {
            switch windowCloser.classifyMissionControlSwipeLocation(usePreparedSwipeDetection: true) {
            case .blankArea:
                Logger.info("Swipe-up landed on Mission Control blank area; arranging visible windows")
                windowCloser.clearPreparedSwipeAction()
                secondMissionControlSwipeMonitor.suppressCurrentMissionControlSession(reason: "blank-area swipe-up arrange")
                windowArranger.arrangeAfterExitingMissionControl(
                    trigger: "blank-area swipe-up",
                    preferCurrentMouseExitPoint: true
                )
                refreshPermissionStatus(showPromptWhenMissing: false)
                return
            case .windowTarget:
                break
            case .missionControlInactive, .permissionMissing:
                refreshPermissionStatus(showPromptWhenMissing: false)
                return
            }
        }

        guard configuration.enableSwipeUpToClose else {
            Logger.info("Swipe-up close is disabled and blank-area arrange did not apply")
            refreshPermissionStatus(showPromptWhenMissing: false)
            return
        }

        let result = windowCloser.closeMissionControlWindowUnderMouseIfActive(usePreparedSwipeDetection: true)
        if result == .performed {
            secondMissionControlSwipeMonitor.suppressCurrentMissionControlSession(reason: "Mission Control window close")
        }
        if (result == .noTargetInMissionControl || result == .rejectedInMissionControl),
           configuration.enableBlankAreaSwipeUpToArrange {
            Logger.info("Swipe-up close found no safe target; treating it as Mission Control blank area")
            secondMissionControlSwipeMonitor.suppressCurrentMissionControlSession(reason: "blank-area fallback arrange")
            windowArranger.arrangeAfterExitingMissionControl(
                trigger: "blank-area swipe-up",
                preferCurrentMouseExitPoint: true
            )
        }
        refreshPermissionStatus(showPromptWhenMissing: false)
    }

    private func minimizeMissionControlWindowUnderMouseFromSwipe() {
        guard configuration.enableSwipeDownToMinimize else {
            Logger.info("Swipe-down minimize is disabled; ignoring detected gesture")
            return
        }

        guard configuration.enableMissionControlMode else {
            Logger.info("Mission Control mode is disabled; ignoring swipe-down minimize")
            return
        }

        Logger.info("Minimize requested by trackpad swipe-down")
        let result = windowCloser.minimizeMissionControlWindowUnderMouseIfActive(usePreparedSwipeDetection: true)
        if result == .performed {
            secondMissionControlSwipeMonitor.suppressCurrentMissionControlSession(reason: "Mission Control window minimize")
        }
        refreshPermissionStatus(showPromptWhenMissing: false)
    }

    private func arrangeFromSecondMissionControlSwipe() {
        guard configuration.enableSecondMissionControlSwipeUpToArrange else {
            Logger.info("Second Mission Control swipe arrange is disabled; ignoring inferred gesture")
            return
        }

        guard configuration.enableMissionControlMode else {
            Logger.info("Mission Control mode is disabled; ignoring second Mission Control swipe arrange")
            return
        }

        guard !isArrangingFromSecondMissionControlSwipe else {
            Logger.info("Second Mission Control swipe arrange is already in progress; ignoring duplicate")
            return
        }

        isArrangingFromSecondMissionControlSwipe = true
        Logger.info("Auto arrange requested from second Mission Control swipe; exiting Mission Control before arranging")
        windowArranger.arrangeAfterExitingMissionControl(trigger: "second Mission Control swipe-up")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
            self?.isArrangingFromSecondMissionControlSwipe = false
        }
        refreshPermissionStatus(showPromptWhenMissing: false)
    }

    private func arrangeVisibleWindows(trigger: String) {
        windowArranger.arrangeVisibleWindows(trigger: trigger)
        refreshPermissionStatus(showPromptWhenMissing: false)
    }

    private func copyLastCloseReport() {
        guard let report = windowCloser.lastActionReport else {
            Logger.info("No Mission Control action report is available yet")
            return
        }

        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(report, forType: .string)
        Logger.info("Copied last Mission Control action report to clipboard")
    }

    private func hideMenuBarIcon() {
        NSApp.activate(ignoringOtherApps: true)

        let alert = NSAlert()
        alert.messageText = "Hide MissionSwipe menu bar icon?"
        alert.informativeText = """
        MissionSwipe will keep running in the background. To show the icon again later, run:

        defaults write io.github.stevenalva.MissionSwipe HideStatusBarIcon -bool false; open -a MissionSwipe
        """
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Hide Icon")
        alert.addButton(withTitle: "Cancel")

        guard alert.runModal() == .alertFirstButtonReturn else {
            return
        }

        configuration.hideStatusBarIcon = true
        statusBarController?.removeStatusItem()
        statusBarController = nil
        Logger.info("MissionSwipe menu bar icon hidden by user")
    }

    @discardableResult
    private func refreshPermissionStatus(showPromptWhenMissing: Bool) -> Bool {
        let isTrusted = permissionManager.isAccessibilityTrusted
        Logger.info("Accessibility trusted: \(isTrusted)")
        statusBarController?.updateAccessibilityStatus(isTrusted: isTrusted)

        if !isTrusted && showPromptWhenMissing {
            permissionManager.logPermissionDiagnostics(reason: "Permission missing on launch")
            if permissionManager.requestSystemAccessibilityPromptIfNeeded() {
                permissionManager.showRestartRequiredAlertThenQuit()
                return false
            }
        }

        return true
    }
}
