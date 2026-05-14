import AppKit

final class DiagnosticsWindowController: NSWindowController {
    var onChangeRecentLogLineCount: ((LogCopyLineCount) -> Void)?
    var onCopyRecentLog: (() -> Void)?
    var onOpenLogFolder: (() -> Void)?
    var onCopyLastActionReport: (() -> Void)?
    var onCaptureSceneSnapshot: (() -> Void)?
    var onDumpWindowList: (() -> Void)?
    var onDumpAXWindows: (() -> Void)?
    var onToggleMissionControlGestureProbe: ((Bool) -> Void)?
    var onToggleInputEventProbe: ((Bool) -> Void)?

    private var lineCount: LogCopyLineCount
    private var missionControlGestureProbeEnabled: Bool
    private var inputEventProbeEnabled: Bool
    private var language: AppLanguage

    private var lineCountPopup: NSPopUpButton?
    private var mcProbeCheckbox: NSButton?
    private var inputProbeCheckbox: NSButton?

    init(
        lineCount: LogCopyLineCount,
        missionControlGestureProbeEnabled: Bool,
        inputEventProbeEnabled: Bool,
        language: AppLanguage
    ) {
        self.lineCount = lineCount
        self.missionControlGestureProbeEnabled = missionControlGestureProbeEnabled
        self.inputEventProbeEnabled = inputEventProbeEnabled
        self.language = language
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 580),
            styleMask: [.titled, .closable],
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

    func update(
        lineCount: LogCopyLineCount,
        missionControlGestureProbeEnabled: Bool,
        inputEventProbeEnabled: Bool,
        language: AppLanguage
    ) {
        let languageChanged = self.language != language
        self.lineCount = lineCount
        self.missionControlGestureProbeEnabled = missionControlGestureProbeEnabled
        self.inputEventProbeEnabled = inputEventProbeEnabled
        if languageChanged {
            self.language = language
            buildContent()
        } else {
            lineCountPopup?.selectItem(at: lineCountIndex(for: lineCount))
            mcProbeCheckbox?.state = missionControlGestureProbeEnabled ? .on : .off
            inputProbeCheckbox?.state = inputEventProbeEnabled ? .on : .off
        }
    }

