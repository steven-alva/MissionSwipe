import AppKit

final class LayoutPreviewHUDController {
    private enum Constants {
        static let size = CGSize(width: 258, height: 164)
        static let mouseOffset: CGFloat = 38
        static let edgePadding: CGFloat = 12
    }

    private let panel: NSPanel
    private let previewView = LayoutPreviewHUDView()
    private var hideWorkItem: DispatchWorkItem?
    private var language: AppLanguage

    init(language: AppLanguage = AppConfiguration.shared.language) {
        self.language = language
        panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: Constants.size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.level = .screenSaver
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        previewView.language = language
        panel.contentView = previewView
    }

    func updateLanguage(_ language: AppLanguage) {
        guard self.language != language else {
            return
        }
        self.language = language
        previewView.language = language
        previewView.needsDisplay = true
    }

    func show(
        placement: WindowArranger.PrimaryPlacement,
        windowCount: Int,
        duration: TimeInterval = 1.1,
        progress: CGFloat = 1,
        isConfirmed: Bool = true,
        shouldReposition: Bool = true
    ) {
        DispatchQueue.main.async { [weak self] in
            guard let self else {
                return
            }

            self.hideWorkItem?.cancel()
            let clampedWindowCount = max(1, windowCount)
            let shouldReveal = !self.panel.isVisible ||
                self.previewView.placement != placement ||
                self.previewView.windowCount != clampedWindowCount

            self.previewView.placement = placement
            self.previewView.windowCount = clampedWindowCount
            self.previewView.confirmationProgress = min(1, max(0, progress))
            self.previewView.isConfirmed = isConfirmed
            if shouldReveal {
                self.previewView.triggerReveal()
            } else {
                self.previewView.needsDisplay = true
            }

            if shouldReposition || !self.panel.isVisible {
                self.panel.setFrame(self.frameNearMouse(), display: true)
            }
            self.panel.alphaValue = 1
            self.panel.orderFrontRegardless()

            let workItem = DispatchWorkItem { [weak self] in
                self?.panel.orderOut(nil)
            }
            self.hideWorkItem = workItem
            DispatchQueue.main.asyncAfter(deadline: .now() + duration, execute: workItem)
        }
    }

    func hide() {
        DispatchQueue.main.async { [weak self] in
            self?.hideWorkItem?.cancel()
            self?.panel.orderOut(nil)
        }
    }

    private func frameNearMouse() -> NSRect {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
        let visibleFrame = screen?.visibleFrame ?? NSRect(origin: .zero, size: NSScreen.main?.frame.size ?? Constants.size)

        var x = mouse.x - Constants.size.width / 2
        var y = mouse.y + Constants.mouseOffset

        if y + Constants.size.height > visibleFrame.maxY - Constants.edgePadding {
            y = mouse.y - Constants.size.height - Constants.mouseOffset
        }

        x = min(max(x, visibleFrame.minX + Constants.edgePadding), visibleFrame.maxX - Constants.size.width - Constants.edgePadding)
        y = min(max(y, visibleFrame.minY + Constants.edgePadding), visibleFrame.maxY - Constants.size.height - Constants.edgePadding)

        return NSRect(x: x, y: y, width: Constants.size.width, height: Constants.size.height)
    }
}

private final class LayoutPreviewHUDView: NSView {
    private enum Constants {
        static let hudRect = NSRect(x: 10, y: 10, width: 238, height: 144)
        static let cornerRadius: CGFloat = 20
        static let screenRect = NSRect(x: 26, y: 46, width: 206, height: 82)
    }

    var placement: WindowArranger.PrimaryPlacement = .left
    var windowCount: Int = 4
    var confirmationProgress: CGFloat = 1
    var isConfirmed: Bool = true
    var language: AppLanguage = AppConfiguration.shared.language
    private var revealProgress: CGFloat = 0
    private var revealTimer: Timer?

    override var isFlipped: Bool {
        true
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        let hudPath = NSBezierPath(
            roundedRect: Constants.hudRect,
            xRadius: Constants.cornerRadius,
            yRadius: Constants.cornerRadius
        )

        drawShell(path: hudPath)
        drawHeader(in: Constants.hudRect)
        drawPreview(in: Constants.screenRect)
        drawConfirmationProgress(in: Constants.hudRect)
    }

