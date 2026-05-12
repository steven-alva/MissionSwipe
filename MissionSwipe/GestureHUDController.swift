import AppKit

final class GestureHUDController {
    enum Kind {
        case progress
        case success
        case warning
    }

    private enum Constants {
        static let size = CGSize(width: 214, height: 88)
        static let mouseOffset: CGFloat = 34
        static let edgePadding: CGFloat = 10
    }

    private let panel: NSPanel
    private let hudView = GestureHUDView()
    private var hideWorkItem: DispatchWorkItem?

    init() {
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
        panel.contentView = hudView
    }

    func show(message: String, progress: CGFloat, kind: Kind, duration: TimeInterval = 0.65) {
        DispatchQueue.main.async { [weak self] in
            guard let self else {
                return
            }

            self.hideWorkItem?.cancel()
            self.hudView.message = message
            self.hudView.progress = min(1, max(0, progress))
            self.hudView.kind = kind
            self.hudView.needsDisplay = true
            if progress >= 1 {
                self.hudView.triggerCompletionPulse()
            }

            self.panel.setFrame(self.frameNearMouse(), display: true)
            self.panel.alphaValue = 1
            self.panel.orderFrontRegardless()

            let effectiveDuration = progress >= 1 ? max(duration, 0.85) : duration
            let workItem = DispatchWorkItem { [weak self] in
                self?.panel.orderOut(nil)
            }
            self.hideWorkItem = workItem
            DispatchQueue.main.asyncAfter(deadline: .now() + effectiveDuration, execute: workItem)
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

private final class GestureHUDView: NSView {
    private enum Constants {
        static let hudSize = CGSize(width: 194, height: 66)
        static let cornerRadius: CGFloat = 18
    }

    var message = ""
    var progress: CGFloat = 0
    var kind: GestureHUDController.Kind = .progress
    private var pulseProgress: CGFloat = 0
    private var pulseTimer: Timer?

    override var isFlipped: Bool {
        true
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        let scale = 1 + 0.02 * sin(.pi * pulseProgress)
        let rect = scaledHudRect(scale: scale)
        let path = NSBezierPath(
            roundedRect: rect,
            xRadius: Constants.cornerRadius * scale,
            yRadius: Constants.cornerRadius * scale
        )

        drawShadow(for: path, pulse: pulseProgress)

        let materialLift = 0.04 * sin(.pi * pulseProgress)
        NSColor.black.withAlphaComponent(0.76 - materialLift).setFill()
        path.fill()

        NSColor.white.withAlphaComponent(0.24 + 0.10 * sin(.pi * pulseProgress)).setStroke()
        path.lineWidth = 1
        path.stroke()
        drawEdgeSweep(around: rect, path: path)

        drawMessage(in: rect)
        drawProgressBar(in: rect)
    }

    func triggerCompletionPulse() {
        pulseTimer?.invalidate()
        pulseProgress = 0

        let startedAt = Date()
        pulseTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60.0, repeats: true) { [weak self] timer in
            guard let self else {
                timer.invalidate()
                return
            }

            let elapsed = Date().timeIntervalSince(startedAt)
            let progress = min(1, elapsed / 0.62)
            self.pulseProgress = CGFloat(progress)
            self.needsDisplay = true

            if progress >= 1 {
                timer.invalidate()
                self.pulseTimer = nil
                self.pulseProgress = 0
                self.needsDisplay = true
            }
        }
        RunLoop.main.add(pulseTimer!, forMode: .common)
    }

    private func drawShadow(for path: NSBezierPath, pulse: CGFloat) {
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowOffset = .zero
        shadow.shadowBlurRadius = 10 + 7 * sin(.pi * pulse)
        shadow.shadowColor = NSColor.white.withAlphaComponent(0.10 + 0.10 * sin(.pi * pulse))
        shadow.set()
        NSColor.white.withAlphaComponent(0.05).setFill()
        path.fill()
        NSGraphicsContext.restoreGraphicsState()
    }

    private func drawEdgeSweep(around rect: NSRect, path: NSBezierPath) {
        guard pulseProgress > 0 else {
            return
        }

        let t = pulseProgress
        let alpha = max(0, 0.36 * sin(.pi * t))
        guard alpha > 0 else {
            return
        }

        let sweepWidth: CGFloat = 58
        let travelWidth = rect.width + sweepWidth * 2
        let x = rect.minX - sweepWidth + travelWidth * t
        let sweepRect = NSRect(x: x, y: rect.minY - 2, width: sweepWidth, height: rect.height + 4)

        NSGraphicsContext.saveGraphicsState()
        path.addClip()
        NSGradient(colors: [
            NSColor.white.withAlphaComponent(0),
            NSColor.white.withAlphaComponent(alpha * 0.12),
            NSColor.white.withAlphaComponent(0)
        ])?.draw(in: sweepRect, angle: 0)
        NSGraphicsContext.restoreGraphicsState()

        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(rect: sweepRect).addClip()
        NSColor.white.withAlphaComponent(alpha).setStroke()
        path.lineWidth = 1.6
        path.stroke()
        NSGraphicsContext.restoreGraphicsState()
    }

    private func drawMessage(in hudRect: NSRect) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 15, weight: .semibold),
            .foregroundColor: NSColor.white,
            .paragraphStyle: paragraph
        ]
        let rect = NSRect(x: hudRect.minX + 16, y: hudRect.minY + 14, width: hudRect.width - 32, height: 22)
        message.draw(in: rect, withAttributes: attributes)
    }

    private func drawProgressBar(in hudRect: NSRect) {
        let trackWidth: CGFloat = 116
        let barFrame = NSRect(x: hudRect.midX - trackWidth / 2, y: hudRect.minY + 47, width: trackWidth, height: 3)
        let trackPath = NSBezierPath(roundedRect: barFrame, xRadius: 1.5, yRadius: 1.5)
        NSColor.white.withAlphaComponent(0.16).setFill()
        trackPath.fill()

        guard progress > 0 else {
            return
        }

        let filledWidth = min(barFrame.width, max(6, barFrame.width * progress))
        let fillFrame = NSRect(x: barFrame.midX - filledWidth / 2, y: barFrame.minY, width: filledWidth, height: barFrame.height)
        let fillPath = NSBezierPath(roundedRect: fillFrame, xRadius: 1.5, yRadius: 1.5)
        NSColor.white.withAlphaComponent(0.92).setFill()
        fillPath.fill()
    }

    private func scaledHudRect(scale: CGFloat) -> NSRect {
        let width = Constants.hudSize.width * scale
        let height = Constants.hudSize.height * scale
        return NSRect(
            x: (bounds.width - width) / 2,
            y: (bounds.height - height) / 2,
            width: width,
            height: height
        )
    }
}