    private func buildContent() {
        guard let window else {
            return
        }

        window.title = text(en: "Diagnostics", zh: "诊断面板")

        let root = NSView()
        root.translatesAutoresizingMaskIntoConstraints = false
        window.contentView = root

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 16
        stack.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -24),
            stack.topAnchor.constraint(equalTo: root.topAnchor, constant: 22),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: root.bottomAnchor, constant: -22)
        ])

        let title = NSTextField(labelWithString: text(en: "Diagnostics", zh: "诊断面板"))
        title.font = .systemFont(ofSize: 18, weight: .semibold)
        stack.addArrangedSubview(title)

        let intro = NSTextField(labelWithString: text(
            en: "Tools for capturing logs, reports, and runtime state — useful when reporting bugs.",
            zh: "用于抓取日志、操作报告和运行状态的工具。报 bug 时把这里的输出贴给开发者。"
        ))
        intro.font = .systemFont(ofSize: 11)
        intro.textColor = .secondaryLabelColor
        intro.maximumNumberOfLines = 2
        intro.preferredMaxLayoutWidth = 472
        stack.addArrangedSubview(intro)

        // Scene snapshot — full one-shot diagnostic
        stack.addArrangedSubview(sectionHeader(text(en: "📸 Capture scene", zh: "📸 捕获当前场景")))
        stack.addArrangedSubview(buildSceneSnapshotSection())

        stack.addArrangedSubview(separatorView())

        // Logs section
        stack.addArrangedSubview(sectionHeader(text(en: "📋 Logs", zh: "📋 日志")))
        stack.addArrangedSubview(buildLogSection())

        stack.addArrangedSubview(separatorView())

        // Recent action report
        stack.addArrangedSubview(sectionHeader(text(en: "📊 Last action report", zh: "📊 最近操作报告")))
        stack.addArrangedSubview(buildReportSection())

        stack.addArrangedSubview(separatorView())

        // System window scan
        stack.addArrangedSubview(sectionHeader(text(en: "🔍 System window scan", zh: "🔍 系统窗口扫描")))
        stack.addArrangedSubview(buildWindowDumpSection())

        stack.addArrangedSubview(separatorView())

        // Experimental probes
        stack.addArrangedSubview(sectionHeader(text(en: "🧪 Experimental probes", zh: "🧪 实验探针")))
        stack.addArrangedSubview(buildProbesSection())

        // Done button
        let doneButton = NSButton(title: text(en: "Done", zh: "完成"), target: self, action: #selector(doneTapped))
        doneButton.bezelStyle = .rounded
        doneButton.keyEquivalent = "\r"

        let bottomRow = NSStackView(views: [doneButton])
        bottomRow.orientation = .horizontal
        bottomRow.alignment = .centerY
        bottomRow.spacing = 8
        stack.addArrangedSubview(bottomRow)
    }

    private func buildSceneSnapshotSection() -> NSView {
        let container = NSStackView()
        container.orientation = .vertical
        container.alignment = .leading
        container.spacing = 6

        let hint = NSTextField(labelWithString: text(
            en: "One-shot dump of system, display, configuration, and every visible window — plus app bundle IDs and AX attributes. Paste this when reporting a layout bug.",
            zh: "一次性导出系统、屏幕、配置和当前所有窗口的详细信息（包含 App Bundle ID、AX 属性等）。报排版相关 bug 时把这段贴出来。"
        ))
        hint.font = .systemFont(ofSize: 11)
        hint.textColor = .secondaryLabelColor
        hint.maximumNumberOfLines = 3
        hint.preferredMaxLayoutWidth = 472
        container.addArrangedSubview(hint)

        let button = NSButton(
            title: text(en: "Capture scene to clipboard", zh: "捕获场景到剪贴板"),
            target: self,
            action: #selector(captureSceneTapped)
        )
        button.bezelStyle = .rounded
        container.addArrangedSubview(button)

        return container
    }

    private func buildLogSection() -> NSView {
        let container = NSStackView()
        container.orientation = .vertical
        container.alignment = .leading
        container.spacing = 8

        let pathLabel = NSTextField(labelWithString: text(
            en: "File: ~/Library/Logs/MissionSwipe/MissionSwipe.log",
            zh: "文件: ~/Library/Logs/MissionSwipe/MissionSwipe.log"
        ))
        pathLabel.font = .systemFont(ofSize: 11, weight: .regular)
        pathLabel.textColor = .secondaryLabelColor
        container.addArrangedSubview(pathLabel)

        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 10

        let label = NSTextField(labelWithString: text(en: "Copy", zh: "复制"))
        label.font = .systemFont(ofSize: 12, weight: .medium)
        row.addArrangedSubview(label)

        let popup = NSPopUpButton()
        for option in LogCopyLineCount.allCases {
            let labels = option.displayLabel
            popup.addItem(withTitle: language == .simplifiedChinese ? labels.zh : labels.en)
        }
        popup.selectItem(at: lineCountIndex(for: lineCount))
        popup.target = self
        popup.action = #selector(lineCountChanged(_:))
        popup.widthAnchor.constraint(equalToConstant: 160).isActive = true
        lineCountPopup = popup
        row.addArrangedSubview(popup)

        let copyButton = NSButton(title: text(en: "Copy now", zh: "立即复制"), target: self, action: #selector(copyLogTapped))
        copyButton.bezelStyle = .rounded
        row.addArrangedSubview(copyButton)

        let openButton = NSButton(title: text(en: "Reveal in Finder", zh: "在 Finder 中打开"), target: self, action: #selector(openLogFolderTapped))
        openButton.bezelStyle = .rounded
        row.addArrangedSubview(openButton)

        container.addArrangedSubview(row)
        return container
    }

    private func buildReportSection() -> NSView {
        let container = NSStackView()
        container.orientation = .vertical
        container.alignment = .leading
        container.spacing = 6

        let hint = NSTextField(labelWithString: text(
            en: "Detailed info from the most recent close or minimize action.",
            zh: "记录最近一次关闭或最小化操作的详细信息。"
        ))
        hint.font = .systemFont(ofSize: 11)
        hint.textColor = .secondaryLabelColor
        hint.maximumNumberOfLines = 2
        hint.preferredMaxLayoutWidth = 472
        container.addArrangedSubview(hint)

        let copyReportButton = NSButton(title: text(en: "Copy last report", zh: "复制最近报告"), target: self, action: #selector(copyReportTapped))
        copyReportButton.bezelStyle = .rounded
        container.addArrangedSubview(copyReportButton)

        return container
    }

    private func buildWindowDumpSection() -> NSView {
        let container = NSStackView()
        container.orientation = .vertical
        container.alignment = .leading
        container.spacing = 6

        let hint = NSTextField(labelWithString: text(
            en: "Dump every window currently visible. Run while Mission Control is open for the most useful data.",
            zh: "把当前所有窗口的状态导出来。Mission Control 打开时跑能拿到更完整的数据。"
        ))
        hint.font = .systemFont(ofSize: 11)
        hint.textColor = .secondaryLabelColor
        hint.maximumNumberOfLines = 2
        hint.preferredMaxLayoutWidth = 472
        container.addArrangedSubview(hint)

        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 10
        let dumpCG = NSButton(title: text(en: "Dump CG windows", zh: "导出 CG 窗口"), target: self, action: #selector(dumpCGTapped))
        dumpCG.bezelStyle = .rounded
        let dumpAX = NSButton(title: text(en: "Dump AX windows", zh: "导出 AX 窗口"), target: self, action: #selector(dumpAXTapped))
        dumpAX.bezelStyle = .rounded
        row.addArrangedSubview(dumpCG)
        row.addArrangedSubview(dumpAX)
        container.addArrangedSubview(row)
        return container
    }

    private func buildProbesSection() -> NSView {
        let container = NSStackView()
        container.orientation = .vertical
        container.alignment = .leading
        container.spacing = 8

        let warning = NSTextField(labelWithString: text(
            en: "Off by default. These can flood the log; only turn them on while reproducing a specific issue.",
            zh: "默认关闭。打开后日志会暴增,仅在重现特定问题时使用。"
        ))
        warning.font = .systemFont(ofSize: 11)
        warning.textColor = .secondaryLabelColor
        warning.maximumNumberOfLines = 2
        warning.preferredMaxLayoutWidth = 472
        container.addArrangedSubview(warning)

        let mc = NSButton(checkboxWithTitle: text(en: "Mission Control gesture probe", zh: "调度中心手势探针"), target: self, action: #selector(toggleMCProbe(_:)))
        mc.state = missionControlGestureProbeEnabled ? .on : .off
        mcProbeCheckbox = mc
        container.addArrangedSubview(mc)

        let mcHint = NSTextField(labelWithString: text(
            en: "Captures raw scroll events for gesture research.",
            zh: "捕获原始滚轮事件,用于研究手势识别。"
        ))
        mcHint.font = .systemFont(ofSize: 11)
        mcHint.textColor = .secondaryLabelColor
        container.addArrangedSubview(mcHint)

        let input = NSButton(checkboxWithTitle: text(en: "Input event probe", zh: "输入事件探针"), target: self, action: #selector(toggleInputProbe(_:)))
        input.state = inputEventProbeEnabled ? .on : .off
        inputProbeCheckbox = input
        container.addArrangedSubview(input)

        let inputHint = NSTextField(labelWithString: text(
            en: "Logs low-level keyboard / mouse events.",
            zh: "记录底层键盘 / 鼠标事件。"
        ))
        inputHint.font = .systemFont(ofSize: 11)
        inputHint.textColor = .secondaryLabelColor
        container.addArrangedSubview(inputHint)

        return container
    }

    private func sectionHeader(_ title: String) -> NSView {
        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 14, weight: .semibold)
        return label
    }

    private func separatorView() -> NSView {
        let line = NSBox()
        line.boxType = .separator
        line.translatesAutoresizingMaskIntoConstraints = false
        line.widthAnchor.constraint(equalToConstant: 472).isActive = true
        return line
    }

    private func text(en: String, zh: String) -> String {
        language == .simplifiedChinese ? zh : en
    }

    private func lineCountIndex(for value: LogCopyLineCount) -> Int {
        LogCopyLineCount.allCases.firstIndex(of: value) ?? 0
    }

    @objc private func lineCountChanged(_ sender: NSPopUpButton) {
        let index = sender.indexOfSelectedItem
        guard LogCopyLineCount.allCases.indices.contains(index) else {
            return
        }
        let value = LogCopyLineCount.allCases[index]
        lineCount = value
        onChangeRecentLogLineCount?(value)
    }

    @objc private func copyLogTapped() {
        onCopyRecentLog?()
    }

    @objc private func openLogFolderTapped() {
        onOpenLogFolder?()
    }

    @objc private func copyReportTapped() {
        onCopyLastActionReport?()
    }

    @objc private func captureSceneTapped() {
        onCaptureSceneSnapshot?()
    }

    @objc private func dumpCGTapped() {
        onDumpWindowList?()
    }

    @objc private func dumpAXTapped() {
        onDumpAXWindows?()
    }

    @objc private func toggleMCProbe(_ sender: NSButton) {
        let isEnabled = sender.state == .on
        missionControlGestureProbeEnabled = isEnabled
        onToggleMissionControlGestureProbe?(isEnabled)
    }

    @objc private func toggleInputProbe(_ sender: NSButton) {
        let isEnabled = sender.state == .on
        inputEventProbeEnabled = isEnabled
        onToggleInputEventProbe?(isEnabled)
    }

    @objc private func doneTapped() {
        window?.performClose(nil)
    }
}
