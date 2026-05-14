import AppKit

final class SettingsWindowController: NSWindowController {
    var onChangeLanguage: ((AppLanguage) -> Void)?
    var onToggleMissionControlMode: ((Bool) -> Void)?
    var onToggleSwipeUpToClose: ((Bool) -> Void)?
    var onToggleSwipeDownToMinimize: ((Bool) -> Void)?
    var onToggleBlankAreaSwipeUpToArrange: ((Bool) -> Void)?
    var onTogglePreviewLayoutGestures: ((Bool) -> Void)?
    var onToggleSmartFitArrange: ((Bool) -> Void)?
    var onOpenSmartFitCapacities: (() -> Void)?
    var onOpenSmartFitAdvanced: (() -> Void)?
    var onToggleDebugLogging: ((Bool) -> Void)?
    var onArrangeVisibleWindows: (() -> Void)?
    var onUndoLastArrange: (() -> Void)?
    var onOpenDiagnosticsPanel: (() -> Void)?
    var onRefreshPermission: (() -> Void)?
    var onOpenAccessibilitySettings: (() -> Void)?
    var onHideMenuBarIcon: (() -> Void)?

    private enum Toggle: String {
        case missionControlMode
        case swipeUpToClose
        case swipeDownToMinimize
        case blankAreaSwipeUpToArrange
        case previewLayoutGestures
        case smartFitArrange
        case debugLogging
    }

    private let permissionLabel = NSTextField(labelWithString: "")
    private var toggles: [Toggle: NSButton] = [:]
    private var languagePopup: NSPopUpButton?
    private var currentLanguage: AppLanguage

    init(language: AppLanguage = AppConfiguration.shared.language) {
        currentLanguage = language
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 650),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        super.init(window: window)
        buildContent()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    func show() {
        NSApp.activate(ignoringOtherApps: true)
        window?.center()
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }

    func update(configuration: AppConfiguration, isAccessibilityTrusted: Bool) {
        if currentLanguage != configuration.language {
            currentLanguage = configuration.language
            buildContent()
        }

        set(.missionControlMode, configuration.enableMissionControlMode)
        set(.swipeUpToClose, configuration.enableSwipeUpToClose)
        set(.swipeDownToMinimize, configuration.enableSwipeDownToMinimize)
        set(.blankAreaSwipeUpToArrange, configuration.enableBlankAreaSwipeUpToArrange)
        set(.previewLayoutGestures, configuration.enablePreviewLayoutGestures)
        set(.smartFitArrange, configuration.enableSmartFitArrange)
        set(.debugLogging, configuration.enableDebugLogging)

        languagePopup?.selectItem(withTitle: currentLanguage.displayName)
        permissionLabel.stringValue = isAccessibilityTrusted
            ? text(en: "Accessibility: Granted", zh: "辅助功能权限：已授权")
            : text(en: "Accessibility: Missing", zh: "辅助功能权限：未授权")
        permissionLabel.textColor = isAccessibilityTrusted ? .systemGreen : .systemOrange
    }

