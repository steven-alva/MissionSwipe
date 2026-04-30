import CoreGraphics
import Foundation

final class MissionControlOverlayRefresher {
    func refreshHoverFeedback(near mousePoint: CGPoint) {
        Logger.info("Refreshing Mission Control hover feedback with a tiny synthetic mouse move")

        let displayBounds = DisplayBoundsHelper.displayBounds(containing: mousePoint)
        let nudgedPoint = CGPoint(
            x: clamp(mousePoint.x + 1, min: displayBounds.minX + 1, max: displayBounds.maxX - 1),
            y: clamp(mousePoint.y + 1, min: displayBounds.minY + 1, max: displayBounds.maxY - 1)
        )

        postMouseMoved(to: nudgedPoint)

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [mousePoint] in
            self.postMouseMoved(to: mousePoint)
        }
    }

    func moveMouseAwayFromHover(near mousePoint: CGPoint, avoiding avoidBounds: CGRect) {
        let displayBounds = DisplayBoundsHelper.displayBounds(containing: mousePoint)
        let safePoint = safePointOutside(avoidBounds.insetBy(dx: -32, dy: -32), near: mousePoint, in: displayBounds)
        Logger.info("Moving mouse away from minimized Mission Control thumbnail: from=\(mousePoint), to=\(safePoint)")

        postMouseMoved(to: safePoint)

        let nudgedPoint = CGPoint(
            x: clamp(safePoint.x + 1, min: displayBounds.minX + 1, max: displayBounds.maxX - 1),
            y: clamp(safePoint.y + 1, min: displayBounds.minY + 1, max: displayBounds.maxY - 1)
        )

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            self.postMouseMoved(to: nudgedPoint)
        }
    }

    private func postMouseMoved(to point: CGPoint) {
        let source = CGEventSource(stateID: .hidSystemState)
        let event = CGEvent(
            mouseEventSource: source,
            mouseType: .mouseMoved,
            mouseCursorPosition: point,
            mouseButton: .left
        )

        event?.post(tap: .cghidEventTap)
    }

    private func clamp(_ value: CGFloat, min: CGFloat, max: CGFloat) -> CGFloat {
        Swift.max(min, Swift.min(max, value))
    }

    private func safePointOutside(_ avoidBounds: CGRect, near mousePoint: CGPoint, in displayBounds: CGRect) -> CGPoint {
        let candidates = [
            CGPoint(x: avoidBounds.maxX + 72, y: mousePoint.y),
            CGPoint(x: avoidBounds.minX - 72, y: mousePoint.y),
            CGPoint(x: mousePoint.x, y: avoidBounds.minY - 72),
            CGPoint(x: mousePoint.x, y: avoidBounds.maxY + 72),
            CGPoint(x: displayBounds.midX, y: displayBounds.minY + 80),
            CGPoint(x: displayBounds.minX + 80, y: displayBounds.minY + 80),
            CGPoint(x: displayBounds.maxX - 80, y: displayBounds.minY + 80)
        ]

        if let safeCandidate = candidates.first(where: { candidate in
            displayBounds.insetBy(dx: 8, dy: 8).contains(candidate) && !avoidBounds.contains(candidate)
        }) {
            return safeCandidate
        }

        return CGPoint(
            x: clamp(displayBounds.midX, min: displayBounds.minX + 8, max: displayBounds.maxX - 8),
            y: clamp(displayBounds.minY + 80, min: displayBounds.minY + 8, max: displayBounds.maxY - 8)
        )
    }
}
