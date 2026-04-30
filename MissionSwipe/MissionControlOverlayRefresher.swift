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

}
