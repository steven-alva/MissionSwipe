import AppKit

final class StatusBarController: NSObject {
    var onCloseWindow: (() -> Void)?
    var onArrangeVisibleWindows: (() -> Void)?
    var onUndoLastArrange: (() -> Void)?
    var onOpenSettings: (() -> Void)?
    var onRefreshPermission: (() -> Void)?
    var onOpenAccessibilitySettings: (() -> Void)?
    var onQuit: (() -> Void)?

    private let statusItem: NSStatusItem
    private let permissionStatusItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private var language: AppLanguage
    private var isAccessibilityTrusted = false

    init(language: AppLanguage = AppConfiguration.shared.language) {
        self.language = language
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()
        configureStatusItem()
        updateAccessibilityStatus(isTrusted: isAccessibilityTrusted)
    }

    func updateLanguage(_ language: AppLanguage) {
        guard self.language != language else {
            return
        }
        self.language = language
        configureStatusItem()
        updateAccessibilityStatus(isTrusted: isAccessibilityTrusted)
    }

    func updateAccessibilityStatus(isTrusted: Bool) {
        isAccessibilityTrusted = isTrusted
        permissionStatusItem.title = isTrusted
            ? text(en: "Accessibility: Granted", zh: "辅助功能权限：已授权")
            : text(en: "Accessibility: Missing", zh: "辅助功能权限：未授权")
        permissionStatusItem.image = NSImage(
            systemSymbolName: isTrusted ? "checkmark.circle" : "exclamationmark.triangle",
            accessibilityDescription: permissionStatusItem.title
        )
    }

    func removeStatusItem() {
        NSStatusBar.system.removeStatusItem(statusItem)
    }

    private func configureStatusItem() {
        if let button = statusItem.button {
            if let image = NSImage(systemSymbolName: "cursorarrow.click.2", accessibilityDescription: "MissionSwipe") {
                image.isTemplate = true
                button.image = image
            } else {
                button.title = "MS"
            }
            button.toolTip = "MissionSwipe"
        }

        let menu = NSMenu(title: "MissionSwipe")
        permissionStatusItem.isEnabled = false
        menu.addItem(permissionStatusItem)
        menu.addItem(.separator())

        menu.addItem(menuItem(text(en: "Close Mission Control Window", zh: "关闭调度中心窗口"), action: #selector(closeWindow), keyEquivalent: "w", modifiers: [.control, .option]))
        menu.addItem(menuItem(text(en: "Arrange Visible Windows", zh: "整理可见窗口"), action: #selector(arrangeVisibleWindows)))
        menu.addItem(menuItem(text(en: "Undo Last Arrange", zh: "撤销上次整理"), action: #selector(undoLastArrange)))
        menu.addItem(.separator())
        menu.addItem(menuItem(text(en: "Settings...", zh: "设置..."), action: #selector(openSettings), keyEquivalent: ",", modifiers: [.command]))
        menu.addItem(menuItem(text(en: "Check Accessibility Permission", zh: "检查辅助功能权限"), action: #selector(refreshPermission)))
        menu.addItem(menuItem(text(en: "Open Accessibility Settings", zh: "打开辅助功能设置"), action: #selector(openAccessibilitySettings)))
        menu.addItem(.separator())
        menu.addItem(menuItem(text(en: "Quit MissionSwipe", zh: "退出 MissionSwipe"), action: #selector(quit), keyEquivalent: "q", modifiers: [.command]))

        statusItem.menu = menu
    }

    private func menuItem(
        _ title: String,
        action: Selector,
        keyEquivalent: String = "",
        modifiers: NSEvent.ModifierFlags = []
    ) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: keyEquivalent)
        item.target = self
        item.keyEquivalentModifierMask = modifiers
        return item
    }

    private func text(en: String, zh: String) -> String {
        language == .simplifiedChinese ? zh : en
    }

    @objc private func closeWindow() {
        onCloseWindow?()
    }

    @objc private func arrangeVisibleWindows() {
        onArrangeVisibleWindows?()
    }

    @objc private func undoLastArrange() {
        onUndoLastArrange?()
    }

    @objc private func openSettings() {
        onOpenSettings?()
    }

    @objc private func refreshPermission() {
        onRefreshPermission?()
    }

    @objc private func openAccessibilitySettings() {
        onOpenAccessibilitySettings?()
    }

    @objc private func quit() {
        onQuit?()
    }
}
