import AppKit

final class SmartFitCapacityWindowController: NSWindowController {
    var onProfileChanged: ((SmartFitCapacityProfile) -> Void)?
    var onResetToDefaults: (() -> Void)?

    private var profile: SmartFitCapacityProfile
    private var language: AppLanguage

    private enum FieldKey: String {
        case compact, laptop, desktop, large, huge
    }

    private var fields: [FieldKey: NSTextField] = [:]

    init(profile: SmartFitCapacityProfile, language: AppLanguage) {
        self.profile = profile
        self.language = language
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 420),
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

    func update(profile: SmartFitCapacityProfile, language: AppLanguage) {
        let languageChanged = self.language != language
        self.profile = profile
        if languageChanged {
            self.language = language
            buildContent()
        } else {
            fields[.compact]?.stringValue = String(profile.compact)
            fields[.laptop]?.stringValue = String(profile.laptop)
            fields[.desktop]?.stringValue = String(profile.desktop)
            fields[.large]?.stringValue = String(profile.large)
            fields[.huge]?.stringValue = String(profile.huge)
        }
    }

    private func buildContent() {
        guard let window else {
            return
        }

        fields.removeAll()
        window.title = text(en: "Smart Fit Capacities", zh: "Smart Fit 容量")

        let root = NSView()
        root.translatesAutoresizingMaskIntoConstraints = false
        window.contentView = root

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 14
        stack.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -24),
            stack.topAnchor.constraint(equalTo: root.topAnchor, constant: 22),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: root.bottomAnchor, constant: -22)
        ])

        let title = NSTextField(labelWithString: text(en: "Smart Fit Capacities", zh: "Smart Fit 容量"))
        title.font = .systemFont(ofSize: 18, weight: .semibold)
        stack.addArrangedSubview(title)

        let intro = NSTextField(labelWithString: text(
            en: "Smart Fit decides how many windows your screen can comfortably hold based on its physical size. Each row below sets the cap for one screen-size group.",
            zh: "Smart Fit 会根据显示屏物理尺寸决定一次能舒服铺多少个窗口。下面每一项对应一个屏幕尺寸段的上限。"
        ))
        intro.font = .systemFont(ofSize: 11)
        intro.textColor = .secondaryLabelColor
        intro.maximumNumberOfLines = 3
        intro.preferredMaxLayoutWidth = 412
        stack.addArrangedSubview(intro)

        stack.addArrangedSubview(capacityRow(
            label: text(en: "13\" – 15\" (compact laptops)", zh: "13\" – 15\"(小尺寸笔记本)"),
            value: profile.compact,
            key: .compact,
            hint: text(en: "MacBook Air, older 13\" MBP", zh: "MacBook Air、老款 13\" MBP")
        ))
        stack.addArrangedSubview(capacityRow(
            label: text(en: "16\" – 17\" (large laptops)", zh: "16\" – 17\"(大尺寸笔记本)"),
            value: profile.laptop,
            key: .laptop,
            hint: text(en: "MacBook Pro 14\"/16\"", zh: "MacBook Pro 14\"/16\"")
        ))
        stack.addArrangedSubview(capacityRow(
            label: text(en: "21\" – 24\" (small desktops)", zh: "21\" – 24\"(小桌面显示器)"),
            value: profile.desktop,
            key: .desktop,
            hint: text(en: "iMac 21.5\", 24\" external", zh: "iMac 21.5\"、24\" 外接")
        ))
        stack.addArrangedSubview(capacityRow(
            label: text(en: "25\" – 29\" (standard 27\")", zh: "25\" – 29\"(常见 27\")"),
            value: profile.large,
            key: .large,
            hint: text(en: "Studio Display, LG 27\"", zh: "Studio Display、LG 27\" 等")
        ))
        stack.addArrangedSubview(capacityRow(
            label: text(en: "30\"+ (large / ultrawide)", zh: "30\" 以上(大屏 / 超宽屏)"),
            value: profile.huge,
            key: .huge,
            hint: text(en: "32\" 4K, 38-49\" ultrawide", zh: "32\" 4K、38-49\" 超宽屏")
        ))

        let buttonRow = NSStackView()
        buttonRow.orientation = .horizontal
        buttonRow.alignment = .centerY
        buttonRow.spacing = 8

        let resetButton = NSButton(title: text(en: "Reset to defaults", zh: "恢复默认"), target: self, action: #selector(resetTapped))
        resetButton.bezelStyle = .rounded

        let doneButton = NSButton(title: text(en: "Done", zh: "完成"), target: self, action: #selector(doneTapped))
        doneButton.bezelStyle = .rounded
        doneButton.keyEquivalent = "\r"

        buttonRow.addArrangedSubview(resetButton)
        buttonRow.addArrangedSubview(doneButton)

        stack.addArrangedSubview(buttonRow)
    }

    private func capacityRow(label: String, value: Int, key: FieldKey, hint: String) -> NSView {
        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 12

        let labelStack = NSStackView()
        labelStack.orientation = .vertical
        labelStack.alignment = .leading
        labelStack.spacing = 1

        let titleLabel = NSTextField(labelWithString: label)
        titleLabel.font = .systemFont(ofSize: 13, weight: .medium)
        labelStack.addArrangedSubview(titleLabel)

        let hintLabel = NSTextField(labelWithString: hint)
        hintLabel.font = .systemFont(ofSize: 11)
        hintLabel.textColor = .secondaryLabelColor
        labelStack.addArrangedSubview(hintLabel)

        labelStack.widthAnchor.constraint(equalToConstant: 280).isActive = true
        row.addArrangedSubview(labelStack)

        let stepper = NSStepper()
        stepper.minValue = 1
        stepper.maxValue = 30
        stepper.increment = 1
        stepper.valueWraps = false
        stepper.target = self
        stepper.action = #selector(stepperChanged(_:))
        stepper.intValue = Int32(value)
        stepper.identifier = NSUserInterfaceItemIdentifier("stepper-\(key.rawValue)")

        let field = NSTextField()
        field.stringValue = String(value)
        field.alignment = .center
        field.font = .systemFont(ofSize: 13, weight: .medium)
        field.widthAnchor.constraint(equalToConstant: 56).isActive = true
        field.target = self
        field.action = #selector(fieldCommitted(_:))
        field.identifier = NSUserInterfaceItemIdentifier(key.rawValue)
        let formatter = NumberFormatter()
        formatter.minimum = 1
        formatter.maximum = 30
        formatter.allowsFloats = false
        field.formatter = formatter
        fields[key] = field

        row.addArrangedSubview(field)
        row.addArrangedSubview(stepper)

        return row
    }

    private func text(en: String, zh: String) -> String {
        language == .simplifiedChinese ? zh : en
    }

    private func currentProfileFromFields() -> SmartFitCapacityProfile {
        SmartFitCapacityProfile(
            compact: clampedValue(fields[.compact], fallback: profile.compact),
            laptop: clampedValue(fields[.laptop], fallback: profile.laptop),
            desktop: clampedValue(fields[.desktop], fallback: profile.desktop),
            large: clampedValue(fields[.large], fallback: profile.large),
            huge: clampedValue(fields[.huge], fallback: profile.huge)
        )
    }

    private func clampedValue(_ field: NSTextField?, fallback: Int) -> Int {
        let raw = field?.integerValue ?? fallback
        return min(max(raw, 1), 30)
    }

    @objc private func fieldCommitted(_ sender: NSTextField) {
        let new = currentProfileFromFields()
        profile = new
        sender.stringValue = String(clampedValue(sender, fallback: 1))
        onProfileChanged?(new)
    }

    @objc private func stepperChanged(_ sender: NSStepper) {
        guard let rawId = sender.identifier?.rawValue,
              rawId.hasPrefix("stepper-"),
              let key = FieldKey(rawValue: String(rawId.dropFirst("stepper-".count))) else {
            return
        }
        fields[key]?.stringValue = String(sender.intValue)
        let new = currentProfileFromFields()
        profile = new
        onProfileChanged?(new)
    }

    @objc private func resetTapped() {
        let new = SmartFitCapacityProfile.default
        profile = new
        fields[.compact]?.stringValue = String(new.compact)
        fields[.laptop]?.stringValue = String(new.laptop)
        fields[.desktop]?.stringValue = String(new.desktop)
        fields[.large]?.stringValue = String(new.large)
        fields[.huge]?.stringValue = String(new.huge)
        onResetToDefaults?()
        onProfileChanged?(new)
    }

    @objc private func doneTapped() {
        window?.performClose(nil)
    }
}