    private func buildContent() {
        guard let window else {
            return
        }

        toggles.removeAll()
        window.title = text(en: "MissionSwipe Settings", zh: "MissionSwipe 设置")

        let root = NSView()
        root.translatesAutoresizingMaskIntoConstraints = false
        window.contentView = root

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 18
        stack.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -24),
            stack.topAnchor.constraint(equalTo: root.topAnchor, constant: 22),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: root.bottomAnchor, constant: -22)
        ])

        let title = NSTextField(labelWithString: "MissionSwipe")
        title.font = .systemFont(ofSize: 22, weight: .semibold)
        stack.addArrangedSubview(title)

        permissionLabel.font = .systemFont(ofSize: 12, weight: .medium)
        stack.addArrangedSubview(permissionLabel)

        stack.addArrangedSubview(section(
            title: text(en: "Core", zh: "核心功能"),
            views: [
                toggle(text(en: "Mission Control mode", zh: "调度中心模式"), detail: text(en: "Only acts when Mission Control is detected.", zh: "只在检测到调度中心时响应。"), key: .missionControlMode),
                toggle(text(en: "Swipe up to close", zh: "上滑关闭"), detail: text(en: "Close the window under the pointer in Mission Control.", zh: "关闭调度中心里鼠标下方的窗口。"), key: .swipeUpToClose),
                toggle(text(en: "Swipe down to minimize", zh: "下滑最小化"), detail: text(en: "Minimize the window under the pointer in Mission Control.", zh: "最小化调度中心里鼠标下方的窗口。"), key: .swipeDownToMinimize),
                toggle(text(en: "Blank-area swipe up to arrange", zh: "空白上滑整理"), detail: text(en: "Arrange visible windows after exiting Mission Control.", zh: "退出调度中心后整理当前可见窗口。"), key: .blankAreaSwipeUpToArrange)
            ]
        ))

        let smartFitToggleView = toggle(
            text(en: "Smart Fit arrange", zh: "Smart Fit 整理"),
            detail: text(
                en: "Fit as many windows as your screen can clearly show. Minimize the rest. Adapts when an app refuses to shrink.",
                zh: "按屏幕容量铺满清晰可见的窗口，其余自动最小化收纳；遇到不肯缩小的应用会自动适配。"
            ),
            key: .smartFitArrange
        )

        let smartFitButtons = buttonRow([
            actionButton(text(en: "Customize capacities…", zh: "自定义容量…"), action: #selector(openSmartFitCapacities)),
            actionButton(text(en: "Advanced…", zh: "高级设置…"), action: #selector(openSmartFitAdvanced))
        ])

        let layoutViews: [NSView] = [
            smartFitToggleView,
            smartFitButtons,
            toggle(
                text(en: "Layout Dashboard", zh: "排版 Dashboard"),
                detail: text(
                    en: "Preview and confirm directional layouts before they apply.",
                    zh: "在应用方向排版前预览并确认布局。"
                ),
                key: .previewLayoutGestures
            ),
            buttonRow([
                actionButton(text(en: "Arrange Now", zh: "立即整理"), action: #selector(arrangeVisibleWindows)),
                actionButton(text(en: "Undo Arrange", zh: "撤销整理"), action: #selector(undoLastArrange))
            ])
        ]

        stack.addArrangedSubview(section(
            title: text(en: "Layout", zh: "排版"),
            views: layoutViews
        ))

        stack.addArrangedSubview(section(
            title: text(en: "Diagnostics", zh: "诊断"),
            views: [
                toggle(text(en: "Debug logging", zh: "调试日志"), detail: text(en: "More detailed logs for troubleshooting.", zh: "记录更详细的排查日志。"), key: .debugLogging),
                buttonRow([
                    actionButton(text(en: "Diagnostics panel…", zh: "诊断面板…"), action: #selector(openDiagnosticsPanel))
                ])
            ]
        ))

        stack.addArrangedSubview(section(
            title: text(en: "System", zh: "系统"),
            views: [
                languageRow(),
                buttonRow([
                    actionButton(text(en: "Check Permission", zh: "检查权限"), action: #selector(refreshPermission)),
                    actionButton(text(en: "Open Accessibility Settings", zh: "打开辅助功能设置"), action: #selector(openAccessibilitySettings))
                ]),
                buttonRow([
                    actionButton(text(en: "Hide Menu Bar Icon", zh: "隐藏菜单栏图标"), action: #selector(hideMenuBarIcon))
                ])
            ]
        ))
    }

    private func section(title: String, views: [NSView]) -> NSView {
        let container = NSStackView()
        container.orientation = .vertical
        container.alignment = .leading
        container.spacing = 8
        container.translatesAutoresizingMaskIntoConstraints = false

        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 13, weight: .semibold)
        label.textColor = .secondaryLabelColor
        container.addArrangedSubview(label)

        for view in views {
            container.addArrangedSubview(view)
        }

        container.widthAnchor.constraint(equalToConstant: 412).isActive = true
        return container
    }

    private func languageRow() -> NSView {
        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 10

        let label = NSTextField(labelWithString: text(en: "Language", zh: "语言"))
        label.font = .systemFont(ofSize: 13, weight: .medium)
        label.widthAnchor.constraint(equalToConstant: 140).isActive = true
        row.addArrangedSubview(label)

        let popup = NSPopUpButton()
        popup.addItems(withTitles: AppLanguage.allCases.map(\.displayName))
        popup.selectItem(withTitle: currentLanguage.displayName)
        popup.target = self
        popup.action = #selector(languageChanged(_:))
        popup.widthAnchor.constraint(equalToConstant: 160).isActive = true
        languagePopup = popup
        row.addArrangedSubview(popup)

        return row
    }

    private func toggle(_ title: String, detail: String, key: Toggle) -> NSView {
        let container = NSStackView()
        container.orientation = .vertical
        container.alignment = .leading
        container.spacing = 2

        let checkbox = NSButton(checkboxWithTitle: title, target: self, action: #selector(toggleChanged(_:)))
        checkbox.identifier = NSUserInterfaceItemIdentifier(key.rawValue)
        checkbox.font = .systemFont(ofSize: 13, weight: .medium)
        toggles[key] = checkbox
        container.addArrangedSubview(checkbox)

        let detailLabel = NSTextField(labelWithString: detail)
        detailLabel.font = .systemFont(ofSize: 11)
        detailLabel.textColor = .secondaryLabelColor
        detailLabel.lineBreakMode = .byWordWrapping
        detailLabel.maximumNumberOfLines = 2
        detailLabel.widthAnchor.constraint(equalToConstant: 390).isActive = true
        container.addArrangedSubview(detailLabel)

        return container
    }

    private func buttonRow(_ buttons: [NSButton]) -> NSView {
        let row = NSStackView(views: buttons)
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 8
        return row
    }

    private func actionButton(_ title: String, action: Selector) -> NSButton {
        let button = NSButton(title: title, target: self, action: action)
        button.bezelStyle = .rounded
        return button
    }

    private func set(_ toggle: Toggle, _ isEnabled: Bool) {
        toggles[toggle]?.state = isEnabled ? .on : .off
    }

    private func text(en: String, zh: String) -> String {
        currentLanguage == .simplifiedChinese ? zh : en
    }

    @objc private func languageChanged(_ sender: NSPopUpButton) {
        let selectedIndex = sender.indexOfSelectedItem
        guard AppLanguage.allCases.indices.contains(selectedIndex) else {
            return
        }
        onChangeLanguage?(AppLanguage.allCases[selectedIndex])
    }

    @objc private func toggleChanged(_ sender: NSButton) {
        guard let rawValue = sender.identifier?.rawValue,
              let toggle = Toggle(rawValue: rawValue) else {
            return
        }

        let isEnabled = sender.state == .on
        switch toggle {
        case .missionControlMode:
            onToggleMissionControlMode?(isEnabled)
        case .swipeUpToClose:
            onToggleSwipeUpToClose?(isEnabled)
        case .swipeDownToMinimize:
            onToggleSwipeDownToMinimize?(isEnabled)
        case .blankAreaSwipeUpToArrange:
            onToggleBlankAreaSwipeUpToArrange?(isEnabled)
        case .previewLayoutGestures:
            onTogglePreviewLayoutGestures?(isEnabled)
        case .smartFitArrange:
            onToggleSmartFitArrange?(isEnabled)
        case .debugLogging:
            onToggleDebugLogging?(isEnabled)
        }
    }

    @objc private func openSmartFitCapacities() {
        onOpenSmartFitCapacities?()
    }

    @objc private func openSmartFitAdvanced() {
        onOpenSmartFitAdvanced?()
    }

    @objc private func openDiagnosticsPanel() {
        onOpenDiagnosticsPanel?()
    }

    @objc private func arrangeVisibleWindows() {
        onArrangeVisibleWindows?()
    }

    @objc private func undoLastArrange() {
        onUndoLastArrange?()
    }

    @objc private func refreshPermission() {
        onRefreshPermission?()
    }

    @objc private func openAccessibilitySettings() {
        onOpenAccessibilitySettings?()
    }

    @objc private func hideMenuBarIcon() {
        onHideMenuBarIcon?()
    }
}
