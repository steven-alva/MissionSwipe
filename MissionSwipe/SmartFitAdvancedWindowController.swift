import AppKit

final class SmartFitAdvancedWindowController: NSWindowController {
    var onStrategyChanged: ((SmartFitOverflowStrategy) -> Void)?
    var onToleranceChanged: ((Double) -> Void)?
    var onThreeWindowLayoutChanged: ((ThreeWindowLayout) -> Void)?
    var onFourWindowLayoutChanged: ((FourWindowLayout) -> Void)?
    var onFiveWindowLayoutChanged: ((FiveWindowLayout) -> Void)?

    private var strategy: SmartFitOverflowStrategy
    private var tolerance: Double
    private var threeWindowLayout: ThreeWindowLayout
    private var fourWindowLayout: FourWindowLayout
    private var fiveWindowLayout: FiveWindowLayout
    private var language: AppLanguage

    private var strategyButtons: [SmartFitOverflowStrategy: NSButton] = [:]
    private var toleranceSlider: NSSlider?
    private var toleranceLabel: NSTextField?
    private var threeLayoutButtons: [ThreeWindowLayout: LayoutThumbnailButton] = [:]
    private var fourLayoutButtons: [FourWindowLayout: LayoutThumbnailButton] = [:]
    private var fiveLayoutButtons: [FiveWindowLayout: LayoutThumbnailButton] = [:]

