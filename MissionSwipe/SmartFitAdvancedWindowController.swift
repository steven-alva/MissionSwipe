import AppKit

final class SmartFitAdvancedWindowController: NSWindowController {
    var onStrategyChanged: ((SmartFitOverflowStrategy) -> Void)?
    var onToleranceChanged: ((Double) -> Void)?

    private var strategy: SmartFitOverflowStrategy
    private var tolerance: Double
    private var language: AppLanguage

    private var strategyButtons: [SmartFitOverflowStrategy: NSButton] = [:]
    private var toleranceSlider: NSSlider?
    private var toleranceLabel: NSTextField?

    init(strategy: SmartFitOverflowStrategy, tolerance: Double, language: AppLanguage) {
        self.strategy = strategy
        self.tolerance = tolerance
        self.language = language
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 480),
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

    func update(strategy: SmartFitOverflowStrategy, tolerance: Double, language: AppLanguage) {
        let languageChanged = self.language != language
        self.strategy = strategy
        self.tolerance = tolerance
        if languageChanged {
            self.language = language
            buildContent()
        } else {
            for (key, button) in strategyButtons {
                button.state = key == strategy ? .on : .off
            }
            toleranceSlider?.doubleValue = tolerance * 100
            toleranceLabel?.stringValue = formatTolerance(tolerance)
        }
    }

    private func buildContent() {
        guard let window else {
            return
        }

        strategyButtons.removeAll()
        window.title = text(en: "Smart Fit Advanced", zh: "Smart Fit 高级设置")

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

        let title = NSTextField(labelWithString: text(en: "Smart Fit Advanced", zh: "Smart Fit 高级设置"))
        title.font = .systemFont(ofSize: 18, weight: .semibold)
        stack.addArrangedSubview(title)

        let intro = NSTextField(labelWithString: text(
            en: "How should Smart Fit handle windows that don't all fit on screen?",
            zh: "当窗口无法一次性干净铺下时,Smart Fit 应该怎么处理?"
        ))
        intro.font = .systemFont(ofSize: 12)
        intro.textColor = .secondaryLabelColor
        intro.maximumNumberOfLines = 2
        intro.preferredMaxLayoutWidth = 472
        stack.addArrangedSubview(intro)

        // Strategy radio rows
        let group = NSStackView()
        group.orientation = .vertical
        group.alignment = .leading
        group.spacing = 10

        for option in SmartFitOverflowStrategy.allCases {
            group.addArrangedSubview(buildStrategyRow(option))
        }
        stack.addArrangedSubview(group)

        // Tolerance slider section
        stack.addArrangedSubview(separatorView())
        stack.addArrangedSubview(buildToleranceSection())

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

    private func buildStrategyRow(_ option: SmartFitOverflowStrategy) -> NSView {
        let container = NSStackView()
        container.orientation = .vertical
        container.alignment = .leading
        container.spacing = 2

        let labels = option.displayLabel
        let radio = NSButton(radioButtonWithTitle: language == .simplifiedChinese ? labels.zh : labels.en, target: self, action: #selector(strategyChanged(_:)))
        radio.identifier = NSUserInterfaceItemIdentifier(option.rawValue)
        radio.state = option == strategy ? .on : .off
        radio.font = .systemFont(ofSize: 13, weight: .medium)
        strategyButtons[option] = radio
        container.addArrangedSubview(radio)

        let details = option.detailText
        let detail = NSTextField(labelWithString: language == .simplifiedChinese ? details.zh : details.en)
        detail.font = .systemFont(ofSize: 11)
        detail.textColor = .secondaryLabelColor
        detail.maximumNumberOfLines = 3
        detail.preferredMaxLayoutWidth = 452
        container.addArrangedSubview(detail)

        return container
    }

    private func buildToleranceSection() -> NSView {
        let container = NSStackView()
        container.orientation = .vertical
        container.alignment = .leading
        container.spacing = 6

        let title = NSTextField(labelWithString: text(en: "Overlap tolerance", zh: "重叠容忍度"))
        title.font = .systemFont(ofSize: 13, weight: .medium)
        container.addArrangedSubview(title)

        let hint = NSTextField(labelWithString: text(
            en: "Windows that overlap below this amount are considered fine. Higher = fewer windows minimized.",
            zh: "重叠占小窗口面积低于这个比例都算可接受。越高 = 越少窗口被收纳。"
        ))
        hint.font = .systemFont(ofSize: 11)
        hint.textColor = .secondaryLabelColor
        hint.maximumNumberOfLines = 2
        hint.preferredMaxLayoutWidth = 452
        container.addArrangedSubview(hint)

        let sliderRow = NSStackView()
        sliderRow.orientation = .horizontal
        sliderRow.alignment = .centerY
        sliderRow.spacing = 10

        let minLabel = NSTextField(labelWithString: "6%")
        minLabel.font = .systemFont(ofSize: 11)
        minLabel.textColor = .secondaryLabelColor

        let slider = NSSlider(
            value: tolerance * 100,
            minValue: 6,
            maxValue: 50,
            target: self,
            action: #selector(toleranceChanged(_:))
        )
        slider.isContinuous = true
        slider.allowsTickMarkValuesOnly = false
        slider.numberOfTickMarks = 5
        slider.tickMarkPosition = .below
        slider.widthAnchor.constraint(equalToConstant: 280).isActive = true
        toleranceSlider = slider

        let maxLabel = NSTextField(labelWithString: "50%")
        maxLabel.font = .systemFont(ofSize: 11)
        maxLabel.textColor = .secondaryLabelColor

        let valueLabel = NSTextField(labelWithString: formatTolerance(tolerance))
        valueLabel.font = .systemFont(ofSize: 12, weight: .semibold)
        valueLabel.widthAnchor.constraint(equalToConstant: 60).isActive = true
        toleranceLabel = valueLabel

        sliderRow.addArrangedSubview(minLabel)
        sliderRow.addArrangedSubview(slider)
        sliderRow.addArrangedSubview(maxLabel)
        sliderRow.addArrangedSubview(valueLabel)
        container.addArrangedSubview(sliderRow)

        return container
    }

    private func separatorView() -> NSView {
        let line = NSBox()
        line.boxType = .separator
        line.translatesAutoresizingMaskIntoConstraints = false
        line.widthAnchor.constraint(equalToConstant: 472).isActive = true
        return line
    }

    private func formatTolerance(_ value: Double) -> String {
        let percent = Int(round(value * 100))
        return "\(percent)%"
    }

    private func text(en: String, zh: String) -> String {
        language == .simplifiedChinese ? zh : en
    }

    @objc private func strategyChanged(_ sender: NSButton) {
        guard let raw = sender.identifier?.rawValue,
              let option = SmartFitOverflowStrategy(rawValue: raw) else {
            return
        }
        strategy = option
        for (key, button) in strategyButtons {
            button.state = key == option ? .on : .off
        }
        onStrategyChanged?(option)
    }

    @objc private func toleranceChanged(_ sender: NSSlider) {
        let value = max(0.06, min(0.50, sender.doubleValue / 100))
        tolerance = value
        toleranceLabel?.stringValue = formatTolerance(value)
        onToleranceChanged?(value)
    }

    @objc private func doneTapped() {
        window?.performClose(nil)
    }
}
