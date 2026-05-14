import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private enum Constants {
        static let closeSwipeUpThresholdY: CGFloat = 210
        static let minimizeSwipeDownThresholdY: CGFloat = 150
        static let arrangeSwipeUpThresholdY: CGFloat = 120
        static let primaryArrangeSwipeThresholdX: CGFloat = 190
        static let previewLayoutSwipeThreshold: CGFloat = 180
        static let previewLayoutGestureCandidateLifetime: TimeInterval = 1.2
        static let previewLayoutHUDUpdateInterval: TimeInterval = 1.0 / 30.0
        static let previewLayoutExitPollDelay: TimeInterval = 0.12
        static let previewLayoutExitSettleDelay: TimeInterval = 0.20
    }

    private struct PreviewLayoutGestureCandidate {
        let placement: WindowArranger.PrimaryPlacement
        let primaryWindow: AXWindowSnapshot
        let windowCount: Int
        let createdAt: Date
    }

    private let permissionManager = AccessibilityPermissionManager()
    private let windowCloser = WindowCloser()
    private let windowArranger = WindowArranger()
    private let windowEnumerator = WindowEnumerator()
    private let missionControlDetector = MissionControlDetector()
    private let debugWindowDumper = DebugWindowDumper()
    private let trackpadGestureDetector = TrackpadGestureDetector()
    private let gestureHUD = GestureHUDController()
    private let layoutPreviewHUD = LayoutPreviewHUDController()
    private let missionControlGestureProbe = MissionControlGestureProbe()
    private let secondMissionControlSwipeMonitor = MissionControlJitterProbe()
    private let inputEventProbe = InputEventProbe()
    private let configuration = AppConfiguration.shared
    private var statusBarController: StatusBarController?
    private var settingsWindowController: SettingsWindowController?
    private var smartFitCapacityWindowController: SmartFitCapacityWindowController?
    private var smartFitAdvancedWindowController: SmartFitAdvancedWindowController?
    private var isArrangingFromSecondMissionControlSwipe = false
    private var pendingLayoutPreviewWorkItem: DispatchWorkItem?
    private var previewLayoutGestureCandidate: PreviewLayoutGestureCandidate?
    private var lastPreviewLayoutHUDUpdateAt: Date?

    func applicationDidFinishLaunching(_ notification: Notification) {
        Logger.info("MissionSwipe launching (devBuild=\(AppConfiguration.isDevBuild), debugLogging=\(configuration.enableDebugLogging))")
        NSApp.setActivationPolicy(.accessory)

        windowArranger.isSmartFitEnabled = configuration.enableSmartFitArrange
        windowArranger.smartFitCapacityProfile = configuration.smartFitCapacityProfile
        windowArranger.smartFitOverflowStrategy = configuration.smartFitOverflowStrategy
        windowArranger.smartFitOverlapTolerance = configuration.smartFitOverlapTolerance
        windowArranger.threeWindowLayout = configuration.threeWindowLayout
        windowArranger.fourWindowLayout = configuration.fourWindowLayout
        windowArranger.fiveWindowLayout = configuration.fiveWindowLayout
        windowArranger.onSmartFitReport = { [weak self] report in
            self?.handleSmartFitReport(report)
        }

        if configuration.hideStatusBarIcon {
            Logger.info("Menu bar icon is hidden by user preference")
        } else {
            let statusBarController = StatusBarController(language: configuration.language)
            self.statusBarController = statusBarController
            configureStatusBarController(statusBarController)
        }

        guard refreshPermissionStatus(showPromptWhenMissing: true) else {
            return
        }
        syncSettingsWindow()
        startTrackpadGestureDetector()
        configureSecondMissionControlSwipeMonitor()
        updateMissionControlGestureProbeEnabledState()
        updateSecondMissionControlSwipeMonitorEnabledState()
        updateInputEventProbeEnabledState()
    }

    func applicationWillTerminate(_ notification: Notification) {
        Logger.info("MissionSwipe terminating")
        trackpadGestureDetector.stop()
        gestureHUD.hide()
        layoutPreviewHUD.hide()
        settingsWindowController?.close()
        smartFitCapacityWindowController?.close()
        smartFitAdvancedWindowController?.close()
        pendingLayoutPreviewWorkItem?.cancel()
        previewLayoutGestureCandidate = nil
        lastPreviewLayoutHUDUpdateAt = nil
        missionControlGestureProbe.stop()
        secondMissionControlSwipeMonitor.stop()
        inputEventProbe.stop()
    }

    private func configureStatusBarController(_ statusBarController: StatusBarController) {
        statusBarController.onCloseWindow = { [weak self] in
            self?.closeMissionControlWindowUnderMouse(trigger: "menu item")
        }
        statusBarController.onArrangeVisibleWindows = { [weak self] in
            self?.arrangeVisibleWindows(trigger: "menu item")
        }
        statusBarController.onUndoLastArrange = { [weak self] in
            self?.windowArranger.undoLastArrange()
        }
        statusBarController.onOpenSettings = { [weak self] in
            self?.openSettings()
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
    }

    private func openSettings() {
        let controller: SettingsWindowController
        if let settingsWindowController {
            controller = settingsWindowController
        } else {
            controller = SettingsWindowController(language: configuration.language)
            settingsWindowController = controller
            configureSettingsWindowController(controller)
        }

        syncSettingsWindow()
        controller.show()
    }

    private func configureSettingsWindowController(_ controller: SettingsWindowController) {
        controller.onChangeLanguage = { [weak self] language in
            self?.configuration.language = language
            self?.statusBarController?.updateLanguage(language)
            self?.layoutPreviewHUD.updateLanguage(language)
            self?.syncSettingsWindow()
        }
        controller.onToggleMissionControlMode = { [weak self] isEnabled in
            self?.configuration.enableMissionControlMode = isEnabled
            self?.syncSettingsWindow()
        }
        controller.onToggleSwipeUpToClose = { [weak self] isEnabled in
            self?.configuration.enableSwipeUpToClose = isEnabled
            self?.updateTrackpadGestureDetectorEnabledState()
            self?.syncSettingsWindow()
        }
        controller.onToggleSwipeDownToMinimize = { [weak self] isEnabled in
            self?.configuration.enableSwipeDownToMinimize = isEnabled
            self?.updateTrackpadGestureDetectorEnabledState()
            self?.syncSettingsWindow()
        }
        controller.onToggleBlankAreaSwipeUpToArrange = { [weak self] isEnabled in
            self?.configuration.enableBlankAreaSwipeUpToArrange = isEnabled
            self?.updateTrackpadGestureDetectorEnabledState()
            self?.syncSettingsWindow()
        }
        controller.onTogglePreviewLayoutGestures = { [weak self] isEnabled in
            self?.configuration.enablePreviewLayoutGestures = isEnabled
            self?.updateTrackpadGestureDetectorEnabledState()
            if !isEnabled {
                self?.cancelPendingLayoutPreview(reason: "preview layout gestures disabled")
            }
            self?.syncSettingsWindow()
        }
        controller.onToggleSmartFitArrange = { [weak self] isEnabled in
            self?.configuration.enableSmartFitArrange = isEnabled
            self?.windowArranger.isSmartFitEnabled = isEnabled
            self?.syncSettingsWindow()
        }
        controller.onOpenSmartFitCapacities = { [weak self] in
            self?.openSmartFitCapacities()
        }
        controller.onOpenSmartFitAdvanced = { [weak self] in
            self?.openSmartFitAdvanced()
        }
        controller.onToggleDebugLogging = { [weak self] isEnabled in
            self?.configuration.enableDebugLogging = isEnabled
            self?.syncSettingsWindow()
        }
        controller.onToggleMissionControlGestureProbe = { [weak self] isEnabled in
            self?.configuration.enableMissionControlGestureProbe = isEnabled
            self?.updateMissionControlGestureProbeEnabledState()
            self?.syncSettingsWindow()
        }
        controller.onToggleInputEventProbe = { [weak self] isEnabled in
            self?.configuration.enableInputEventProbe = isEnabled
            self?.updateInputEventProbeEnabledState()
            self?.syncSettingsWindow()
        }
        controller.onArrangeVisibleWindows = { [weak self] in
            self?.arrangeVisibleWindows(trigger: "settings")
        }
        controller.onUndoLastArrange = { [weak self] in
            self?.windowArranger.undoLastArrange()
        }
        controller.onCopyLastActionReport = { [weak self] in
            self?.copyLastCloseReport()
        }
        controller.onCopyRecentLog = { [weak self] in
            self?.copyRecentLog()
        }
        controller.onDumpWindowList = { [weak self] in
            self?.debugWindowDumper.dumpWindowList()
        }
        controller.onDumpAXWindows = { [weak self] in
            self?.debugWindowDumper.dumpAXWindows()
        }
        controller.onRefreshPermission = { [weak self] in
            self?.refreshPermissionStatus(showPromptWhenMissing: false)
        }
        controller.onOpenAccessibilitySettings = {
            AccessibilityPermissionManager.openAccessibilitySettings()
        }
        controller.onHideMenuBarIcon = { [weak self] in
            self?.hideMenuBarIcon()
        }
    }

    private func syncSettingsWindow() {
        statusBarController?.updateLanguage(configuration.language)
        layoutPreviewHUD.updateLanguage(configuration.language)
        settingsWindowController?.update(
            configuration: configuration,
            isAccessibilityTrusted: permissionManager.isAccessibilityTrusted
        )
        smartFitCapacityWindowController?.update(
            profile: configuration.smartFitCapacityProfile,
            language: configuration.language
        )
        smartFitAdvancedWindowController?.update(
            strategy: configuration.smartFitOverflowStrategy,
            tolerance: configuration.smartFitOverlapTolerance,
            threeWindowLayout: configuration.threeWindowLayout,
            fourWindowLayout: configuration.fourWindowLayout,
            fiveWindowLayout: configuration.fiveWindowLayout,
            language: configuration.language
        )
    }

    private func openSmartFitAdvanced() {
        let controller: SmartFitAdvancedWindowController
        if let existing = smartFitAdvancedWindowController {
            controller = existing
        } else {
            controller = SmartFitAdvancedWindowController(
                strategy: configuration.smartFitOverflowStrategy,
                tolerance: configuration.smartFitOverlapTolerance,
                threeWindowLayout: configuration.threeWindowLayout,
                fourWindowLayout: configuration.fourWindowLayout,
                fiveWindowLayout: configuration.fiveWindowLayout,
                language: configuration.language
            )
            smartFitAdvancedWindowController = controller
            controller.onStrategyChanged = { [weak self] strategy in
                guard let self else { return }
                self.configuration.smartFitOverflowStrategy = strategy
                self.windowArranger.smartFitOverflowStrategy = strategy
            }
            controller.onToleranceChanged = { [weak self] tolerance in
                guard let self else { return }
                self.configuration.smartFitOverlapTolerance = tolerance
                self.windowArranger.smartFitOverlapTolerance = tolerance
            }
            controller.onThreeWindowLayoutChanged = { [weak self] layout in
                guard let self else { return }
                self.configuration.threeWindowLayout = layout
                self.windowArranger.threeWindowLayout = layout
            }
            controller.onFourWindowLayoutChanged = { [weak self] layout in
                guard let self else { return }
                self.configuration.fourWindowLayout = layout
                self.windowArranger.fourWindowLayout = layout
            }
            controller.onFiveWindowLayoutChanged = { [weak self] layout in
                guard let self else { return }
                self.configuration.fiveWindowLayout = layout
                self.windowArranger.fiveWindowLayout = layout
            }
        }
        controller.update(
            strategy: configuration.smartFitOverflowStrategy,
            tolerance: configuration.smartFitOverlapTolerance,
            threeWindowLayout: configuration.threeWindowLayout,
            fourWindowLayout: configuration.fourWindowLayout,
            fiveWindowLayout: configuration.fiveWindowLayout,
            language: configuration.language
        )
        controller.show()
    }

    private func openSmartFitCapacities() {
        let controller: SmartFitCapacityWindowController
        if let existing = smartFitCapacityWindowController {
            controller = existing
        } else {
            controller = SmartFitCapacityWindowController(
                profile: configuration.smartFitCapacityProfile,
                language: configuration.language
            )
            smartFitCapacityWindowController = controller
            controller.onProfileChanged = { [weak self] profile in
                guard let self else { return }
                self.configuration.smartFitCapacityProfile = profile
                self.windowArranger.smartFitCapacityProfile = profile
            }
            controller.onResetToDefaults = { [weak self] in
                self?.configuration.smartFitCapacityProfile = .default
                self?.windowArranger.smartFitCapacityProfile = .default
            }
        }
        controller.update(
            profile: configuration.smartFitCapacityProfile,
            language: configuration.language
        )
        controller.show()
    }

    private func handleSmartFitReport(_ report: WindowArranger.SmartFitReport) {
        let totalTouched = report.arrangedCount + report.minimizedCount + report.stackedCount
        guard totalTouched > 0 else {
            return
        }

        let zh = configuration.language == .simplifiedChinese

        if report.stackedCount > 0 {
            let message = zh
                ? "已堆叠 \(report.stackedCount) 个窗口"
                : "Stacked \(report.stackedCount)"
            gestureHUD.show(message: message, progress: 1, kind: .success, duration: 1.4)
            return
        }

        if report.minimizedCount > 0 {
            let message = zh
                ? "已收纳 \(report.minimizedCount) 个窗口"
                : "Minimized \(report.minimizedCount)"
            gestureHUD.show(message: message, progress: 1, kind: .success, duration: 1.4)
            return
        }

        if report.adapted {
            let message = zh
                ? "已自动适配 \(report.stubbornCount) 个固执窗口"
                : "Adapted around \(report.stubbornCount) stubborn"
            gestureHUD.show(message: message, progress: 1, kind: .success, duration: 1.2)
        }
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
        trackpadGestureDetector.shouldTriggerSwipeUp = { [weak self] accumulatedY in
            self?.shouldTriggerSwipeUp(accumulatedY: accumulatedY) ?? false
        }
        trackpadGestureDetector.shouldTriggerSwipeDown = { [weak self] accumulatedY in
            self?.shouldTriggerSwipeDown(accumulatedY: accumulatedY) ?? false
        }
        trackpadGestureDetector.shouldTriggerSwipeLeft = { [weak self] distance in
            self?.shouldTriggerPrimaryArrange(side: .right, distance: distance) ?? false
        }
        trackpadGestureDetector.shouldTriggerSwipeRight = { [weak self] distance in
            self?.shouldTriggerPrimaryArrange(side: .left, distance: distance) ?? false
        }
        trackpadGestureDetector.shouldTriggerLayoutSwipe = { [weak self] direction, distance in
            self?.shouldTriggerPreviewLayout(direction: direction, distance: distance) ?? false
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
        trackpadGestureDetector.onSwipeLeftDetected = { [weak self] in
            DispatchQueue.main.async {
                self?.arrangePrimaryWindowFromHorizontalSwipe(side: .right)
            }
        }
        trackpadGestureDetector.onSwipeRightDetected = { [weak self] in
            DispatchQueue.main.async {
                self?.arrangePrimaryWindowFromHorizontalSwipe(side: .left)
            }
        }
        trackpadGestureDetector.onLayoutSwipeDetected = { [weak self] direction in
            DispatchQueue.main.async {
                self?.arrangePrimaryWindowFromPreviewGesture(placement: self?.placement(for: direction) ?? .left)
            }
        }
        trackpadGestureDetector.start()
    }

    private func shouldTriggerSwipeUp(accumulatedY: CGFloat) -> Bool {
        guard configuration.enableSwipeUpToClose || configuration.enableBlankAreaSwipeUpToArrange else {
            return false
        }

        guard configuration.enableBlankAreaSwipeUpToArrange else {
            return allowSwipeUpCloseIfLongEnough(accumulatedY: accumulatedY)
        }

        switch windowCloser.classifyMissionControlSwipeLocation(usePreparedSwipeDetection: true) {
        case .blankArea:
            return allowBlankAreaArrangeIfLongEnough(accumulatedY: accumulatedY)
        case .windowTarget:
            guard configuration.enableSwipeUpToClose else {
                Logger.info("Swipe-up is over a Mission Control window, but close is disabled")
                return false
            }

            return allowSwipeUpCloseIfLongEnough(accumulatedY: accumulatedY)
        case .missionControlInactive, .permissionMissing:
            return false
        }
    }

    private func allowBlankAreaArrangeIfLongEnough(accumulatedY: CGFloat) -> Bool {
        let progress = accumulatedY / Constants.arrangeSwipeUpThresholdY
        let allowed = accumulatedY >= Constants.arrangeSwipeUpThresholdY
        if allowed {
            gestureHUD.show(message: text(en: "Arranging", zh: "整理中"), progress: 1, kind: .progress, duration: 0.75)
        } else {
            gestureHUD.show(message: text(en: "Swipe up to arrange", zh: "上滑整理"), progress: progress, kind: .progress, duration: 0.5)
            Logger.debug("Blank-area swipe-up arrange waiting for longer throw: accumulatedY=\(String(format: "%.2f", accumulatedY)), threshold=\(String(format: "%.2f", Constants.arrangeSwipeUpThresholdY))")
        }
        return allowed
    }

    private func allowSwipeUpCloseIfLongEnough(accumulatedY: CGFloat) -> Bool {
        let progress = accumulatedY / Constants.closeSwipeUpThresholdY
        let allowed = accumulatedY >= Constants.closeSwipeUpThresholdY
        if allowed {
            gestureHUD.show(message: text(en: "Closed", zh: "已关闭"), progress: 1, kind: .warning, duration: 0.75)
        } else {
            gestureHUD.show(message: text(en: "Swipe up to close", zh: "上滑关闭"), progress: progress, kind: .progress, duration: 0.5)
            Logger.debug("Swipe-up close waiting for longer throw over window: accumulatedY=\(String(format: "%.2f", accumulatedY)), threshold=\(String(format: "%.2f", Constants.closeSwipeUpThresholdY))")
        }
        return allowed
    }

    private func shouldTriggerSwipeDown(accumulatedY: CGFloat) -> Bool {
        guard configuration.enableSwipeDownToMinimize else {
            return false
        }

        switch windowCloser.classifyMissionControlSwipeLocation(usePreparedSwipeDetection: true) {
        case .windowTarget:
            return allowSwipeDownMinimizeIfLongEnough(accumulatedY: accumulatedY)
        case .blankArea:
            gestureHUD.show(message: text(en: "No target", zh: "无目标"), progress: 0, kind: .progress, duration: 0.45)
            return false
        case .missionControlInactive, .permissionMissing:
            return false
        }
    }

    private func allowSwipeDownMinimizeIfLongEnough(accumulatedY: CGFloat) -> Bool {
        let distance = abs(accumulatedY)
        let progress = distance / Constants.minimizeSwipeDownThresholdY
        let allowed = distance >= Constants.minimizeSwipeDownThresholdY
        if allowed {
            gestureHUD.show(message: text(en: "Minimized", zh: "已最小化"), progress: 1, kind: .success, duration: 0.75)
        } else {
            gestureHUD.show(message: text(en: "Swipe down to minimize", zh: "下滑最小化"), progress: progress, kind: .progress, duration: 0.5)
            Logger.debug("Swipe-down minimize waiting for longer throw over window: accumulatedY=\(String(format: "%.2f", accumulatedY)), threshold=\(String(format: "%.2f", Constants.minimizeSwipeDownThresholdY))")
        }
        return allowed
    }

    private func shouldTriggerPrimaryArrange(side: WindowArranger.PrimarySide, distance: CGFloat) -> Bool {
        guard configuration.enableBlankAreaSwipeUpToArrange else {
            return false
        }

        switch windowCloser.classifyMissionControlSwipeLocation(usePreparedSwipeDetection: true) {
        case .windowTarget:
            let message = side == .left
                ? text(en: "Primary left", zh: "左侧主排")
                : text(en: "Primary right", zh: "右侧主排")
            let progress = distance / Constants.primaryArrangeSwipeThresholdX
            let allowed = distance >= Constants.primaryArrangeSwipeThresholdX

            if allowed {
                if configuration.enablePreviewLayoutGestures {
                    Logger.debug("Primary arrange preview gesture confirmed: side=\(side.rawValue), distance=\(String(format: "%.2f", distance)), threshold=\(String(format: "%.2f", Constants.primaryArrangeSwipeThresholdX))")
                } else {
                    gestureHUD.show(message: message, progress: 1, kind: .success, duration: 0.75)
                }
            } else {
                gestureHUD.show(message: message, progress: progress, kind: .progress, duration: 0.5)
                Logger.debug("Primary arrange waiting for longer horizontal throw: side=\(side.rawValue), distance=\(String(format: "%.2f", distance)), threshold=\(String(format: "%.2f", Constants.primaryArrangeSwipeThresholdX))")
            }
            return allowed
        case .blankArea:
            gestureHUD.show(message: text(en: "No target", zh: "无目标"), progress: 0, kind: .progress, duration: 0.45)
            return false
        case .missionControlInactive, .permissionMissing:
            return false
        }
    }

    private func shouldTriggerPreviewLayout(direction: TrackpadLayoutSwipeDirection, distance: CGFloat) -> Bool {
        guard configuration.enablePreviewLayoutGestures,
              configuration.enableBlankAreaSwipeUpToArrange else {
            return false
        }

        switch windowCloser.classifyMissionControlSwipeLocation(usePreparedSwipeDetection: true) {
        case .windowTarget:
            let progress = distance / Constants.previewLayoutSwipeThreshold
            let allowed = distance >= Constants.previewLayoutSwipeThreshold
            let placement = placement(for: direction)
            if let candidate = previewLayoutCandidate(for: placement) {
                layoutPreviewHUD.show(
                    placement: placement,
                    windowCount: candidate.windowCount,
                    duration: allowed ? 1.25 : 0.55,
                    progress: progress,
                    isConfirmed: allowed,
                    shouldReposition: shouldUpdatePreviewLayoutHUDFrame(force: allowed)
                )
            }
            if !allowed {
                Logger.debug("Preview layout gesture waiting for longer throw: direction=\(direction), distance=\(String(format: "%.2f", distance)), threshold=\(String(format: "%.2f", Constants.previewLayoutSwipeThreshold))")
            }
            return allowed
        case .blankArea:
            gestureHUD.show(message: text(en: "No target", zh: "无目标"), progress: 0, kind: .progress, duration: 0.45)
            return false
        case .missionControlInactive, .permissionMissing:
            return false
        }
    }

    private func previewLayoutCandidate(for placement: WindowArranger.PrimaryPlacement) -> PreviewLayoutGestureCandidate? {
        let now = Date()
        if let candidate = previewLayoutGestureCandidate,
           candidate.placement == placement,
           now.timeIntervalSince(candidate.createdAt) <= Constants.previewLayoutGestureCandidateLifetime {
            return candidate
        }

        guard let primaryWindow = windowCloser.missionControlWindowUnderMouseIfActive(usePreparedSwipeDetection: true) else {
            previewLayoutGestureCandidate = nil
            lastPreviewLayoutHUDUpdateAt = nil
            return nil
        }

        let candidate = PreviewLayoutGestureCandidate(
            placement: placement,
            primaryWindow: primaryWindow,
            windowCount: currentMissionControlWindowCount(primaryWindow: primaryWindow),
            createdAt: now
        )
        previewLayoutGestureCandidate = candidate
        lastPreviewLayoutHUDUpdateAt = nil
        return candidate
    }

    private func shouldUpdatePreviewLayoutHUDFrame(force: Bool) -> Bool {
        if force {
            lastPreviewLayoutHUDUpdateAt = Date()
            return true
        }

        let now = Date()
        guard let lastPreviewLayoutHUDUpdateAt else {
            self.lastPreviewLayoutHUDUpdateAt = now
            return true
        }

        guard now.timeIntervalSince(lastPreviewLayoutHUDUpdateAt) >= Constants.previewLayoutHUDUpdateInterval else {
            return false
        }

        self.lastPreviewLayoutHUDUpdateAt = now
        return true
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
        trackpadGestureDetector.detectsSwipeLeftRight = configuration.enableBlankAreaSwipeUpToArrange
        trackpadGestureDetector.detectsLayoutSwipe = configuration.enablePreviewLayoutGestures && configuration.enableBlankAreaSwipeUpToArrange
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
                cancelPendingLayoutPreview(reason: "blank-area swipe-up arrange")
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

        cancelPendingLayoutPreview(reason: "Mission Control window close")
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
        cancelPendingLayoutPreview(reason: "Mission Control window minimize")
        gestureHUD.show(message: text(en: "Minimized", zh: "已最小化"), progress: 1, kind: .success)
        let result = windowCloser.minimizeMissionControlWindowUnderMouseIfActive(usePreparedSwipeDetection: true)
        if result == .performed {
            secondMissionControlSwipeMonitor.suppressCurrentMissionControlSession(reason: "Mission Control window minimize")
        }
        refreshPermissionStatus(showPromptWhenMissing: false)
    }

    private func arrangePrimaryWindowFromHorizontalSwipe(side: WindowArranger.PrimarySide) {
        guard configuration.enableBlankAreaSwipeUpToArrange else {
            Logger.info("Primary-window horizontal arrange is disabled because blank-area arrange is disabled")
            return
        }

        guard configuration.enableMissionControlMode else {
            Logger.info("Mission Control mode is disabled; ignoring horizontal primary arrange")
            return
        }

        if configuration.enablePreviewLayoutGestures {
            arrangePrimaryWindowFromPreviewGesture(placement: WindowArranger.PrimaryPlacement(side: side))
            return
        }

        Logger.info("Primary-window arrange requested by trackpad swipe-\(side.rawValue)")
        guard let primaryWindow = windowCloser.missionControlWindowUnderMouseIfActive(usePreparedSwipeDetection: true) else {
            Logger.info("Horizontal primary arrange found no safe Mission Control target")
            refreshPermissionStatus(showPromptWhenMissing: false)
            return
        }

        windowCloser.clearPreparedSwipeAction()
        secondMissionControlSwipeMonitor.suppressCurrentMissionControlSession(reason: "horizontal primary arrange")
        windowArranger.arrangeAfterExitingMissionControl(
            trigger: "horizontal primary swipe-\(side.rawValue)",
            primaryWindow: primaryWindow,
            primarySide: side,
            preferCurrentMouseExitPoint: true
        )
        refreshPermissionStatus(showPromptWhenMissing: false)
    }

    private func arrangePrimaryWindowFromPreviewGesture(placement: WindowArranger.PrimaryPlacement) {
        guard configuration.enablePreviewLayoutGestures,
              configuration.enableBlankAreaSwipeUpToArrange else {
            Logger.info("Preview layout gesture is disabled; ignoring preview arrange")
            return
        }

        guard configuration.enableMissionControlMode else {
            Logger.info("Mission Control mode is disabled; ignoring preview layout gesture")
            return
        }

        Logger.info("Preview layout requested by trackpad gesture: placement=\(placement.rawValue)")
        let cachedCandidate = previewLayoutGestureCandidate
        let candidateIsUsable = cachedCandidate?.placement == placement &&
            Date().timeIntervalSince(cachedCandidate?.createdAt ?? .distantPast) <= Constants.previewLayoutGestureCandidateLifetime
        let primaryWindow: AXWindowSnapshot
        let windowCount: Int
        if let cachedCandidate, candidateIsUsable {
            primaryWindow = cachedCandidate.primaryWindow
            windowCount = cachedCandidate.windowCount
        } else if let selectedWindow = windowCloser.missionControlWindowUnderMouseIfActive(usePreparedSwipeDetection: true) {
            primaryWindow = selectedWindow
            windowCount = currentMissionControlWindowCount(primaryWindow: selectedWindow)
        } else {
            Logger.info("Preview layout gesture found no safe Mission Control target")
            refreshPermissionStatus(showPromptWhenMissing: false)
            return
        }

        pendingLayoutPreviewWorkItem?.cancel()
        previewLayoutGestureCandidate = nil
        lastPreviewLayoutHUDUpdateAt = nil
        layoutPreviewHUD.show(
            placement: placement,
            windowCount: windowCount,
            duration: 1.8,
            progress: 1,
            isConfirmed: true,
            shouldReposition: false
        )

        let workItem = DispatchWorkItem { [weak self, primaryWindow] in
            guard let self else {
                return
            }

            self.runPreviewLayoutAfterMissionControlExit(
                primaryWindow: primaryWindow,
                placement: placement,
                startedAt: Date()
            )
        }

        pendingLayoutPreviewWorkItem = workItem
        DispatchQueue.main.async(execute: workItem)
    }

    private func runPreviewLayoutAfterMissionControlExit(
        primaryWindow: AXWindowSnapshot,
        placement: WindowArranger.PrimaryPlacement,
        startedAt: Date
    ) {
        guard pendingLayoutPreviewWorkItem != nil else {
            Logger.info("Preview layout wait was cancelled before Mission Control exit")
            return
        }

        let detection = currentMissionControlDetection()
        if detection.isLikelyActive {
            let workItem = DispatchWorkItem { [weak self, primaryWindow] in
                self?.runPreviewLayoutAfterMissionControlExit(
                    primaryWindow: primaryWindow,
                    placement: placement,
                    startedAt: startedAt
                )
            }
            pendingLayoutPreviewWorkItem = workItem
            DispatchQueue.main.asyncAfter(deadline: .now() + Constants.previewLayoutExitPollDelay, execute: workItem)
            return
        }

        pendingLayoutPreviewWorkItem = nil
        windowCloser.clearPreparedSwipeAction()
        layoutPreviewHUD.hide()
        secondMissionControlSwipeMonitor.suppressCurrentMissionControlSession(reason: "preview layout arrange after exit")

        let elapsed = Date().timeIntervalSince(startedAt)
        Logger.info(
            "Mission Control exited; executing pending preview layout. placement=\(placement.rawValue), elapsed=\(String(format: "%.2f", elapsed))s, detection=\(detection.debugSummary)"
        )

        DispatchQueue.main.asyncAfter(deadline: .now() + Constants.previewLayoutExitSettleDelay) { [weak self, primaryWindow] in
            guard let self else {
                return
            }

            self.windowArranger.arrangeVisibleWindows(
                trigger: "preview layout after Mission Control exit \(placement.rawValue)",
                primaryWindow: primaryWindow,
                primaryPlacement: placement
            )
            self.refreshPermissionStatus(showPromptWhenMissing: false)
        }
    }

    private func currentMissionControlDetection() -> MissionControlDetection {
        let mousePoint = windowEnumerator.currentMouseLocationInCGWindowCoordinates()
        let entries = windowEnumerator.allWindowEntries(options: [.optionOnScreenOnly])
        return missionControlDetector.detect(mousePoint: mousePoint, entries: entries)
    }

    private func currentMissionControlWindowCount(primaryWindow: AXWindowSnapshot) -> Int {
        max(1, windowArranger.arrangeableWindowCountForPreview(primaryWindow: primaryWindow))
    }

    private func placement(for direction: TrackpadLayoutSwipeDirection) -> WindowArranger.PrimaryPlacement {
        switch direction {
        case .upLeft:
            return .topRight
        case .upRight:
            return .topLeft
        case .downLeft:
            return .bottomRight
        case .downRight:
            return .bottomLeft
        }
    }

    private func cancelPendingLayoutPreview(reason: String) {
        guard pendingLayoutPreviewWorkItem != nil else {
            return
        }

        Logger.info("Cancelling pending preview layout: \(reason)")
        pendingLayoutPreviewWorkItem?.cancel()
        pendingLayoutPreviewWorkItem = nil
        previewLayoutGestureCandidate = nil
        lastPreviewLayoutHUDUpdateAt = nil
        layoutPreviewHUD.hide()
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
            let message = configuration.language == .simplifiedChinese
                ? "暂无报告 — 先做一次关窗或最小化"
                : "No recent report — close or minimize a window first"
            gestureHUD.show(message: message, progress: 0, kind: .warning, duration: 1.6)
            return
        }

        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(report, forType: .string)
        Logger.info("Copied last Mission Control action report to clipboard")
        let message = configuration.language == .simplifiedChinese
            ? "报告已复制"
            : "Report copied"
        gestureHUD.show(message: message, progress: 1, kind: .success, duration: 1.2)
    }

    private func copyRecentLog() {
        let zh = configuration.language == .simplifiedChinese
        let logURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Logs", isDirectory: true)
            .appendingPathComponent("MissionSwipe", isDirectory: true)
            .appendingPathComponent("MissionSwipe.log")

        guard let raw = try? String(contentsOf: logURL, encoding: .utf8), !raw.isEmpty else {
            let message = zh ? "暂无日志" : "No log content yet"
            gestureHUD.show(message: message, progress: 0, kind: .warning, duration: 1.6)
            return
        }

        // Grab the tail end of the log so a single paste fits in chat without
        // overwhelming the user. 300 lines covers several arrange + close cycles.
        let lines = raw.split(separator: "\n", omittingEmptySubsequences: false)
        let tailCount = min(300, lines.count)
        let tail = lines.suffix(tailCount).joined(separator: "\n")

        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(tail, forType: .string)
        Logger.info("Copied last \(tailCount) log lines to clipboard")

        let message = zh ? "已复制最近 \(tailCount) 行日志" : "Copied last \(tailCount) log lines"
        gestureHUD.show(message: message, progress: 1, kind: .success, duration: 1.4)
    }

    private func hideMenuBarIcon() {
        NSApp.activate(ignoringOtherApps: true)

        let alert = NSAlert()
        alert.messageText = text(en: "Hide MissionSwipe menu bar icon?", zh: "隐藏 MissionSwipe 菜单栏图标？")
        alert.informativeText = """
        \(text(en: "MissionSwipe will keep running in the background. To show the icon again later, run:", zh: "MissionSwipe 会继续在后台运行。以后要重新显示图标，运行："))

        defaults write io.github.stevenalva.MissionSwipe HideStatusBarIcon -bool false; open -a MissionSwipe
        """
        alert.alertStyle = .informational
        alert.addButton(withTitle: text(en: "Hide Icon", zh: "隐藏图标"))
        alert.addButton(withTitle: text(en: "Cancel", zh: "取消"))

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
        syncSettingsWindow()

        if !isTrusted && showPromptWhenMissing {
            permissionManager.logPermissionDiagnostics(reason: "Permission missing on launch")
            if permissionManager.requestSystemAccessibilityPromptIfNeeded() {
                permissionManager.showRestartRequiredAlertThenQuit()
                return false
            }
        }

        return true
    }

    private func text(en: String, zh: String) -> String {
        configuration.language == .simplifiedChinese ? zh : en
    }
}
