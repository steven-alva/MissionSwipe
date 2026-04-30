import AppKit

final class StatusBarController: NSObject {
    var onCloseWindow: (() -> Void)?
    var onToggleMissionControlMode: ((Bool) -> Void)?
    var onToggleSwipeUpToClose: ((Bool) -> Void)?
    var onToggleSwipeDownToMinimize: ((Bool) -> Void)?
    var onToggleDebugLogging: ((Bool) -> Void)?
    var onDumpWindowList: (() -> Void)?
    var onDumpAXWindows: (() -> Void)?
    var onCopyLastCloseReport: (() -> Void)?
    var onOpenAccessibilitySettings: (() -> Void)?
    var onRefreshPermission: (() -> Void)?
    var onQuit: (() -> Void)?

    private let statusItem: NSStatusItem
    private let permissionStatusItem: NSMenuItem
    private let missionControlModeItem: NSMenuItem
    private let swipeUpToCloseItem: NSMenuItem
    private let swipeDownToMinimizeItem: NSMenuItem
    private let debugLoggingItem: NSMenuItem

    override init() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        permissionStatusItem = NSMenuItem(title: "Accessibility: Checking...", action: nil, keyEquivalent: "")
        missionControlModeItem = NSMenuItem(title: "Enable Mission Control Close", action: #selector(toggleMissionControlMode), keyEquivalent: "")
        swipeUpToCloseItem = NSMenuItem(title: "Enable Swipe Up to Close", action: #selector(toggleSwipeUpToClose), keyEquivalent: "")
        swipeDownToMinimizeItem = NSMenuItem(title: "Enable Swipe Down to Minimize (Experimental)", action: #selector(toggleSwipeDownToMinimize), keyEquivalent: "")
        debugLoggingItem = NSMenuItem(title: "Debug Logging", action: #selector(toggleDebugLogging), keyEquivalent: "")

        super.init()
        configureStatusItem()
    }

    func updateAccessibilityStatus(isTrusted: Bool) {
        permissionStatusItem.title = isTrusted ? "Accessibility: Granted" : "Accessibility: Missing"
        permissionStatusItem.image = NSImage(
            systemSymbolName: isTrusted ? "checkmark.circle" : "exclamationmark.triangle",
            accessibilityDescription: permissionStatusItem.title
        )
    }

    func updateMissionControlMode(isEnabled: Bool) {
        missionControlModeItem.state = isEnabled ? .on : .off
    }

    func updateSwipeUpToClose(isEnabled: Bool) {
        swipeUpToCloseItem.state = isEnabled ? .on : .off
    }

    func updateSwipeDownToMinimize(isEnabled: Bool) {
        swipeDownToMinimizeItem.state = isEnabled ? .on : .off
    }

    func updateDebugLogging(isEnabled: Bool) {
        debugLoggingItem.state = isEnabled ? .on : .off
    }

    private func configureStatusItem() {
        if let button = statusItem.button {
            if let image = NSImage(systemSymbolName: "cursorarrow.click.2", accessibilityDescription: "MissionSwipe") {
                image.isTemplate = true
                button.image = image
            } else {
                button.title = "MS"
            }
            button.toolTip = "MissionSwipe - Mission Control close only"
        }

        let menu = NSMenu(title: "MissionSwipe")
        permissionStatusItem.isEnabled = false
        menu.addItem(permissionStatusItem)
        menu.addItem(.separator())

        let closeItem = NSMenuItem(title: "Close Mission Control Window", action: #selector(closeWindow), keyEquivalent: "")
        closeItem.target = self
        closeItem.keyEquivalentModifierMask = [.control, .option]
        closeItem.keyEquivalent = "w"
        menu.addItem(closeItem)

        missionControlModeItem.target = self
        missionControlModeItem.state = .on
        menu.addItem(missionControlModeItem)

        swipeUpToCloseItem.target = self
        swipeUpToCloseItem.state = .on
        menu.addItem(swipeUpToCloseItem)

        swipeDownToMinimizeItem.target = self
        swipeDownToMinimizeItem.state = .off
        menu.addItem(swipeDownToMinimizeItem)

        menu.addItem(.separator())

        debugLoggingItem.target = self
        debugLoggingItem.state = .off
        menu.addItem(debugLoggingItem)

        let copyLastCloseReportItem = NSMenuItem(title: "Copy Last Action Report", action: #selector(copyLastCloseReport), keyEquivalent: "")
        copyLastCloseReportItem.target = self
        menu.addItem(copyLastCloseReportItem)

        let dumpWindowListItem = NSMenuItem(title: "Dump Window List", action: #selector(dumpWindowList), keyEquivalent: "")
        dumpWindowListItem.target = self
        menu.addItem(dumpWindowListItem)

        let dumpAXWindowsItem = NSMenuItem(title: "Dump AX Windows", action: #selector(dumpAXWindows), keyEquivalent: "")
        dumpAXWindowsItem.target = self
        menu.addItem(dumpAXWindowsItem)

        menu.addItem(.separator())

        let refreshItem = NSMenuItem(title: "Check Accessibility Permission", action: #selector(refreshPermission), keyEquivalent: "")
        refreshItem.target = self
        menu.addItem(refreshItem)

        let settingsItem = NSMenuItem(title: "Open Accessibility Settings", action: #selector(openAccessibilitySettings), keyEquivalent: "")
        settingsItem.target = self
        menu.addItem(settingsItem)

        menu.addItem(.separator())

        let quitItem = NSMenuItem(title: "Quit MissionSwipe", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        statusItem.menu = menu
    }

    @objc private func closeWindow() {
        onCloseWindow?()
    }

    @objc private func toggleMissionControlMode() {
        let newValue = missionControlModeItem.state != .on
        updateMissionControlMode(isEnabled: newValue)
        onToggleMissionControlMode?(newValue)
    }

    @objc private func toggleSwipeUpToClose() {
        let newValue = swipeUpToCloseItem.state != .on
        updateSwipeUpToClose(isEnabled: newValue)
        onToggleSwipeUpToClose?(newValue)
    }

    @objc private func toggleSwipeDownToMinimize() {
        let newValue = swipeDownToMinimizeItem.state != .on
        updateSwipeDownToMinimize(isEnabled: newValue)
        onToggleSwipeDownToMinimize?(newValue)
    }

    @objc private func toggleDebugLogging() {
        let newValue = debugLoggingItem.state != .on
        updateDebugLogging(isEnabled: newValue)
        onToggleDebugLogging?(newValue)
    }

    @objc private func copyLastCloseReport() {
        onCopyLastCloseReport?()
    }

    @objc private func dumpWindowList() {
        onDumpWindowList?()
    }

    @objc private func dumpAXWindows() {
        onDumpAXWindows?()
    }

    @objc private func openAccessibilitySettings() {
        onOpenAccessibilitySettings?()
    }

    @objc private func refreshPermission() {
        onRefreshPermission?()
    }

    @objc private func quit() {
        onQuit?()
    }
}