    init(
        strategy: SmartFitOverflowStrategy,
        tolerance: Double,
        threeWindowLayout: ThreeWindowLayout,
        fourWindowLayout: FourWindowLayout,
        fiveWindowLayout: FiveWindowLayout,
        language: AppLanguage
    ) {
        self.strategy = strategy
        self.tolerance = tolerance
        self.threeWindowLayout = threeWindowLayout
        self.fourWindowLayout = fourWindowLayout
        self.fiveWindowLayout = fiveWindowLayout
        self.language = language
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 780),
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
        strategy: SmartFitOverflowStrategy,
        tolerance: Double,
        threeWindowLayout: ThreeWindowLayout,
        fourWindowLayout: FourWindowLayout,
        fiveWindowLayout: FiveWindowLayout,
        language: AppLanguage
    ) {
        let languageChanged = self.language != language
        self.strategy = strategy
        self.tolerance = tolerance
        self.threeWindowLayout = threeWindowLayout
        self.fourWindowLayout = fourWindowLayout
        self.fiveWindowLayout = fiveWindowLayout
        if languageChanged {
            self.language = language
            buildContent()
        } else {
            for (key, button) in strategyButtons {
                button.state = key == strategy ? .on : .off
            }
            toleranceSlider?.doubleValue = tolerance * 100
            toleranceLabel?.stringValue = formatTolerance(tolerance)
            refreshLayoutSelections()
        }
    }

    private func buildContent() {
        guard let window else {
            return
        }

        strategyButtons.removeAll()
        threeLayoutButtons.removeAll()
        fourLayoutButtons.removeAll()
        fiveLayoutButtons.removeAll()
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

        // Overflow strategy section
        let strategyHeader = sectionHeader(text(en: "Overflow strategy", zh: "溢出策略"))
        stack.addArrangedSubview(strategyHeader)

        let strategyIntro = NSTextField(labelWithString: text(
            en: "How should Smart Fit handle windows that don't all fit on screen?",
            zh: "当窗口无法一次性干净铺下时,Smart Fit 应该怎么处理?"
        ))
        strategyIntro.font = .systemFont(ofSize: 11)
        strategyIntro.textColor = .secondaryLabelColor
        strategyIntro.maximumNumberOfLines = 2
        strategyIntro.preferredMaxLayoutWidth = 512
        stack.addArrangedSubview(strategyIntro)

        let strategyGroup = NSStackView()
        strategyGroup.orientation = .vertical
        strategyGroup.alignment = .leading
        strategyGroup.spacing = 8
        for option in SmartFitOverflowStrategy.allCases {
            strategyGroup.addArrangedSubview(buildStrategyRow(option))
        }
        stack.addArrangedSubview(strategyGroup)

        stack.addArrangedSubview(separatorView())
        stack.addArrangedSubview(buildToleranceSection())

        stack.addArrangedSubview(separatorView())

        // Layout style section
        stack.addArrangedSubview(sectionHeader(text(en: "Layout styles", zh: "布局样式")))
        let layoutIntro = NSTextField(labelWithString: text(
            en: "Pick the layout for 3 / 4 / 5 visible windows.",
            zh: "为 3 / 4 / 5 个可见窗口分别挑选布局。"
        ))
        layoutIntro.font = .systemFont(ofSize: 11)
        layoutIntro.textColor = .secondaryLabelColor
        layoutIntro.maximumNumberOfLines = 2
        layoutIntro.preferredMaxLayoutWidth = 512
        stack.addArrangedSubview(layoutIntro)

        stack.addArrangedSubview(buildThreeLayoutPicker())
        stack.addArrangedSubview(buildFourLayoutPicker())
        stack.addArrangedSubview(buildFiveLayoutPicker())

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
        detail.preferredMaxLayoutWidth = 492
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
        hint.preferredMaxLayoutWidth = 512
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
        slider.widthAnchor.constraint(equalToConstant: 320).isActive = true
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

    private func buildThreeLayoutPicker() -> NSView {
        return buildLayoutPickerRow(
            title: text(en: "3 windows", zh: "3 窗口布局"),
            options: ThreeWindowLayout.allCases.map { option in
                LayoutPickerOption(
                    id: option.rawValue,
                    title: language == .simplifiedChinese ? option.displayLabel.zh : option.displayLabel.en,
                    frames: option.thumbnailFrames,
                    isSelected: option == threeWindowLayout
                )
            },
            action: { [weak self] id in
                guard let self, let option = ThreeWindowLayout(rawValue: id) else { return }
                self.threeWindowLayout = option
                self.refreshLayoutSelections()
                self.onThreeWindowLayoutChanged?(option)
            },
            registerButton: { [weak self] id, button in
                if let option = ThreeWindowLayout(rawValue: id) {
                    self?.threeLayoutButtons[option] = button
                }
            }
        )
    }

    private func buildFourLayoutPicker() -> NSView {
        return buildLayoutPickerRow(
            title: text(en: "4 windows", zh: "4 窗口布局"),
            options: FourWindowLayout.allCases.map { option in
                LayoutPickerOption(
                    id: option.rawValue,
                    title: language == .simplifiedChinese ? option.displayLabel.zh : option.displayLabel.en,
                    frames: option.thumbnailFrames,
                    isSelected: option == fourWindowLayout
                )
            },
            action: { [weak self] id in
                guard let self, let option = FourWindowLayout(rawValue: id) else { return }
                self.fourWindowLayout = option
                self.refreshLayoutSelections()
                self.onFourWindowLayoutChanged?(option)
            },
            registerButton: { [weak self] id, button in
                if let option = FourWindowLayout(rawValue: id) {
                    self?.fourLayoutButtons[option] = button
                }
            }
        )
    }

    private func buildFiveLayoutPicker() -> NSView {
        return buildLayoutPickerRow(
            title: text(en: "5 windows", zh: "5 窗口布局"),
            options: FiveWindowLayout.allCases.map { option in
                LayoutPickerOption(
                    id: option.rawValue,
                    title: language == .simplifiedChinese ? option.displayLabel.zh : option.displayLabel.en,
                    frames: option.thumbnailFrames,
                    isSelected: option == fiveWindowLayout
                )
            },
            action: { [weak self] id in
                guard let self, let option = FiveWindowLayout(rawValue: id) else { return }
                self.fiveWindowLayout = option
                self.refreshLayoutSelections()
                self.onFiveWindowLayoutChanged?(option)
            },
            registerButton: { [weak self] id, button in
                if let option = FiveWindowLayout(rawValue: id) {
                    self?.fiveLayoutButtons[option] = button
                }
            }
        )
    }

    private func buildLayoutPickerRow(
        title: String,
        options: [LayoutPickerOption],
        action: @escaping (String) -> Void,
        registerButton: (String, LayoutThumbnailButton) -> Void
    ) -> NSView {
        let container = NSStackView()
        container.orientation = .vertical
        container.alignment = .leading
        container.spacing = 6

        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = .systemFont(ofSize: 13, weight: .medium)
        container.addArrangedSubview(titleLabel)

        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .top
        row.spacing = 12
        for option in options {
            let button = LayoutThumbnailButton(option: option)
            button.onSelect = action
            registerButton(option.id, button)
            row.addArrangedSubview(button)
        }
        container.addArrangedSubview(row)
        return container
    }

    private func refreshLayoutSelections() {
        for (key, button) in threeLayoutButtons {
            button.setSelected(key == threeWindowLayout)
        }
        for (key, button) in fourLayoutButtons {
            button.setSelected(key == fourWindowLayout)
        }
        for (key, button) in fiveLayoutButtons {
            button.setSelected(key == fiveWindowLayout)
        }
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
        line.widthAnchor.constraint(equalToConstant: 512).isActive = true
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

// MARK: - Layout thumbnail components

struct LayoutPickerOption {
    let id: String
    let title: String
    /// Normalized frames in 0..1 with top-left origin.
    let frames: [CGRect]
    let isSelected: Bool
}

final class LayoutThumbnailButton: NSView {
    var onSelect: ((String) -> Void)?

    private let optionID: String
    private let frames: [CGRect]
    private let titleLabel: NSTextField
    private let thumbnailView: LayoutThumbnailView
    private var isHovering = false

    init(option: LayoutPickerOption) {
        optionID = option.id
        frames = option.frames
        thumbnailView = LayoutThumbnailView(frames: option.frames)
        titleLabel = NSTextField(labelWithString: option.title)
        super.init(frame: .zero)
        thumbnailView.isSelected = option.isSelected

        thumbnailView.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.font = .systemFont(ofSize: 11, weight: .medium)
        titleLabel.alignment = .center
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.preferredMaxLayoutWidth = 140
        titleLabel.lineBreakMode = .byWordWrapping
        titleLabel.maximumNumberOfLines = 2
        titleLabel.textColor = option.isSelected ? .controlAccentColor : .labelColor

        addSubview(thumbnailView)
        addSubview(titleLabel)

        NSLayoutConstraint.activate([
            thumbnailView.topAnchor.constraint(equalTo: topAnchor),
            thumbnailView.leadingAnchor.constraint(equalTo: leadingAnchor),
            thumbnailView.trailingAnchor.constraint(equalTo: trailingAnchor),
            thumbnailView.widthAnchor.constraint(equalToConstant: 140),
            thumbnailView.heightAnchor.constraint(equalToConstant: 80),
            titleLabel.topAnchor.constraint(equalTo: thumbnailView.bottomAnchor, constant: 4),
            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor),
            titleLabel.trailingAnchor.constraint(equalTo: trailingAnchor),
            titleLabel.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])

        let tracking = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(tracking)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    func setSelected(_ selected: Bool) {
        thumbnailView.isSelected = selected
        titleLabel.textColor = selected ? .controlAccentColor : .labelColor
        thumbnailView.needsDisplay = true
    }

    override func mouseDown(with event: NSEvent) {
        onSelect?(optionID)
    }

    override func mouseEntered(with event: NSEvent) {
        isHovering = true
        thumbnailView.isHovering = true
        thumbnailView.needsDisplay = true
    }

    override func mouseExited(with event: NSEvent) {
        isHovering = false
        thumbnailView.isHovering = false
        thumbnailView.needsDisplay = true
    }
}

final class LayoutThumbnailView: NSView {
    var frames: [CGRect]
    var isSelected: Bool = false
    var isHovering: Bool = false

    init(frames: [CGRect]) {
        self.frames = frames
        super.init(frame: .zero)
        wantsLayer = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        let bgColor: NSColor
        if isSelected {
            bgColor = NSColor.controlAccentColor.withAlphaComponent(0.15)
        } else if isHovering {
            bgColor = NSColor.controlBackgroundColor.blended(withFraction: 0.5, of: .systemGray) ?? .controlBackgroundColor
        } else {
            bgColor = .controlBackgroundColor
        }

        let bgPath = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 6, yRadius: 6)
        bgColor.setFill()
        bgPath.fill()

        let borderColor: NSColor = isSelected ? .controlAccentColor : NSColor.systemGray.withAlphaComponent(0.3)
        borderColor.setStroke()
        bgPath.lineWidth = isSelected ? 2 : 1
        bgPath.stroke()

        let inset: CGFloat = 8
        let drawArea = bounds.insetBy(dx: inset, dy: inset)

        let windowFill: NSColor = isSelected
            ? NSColor.controlAccentColor.withAlphaComponent(0.65)
            : NSColor.systemGray.withAlphaComponent(0.55)
        windowFill.setFill()

        for f in frames {
            let rect = NSRect(
                x: drawArea.minX + f.minX * drawArea.width,
                y: drawArea.minY + f.minY * drawArea.height,
                width: f.width * drawArea.width,
                height: f.height * drawArea.height
            ).insetBy(dx: 1.5, dy: 1.5)
            NSBezierPath(roundedRect: rect, xRadius: 2, yRadius: 2).fill()
        }
    }
}