    func triggerReveal() {
        revealTimer?.invalidate()
        revealProgress = 0
        needsDisplay = true

        let startedAt = Date()
        let timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60.0, repeats: true) { [weak self] timer in
            guard let self else {
                timer.invalidate()
                return
            }

            let elapsed = Date().timeIntervalSince(startedAt)
            self.revealProgress = min(1, CGFloat(elapsed / 0.34))
            self.needsDisplay = true
            if self.revealProgress >= 1 {
                timer.invalidate()
                self.revealTimer = nil
            }
        }
        revealTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func drawShell(path: NSBezierPath) {
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowOffset = .zero
        shadow.shadowBlurRadius = 18
        shadow.shadowColor = NSColor.white.withAlphaComponent(0.13)
        shadow.set()
        NSColor.black.withAlphaComponent(0.08).setFill()
        path.fill()
        NSGraphicsContext.restoreGraphicsState()

        NSColor.black.withAlphaComponent(0.78).setFill()
        path.fill()
        NSColor.white.withAlphaComponent(0.24).setStroke()
        path.lineWidth = 1
        path.stroke()
    }

    private func drawHeader(in rect: NSRect) {
        let titleAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 13, weight: .semibold),
            .foregroundColor: NSColor.white.withAlphaComponent(0.96)
        ]
        text(en: "Layout Preview", zh: "排版预览").draw(
            at: NSPoint(x: rect.minX + 18, y: rect.minY + 16),
            withAttributes: titleAttributes
        )

        let labelAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11, weight: .medium),
            .foregroundColor: NSColor.white.withAlphaComponent(0.58)
        ]
        headerDetail.draw(
            at: NSPoint(x: rect.maxX - 18 - headerDetailSize.width, y: rect.minY + 18),
            withAttributes: labelAttributes
        )
    }

    private var placementLabel: NSString {
        switch placement {
        case .left:
            return text(en: "Left primary", zh: "左侧主排") as NSString
        case .right:
            return text(en: "Right primary", zh: "右侧主排") as NSString
        case .topLeft:
            return text(en: "Top-left primary", zh: "左上主排") as NSString
        case .topRight:
            return text(en: "Top-right primary", zh: "右上主排") as NSString
        case .bottomLeft:
            return text(en: "Bottom-left primary", zh: "左下主排") as NSString
        case .bottomRight:
            return text(en: "Bottom-right primary", zh: "右下主排") as NSString
        }
    }

    private var headerDetail: NSString {
        text(en: "\(placementLabel) · \(windowCount) windows", zh: "\(placementLabel) · \(windowCount) 窗口") as NSString
    }

    private var headerDetailSize: CGSize {
        headerDetail.size(withAttributes: [
            .font: NSFont.systemFont(ofSize: 11, weight: .medium)
        ])
    }

    private func drawPreview(in screenRect: NSRect) {
        let screenPath = NSBezierPath(roundedRect: screenRect, xRadius: 10, yRadius: 10)
        NSColor.white.withAlphaComponent(0.08).setFill()
        screenPath.fill()
        NSColor.white.withAlphaComponent(0.17).setStroke()
        screenPath.lineWidth = 1
        screenPath.stroke()

        let gap: CGFloat = 5
        let blocks = previewBlocks(in: screenRect.insetBy(dx: 8, dy: 8), gap: gap)
        for block in blocks.secondary {
            drawBlock(block, alpha: 0.28, corner: 5)
        }
        drawBlock(blocks.primary, alpha: 0.92, corner: 6)
    }

    private func drawConfirmationProgress(in rect: NSRect) {
        let progress = min(1, max(0, confirmationProgress))
        let trackRect = NSRect(x: rect.minX + 22, y: rect.maxY - 18, width: rect.width - 44, height: 4)
        let trackPath = NSBezierPath(roundedRect: trackRect, xRadius: 2, yRadius: 2)
        NSColor.white.withAlphaComponent(0.14).setFill()
        trackPath.fill()

        guard progress > 0 else {
            drawConfirmationLabel(in: rect, text: text(en: "slide to confirm", zh: "滑满确认"))
            return
        }

        let fillRect = NSRect(
            x: trackRect.minX,
            y: trackRect.minY,
            width: max(6, trackRect.width * progress),
            height: trackRect.height
        )
        let fillPath = NSBezierPath(roundedRect: fillRect, xRadius: 2, yRadius: 2)
        NSColor.white.withAlphaComponent(isConfirmed ? 0.94 : 0.72).setFill()
        fillPath.fill()

        drawConfirmationLabel(
            in: rect,
            text: isConfirmed
                ? text(en: "release to apply", zh: "释放后生效")
                : text(en: "slide to confirm", zh: "滑满确认")
        )
    }

    private func drawConfirmationLabel(in rect: NSRect, text: String) {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 10, weight: .medium),
            .foregroundColor: NSColor.white.withAlphaComponent(0.50)
        ]
        let label = text as NSString
        let size = label.size(withAttributes: attributes)
        label.draw(
            at: NSPoint(x: rect.midX - size.width / 2, y: rect.maxY - 35),
            withAttributes: attributes
        )
    }

    private func drawBlock(_ rect: NSRect, alpha: CGFloat, corner: CGFloat) {
        let easedProgress = easeOutCubic(revealProgress)
        let scale = 0.94 + 0.06 * easedProgress
        let width = rect.width * scale
        let height = rect.height * scale
        let scaledRect = NSRect(
            x: rect.midX - width / 2,
            y: rect.midY - height / 2,
            width: width,
            height: height
        )

        let path = NSBezierPath(roundedRect: scaledRect, xRadius: corner, yRadius: corner)
        NSColor.white.withAlphaComponent(alpha * easedProgress).setFill()
        path.fill()

        if alpha > 0.8 {
            NSColor.white.withAlphaComponent(0.38 * easedProgress).setStroke()
            path.lineWidth = 1
            path.stroke()
        }
    }

    private func previewBlocks(in rect: NSRect, gap: CGFloat) -> (primary: NSRect, secondary: [NSRect]) {
        let secondaryCount = max(0, windowCount - 1)
        switch placement {
        case .left:
            let primaryWidth = floor((rect.width - gap) * 0.50)
            let primary = NSRect(x: rect.minX, y: rect.minY, width: primaryWidth, height: rect.height)
            let secondaryRegion = NSRect(x: primary.maxX + gap, y: rect.minY, width: rect.maxX - primary.maxX - gap, height: rect.height)
            return (primary, adaptiveGrid(in: secondaryRegion, count: secondaryCount, gap: gap))
        case .right:
            let primaryWidth = floor((rect.width - gap) * 0.50)
            let primary = NSRect(x: rect.maxX - primaryWidth, y: rect.minY, width: primaryWidth, height: rect.height)
            let secondaryRegion = NSRect(x: rect.minX, y: rect.minY, width: primary.minX - rect.minX - gap, height: rect.height)
            return (primary, adaptiveGrid(in: secondaryRegion, count: secondaryCount, gap: gap))
        case .topLeft:
            let primary = quadrantPrimary(in: rect, xOnRight: false, yOnBottom: false, gap: gap)
            return (primary, cornerSecondaries(in: rect, excluding: primary, count: secondaryCount, gap: gap, rightSide: true, bottomSide: true))
        case .topRight:
            let primary = quadrantPrimary(in: rect, xOnRight: true, yOnBottom: false, gap: gap)
            return (primary, cornerSecondaries(in: rect, excluding: primary, count: secondaryCount, gap: gap, rightSide: false, bottomSide: true))
        case .bottomLeft:
            let primary = quadrantPrimary(in: rect, xOnRight: false, yOnBottom: true, gap: gap)
            return (primary, cornerSecondaries(in: rect, excluding: primary, count: secondaryCount, gap: gap, rightSide: true, bottomSide: false))
        case .bottomRight:
            let primary = quadrantPrimary(in: rect, xOnRight: true, yOnBottom: true, gap: gap)
            return (primary, cornerSecondaries(in: rect, excluding: primary, count: secondaryCount, gap: gap, rightSide: false, bottomSide: false))
        }
    }

    private func quadrantPrimary(in rect: NSRect, xOnRight: Bool, yOnBottom: Bool, gap: CGFloat) -> NSRect {
        let width = floor((rect.width - gap) * 0.50)
        let height = floor((rect.height - gap) * 0.50)
        return NSRect(
            x: xOnRight ? rect.maxX - width : rect.minX,
            y: yOnBottom ? rect.maxY - height : rect.minY,
            width: width,
            height: height
        )
    }

    private func cornerSecondaries(
        in rect: NSRect,
        excluding primary: NSRect,
        count: Int,
        gap: CGFloat,
        rightSide: Bool,
        bottomSide: Bool
    ) -> [NSRect] {
        guard count > 0 else {
            return []
        }

        let side = rightSide
            ? NSRect(x: primary.maxX + gap, y: rect.minY, width: rect.maxX - primary.maxX - gap, height: rect.height)
            : NSRect(x: rect.minX, y: rect.minY, width: primary.minX - rect.minX - gap, height: rect.height)
        let shelf = bottomSide
            ? NSRect(x: primary.minX, y: primary.maxY + gap, width: primary.width, height: rect.maxY - primary.maxY - gap)
            : NSRect(x: primary.minX, y: rect.minY, width: primary.width, height: primary.minY - rect.minY - gap)

        let regions = [side, shelf].filter { $0.width > 0 && $0.height > 0 }
        guard !regions.isEmpty else {
            return []
        }

        let totalArea = regions.reduce(CGFloat(0)) { $0 + $1.width * $1.height }
        var remainingCount = count
        var blocks: [NSRect] = []

        for (index, region) in regions.enumerated() {
            guard remainingCount > 0 else {
                break
            }

            let regionCount: Int
            if index == regions.count - 1 {
                regionCount = remainingCount
            } else {
                let proportional = Int(round(CGFloat(count) * (region.width * region.height / max(totalArea, 1))))
                regionCount = min(max(1, proportional), remainingCount)
            }

            blocks += adaptiveGrid(in: region, count: regionCount, gap: gap)
            remainingCount -= regionCount
        }
        return blocks
    }

    private func adaptiveGrid(in rect: NSRect, count: Int, gap: CGFloat) -> [NSRect] {
        guard count > 0, rect.width > 0, rect.height > 0 else {
            return []
        }

        if count <= 3 || rect.width < rect.height * 0.50 {
            return verticalStack(in: rect, count: count, gap: gap)
        }

        let columns = min(count, max(1, Int(ceil(sqrt(Double(count))))))
        let rows = Int(ceil(Double(count) / Double(columns)))
        let cellWidth = floor((rect.width - CGFloat(columns - 1) * gap) / CGFloat(columns))
        let cellHeight = floor((rect.height - CGFloat(rows - 1) * gap) / CGFloat(rows))

        return (0..<count).map { index in
            let row = index / columns
            let column = index % columns
            let x = rect.minX + CGFloat(column) * (cellWidth + gap)
            let y = rect.minY + CGFloat(row) * (cellHeight + gap)
            return NSRect(
                x: x,
                y: y,
                width: column == columns - 1 ? rect.maxX - x : cellWidth,
                height: row == rows - 1 ? rect.maxY - y : cellHeight
            )
        }
    }

    private func verticalStack(in rect: NSRect, count: Int, gap: CGFloat) -> [NSRect] {
        guard count > 0, rect.width > 0, rect.height > 0 else {
            return []
        }

        let height = max(4, floor((rect.height - CGFloat(count - 1) * gap) / CGFloat(count)))
        return (0..<count).map { index in
            let y = rect.minY + CGFloat(index) * (height + gap)
            return NSRect(
                x: rect.minX,
                y: y,
                width: rect.width,
                height: index == count - 1 ? rect.maxY - y : height
            )
        }
    }

    private func easeOutCubic(_ value: CGFloat) -> CGFloat {
        let clamped = min(1, max(0, value))
        return 1 - pow(1 - clamped, 3)
    }

    private func text(en: String, zh: String) -> String {
        language == .simplifiedChinese ? zh : en
    }
}
