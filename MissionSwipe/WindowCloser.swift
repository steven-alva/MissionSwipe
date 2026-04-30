import ApplicationServices
import CoreGraphics
import Foundation

final class WindowCloser {
    private enum MissionControlWindowAction {
        case close
        case minimize

        var verb: String {
            switch self {
            case .close:
                return "close"
            case .minimize:
                return "minimize"
            }
        }

        var successPrefix: String {
            switch self {
            case .close:
                return "Mission Control close succeeded"
            case .minimize:
                return "Mission Control minimize succeeded"
            }
        }
    }

    private struct SelectedMissionControlAXMatch {
        let match: AXWindowMatch
        let source: String
    }

    private let permissionManager: AccessibilityPermissionManager
    private let windowEnumerator: WindowEnumerator
    private let axWindowController: AXWindowController
    private let missionControlDetector: MissionControlDetector
    private let debugDumper: DebugWindowDumper
    private let missionControlOverlayRefresher: MissionControlOverlayRefresher

    private let missionControlCloseThreshold: MatchingConfidence = .high
    private let swipePreflightReuseInterval: TimeInterval = 0.45
    private let swipePreflightReuseDistance: CGFloat = 24
    private var preparedSwipeAction: (mousePoint: CGPoint, detection: MissionControlDetection, createdAt: Date)?
    private var lastSwipePreflight: (mousePoint: CGPoint, detection: MissionControlDetection, createdAt: Date, accepted: Bool)?

    private(set) var lastActionReport: String?

    init(
        permissionManager: AccessibilityPermissionManager = AccessibilityPermissionManager(),
        windowEnumerator: WindowEnumerator = WindowEnumerator(),
        axWindowController: AXWindowController = AXWindowController(),
        missionControlDetector: MissionControlDetector = MissionControlDetector(),
        debugDumper: DebugWindowDumper = DebugWindowDumper(),
        missionControlOverlayRefresher: MissionControlOverlayRefresher = MissionControlOverlayRefresher()
    ) {
        self.permissionManager = permissionManager
        self.windowEnumerator = windowEnumerator
        self.axWindowController = axWindowController
        self.missionControlDetector = missionControlDetector
        self.debugDumper = debugDumper
        self.missionControlOverlayRefresher = missionControlOverlayRefresher
    }

    func closeMissionControlWindowUnderMouseIfActive(usePreparedSwipeDetection: Bool = false) {
        performMissionControlWindowAction(.close, usePreparedSwipeDetection: usePreparedSwipeDetection)
    }

    func minimizeMissionControlWindowUnderMouseIfActive(usePreparedSwipeDetection: Bool = false) {
        performMissionControlWindowAction(.minimize, usePreparedSwipeDetection: usePreparedSwipeDetection)
    }

    private func performMissionControlWindowAction(_ action: MissionControlWindowAction, usePreparedSwipeDetection: Bool) {
        Logger.info("Starting Mission-Control-only \(action.verb)-window-under-mouse workflow")

        guard permissionManager.isAccessibilityTrusted else {
            Logger.error("Accessibility permission is missing. Cannot inspect or \(action.verb) AX windows.")
            return
        }

        let prepared = usePreparedSwipeDetection ? preparedSwipeAction : nil
        preparedSwipeAction = nil

        let mousePoint: CGPoint
        let missionControlDetection: MissionControlDetection

        if let prepared,
           Date().timeIntervalSince(prepared.createdAt) <= 1.0 {
            mousePoint = prepared.mousePoint
            missionControlDetection = prepared.detection
            Logger.info("Using prepared Mission Control swipe detection: \(missionControlDetection.debugSummary)")
        } else {
            mousePoint = windowEnumerator.currentMouseLocationInCGWindowCoordinates()
            missionControlDetection = missionControlDetector.detect(mousePoint: mousePoint)
        }

        guard missionControlDetection.isLikelyActive else {
            Logger.info("Mission Control not active; ignoring \(action.verb) request. Detection: \(missionControlDetection.debugSummary)")
            return
        }

        performInMissionControlMode(action, mousePoint: mousePoint, detection: missionControlDetection)
    }

    func prepareMissionControlSwipeClose() -> Bool {
        prepareMissionControlSwipeAction()
    }

    func prepareMissionControlSwipeAction() -> Bool {
        guard permissionManager.isAccessibilityTrusted else {
            Logger.error("Cannot arm swipe gesture because Accessibility permission is missing")
            preparedSwipeAction = nil
            return false
        }

        let mousePoint = windowEnumerator.currentMouseLocationInCGWindowCoordinates()

        if let cached = reusableSwipePreflight(for: mousePoint) {
            if cached.accepted {
                preparedSwipeAction = (mousePoint: cached.mousePoint, detection: cached.detection, createdAt: Date())
                Logger.debug("Swipe gesture preflight reused accepted Mission Control detection: \(cached.detection.debugSummary)")
                return true
            }

            Logger.debug("Swipe gesture preflight reused recent rejection: \(cached.detection.debugSummary)")
            preparedSwipeAction = nil
            return false
        }

        let detection = missionControlDetector.detect(mousePoint: mousePoint)

        guard detection.isLikelyActive, detection.confidence >= .medium else {
            Logger.info("Swipe gesture preflight rejected. Detection: \(detection.debugSummary)")
            preparedSwipeAction = nil
            lastSwipePreflight = (mousePoint: mousePoint, detection: detection, createdAt: Date(), accepted: false)
            return false
        }

        preparedSwipeAction = (mousePoint: mousePoint, detection: detection, createdAt: Date())
        lastSwipePreflight = (mousePoint: mousePoint, detection: detection, createdAt: Date(), accepted: true)
        Logger.info("Swipe gesture preflight accepted. Prepared detection: \(detection.debugSummary)")
        return true
    }

    private func performInMissionControlMode(_ action: MissionControlWindowAction, mousePoint: CGPoint, detection: MissionControlDetection) {
        Logger.info("Mission Control mode active")
        Logger.info("Mission Control detection summary: \(detection.debugSummary)")

        let candidates = windowEnumerator.visibleWindowCandidates(from: detection.entries)
        Logger.info("Mission Control mode has \(candidates.count) real app CG candidate(s) after filtering")

        guard !candidates.isEmpty else {
            Logger.warning("No real app CG candidates are available in Mission Control mode")
            debugDumper.dumpWindowList(entries: detection.entries, header: "Mission Control no-candidate diagnostics")
            return
        }

        let geometryMatches = missionControlGeometryMatches(candidates: candidates, mousePoint: mousePoint)
        let usableGeometryMatches = geometryMatches.filter { $0.confidence != .none }

        guard let geometryMatch = usableGeometryMatches.max(by: { $0.score < $1.score }) else {
            Logger.warning("No Mission Control geometry match had usable confidence")
            logTopGeometryMatches(geometryMatches)
            debugDumper.dumpWindowList(entries: detection.entries, header: "Mission Control geometry failure diagnostics")
            return
        }

        Logger.info("Best Mission Control geometry match: \(geometryMatch.debugSummary), usableGeometryMatches=\(usableGeometryMatches.count)")

        let axWindows = axWindowController.windows(forPID: geometryMatch.candidate.ownerPID)
        let samePIDCandidates = candidates.filter { $0.ownerPID == geometryMatch.candidate.ownerPID }
        let rankedMatch = axWindowController.missionControlRankedMatch(
            for: geometryMatch.candidate,
            samePIDCandidates: samePIDCandidates,
            axWindows: axWindows
        )
        let thumbnailMatch = axWindowController.bestMissionControlThumbnailMatch(for: geometryMatch.candidate, in: axWindows)

        let selectedAXMatch = selectMissionControlAXMatch(rankedMatch: rankedMatch, thumbnailMatch: thumbnailMatch)

        guard let selectedAXMatch else {
            Logger.error("Mission Control mode failed to match selected CG candidate to an AX window")
            debugDumper.dumpWindowList(entries: detection.entries, header: "Mission Control AX-match failure diagnostics")
            return
        }

        let axMatch = selectedAXMatch.match
        let finalConfidence = minConfidence(geometryMatch.confidence, axMatch.confidence)
        Logger.info("Mission Control combined confidence=\(finalConfidence), geometry=\(geometryMatch.confidence), ax=\(axMatch.confidence)")

        if selectedAXMatch.source == "ranked-disputed",
           geometryMatch.score < 100 || usableGeometryMatches.count > 1 {
            Logger.warning("Mission Control ranked/thumbnail conflict is not safe enough to close automatically. geometryScore=\(geometryMatch.score), usableGeometryMatches=\(usableGeometryMatches.count)")
            Logger.warning("Rejected disputed target: CG={\(geometryMatch.debugSummary)}, AX={\(axMatch.debugSummary)}")
            return
        }

        guard finalConfidence >= missionControlCloseThreshold else {
            Logger.warning("Mission Control match confidence \(finalConfidence) is below safe threshold \(missionControlCloseThreshold). Not performing \(action.verb).")
            Logger.warning("Rejected Mission Control target: CG={\(geometryMatch.debugSummary)}, AX={\(axMatch.debugSummary)}")
            debugDumper.dumpWindowList(entries: detection.entries, header: "Mission Control low-confidence diagnostics")
            return
        }

        let didPerform: Bool
        switch action {
        case .close:
            didPerform = axWindowController.close(axMatch.window)
        case .minimize:
            didPerform = axWindowController.minimize(axMatch.window)
        }

        if didPerform {
            let summary = closeSummary(
                action: action,
                cgWindow: geometryMatch.candidate,
                axMatch: axMatch,
                axSource: selectedAXMatch.source,
                geometryConfidence: geometryMatch.confidence,
                finalConfidence: finalConfidence
            )
            lastActionReport = "\(action.successPrefix): \(summary)"
            Logger.info("\(action.successPrefix): \(summary)")
            missionControlOverlayRefresher.refreshHoverFeedback(near: mousePoint)
        } else {
            Logger.error("Mission Control \(action.verb) workflow failed without crashing or force quitting")
        }
    }

    private func missionControlGeometryMatches(candidates: [CGWindowCandidate], mousePoint: CGPoint) -> [CGWindowGeometryMatch] {
        let displayBounds = DisplayBoundsHelper.displayBounds(containing: mousePoint)
        let scaleFactors: [CGFloat] = [0.20, 0.25, 0.33, 0.40, 0.50, 0.60, 0.75]

        return candidates.map { candidate in
            var score = 0
            var explanations: [String] = []
            var bestPredictedBounds: CGRect?

            if candidate.bounds.insetBy(dx: -4, dy: -4).contains(mousePoint) {
                score = 100
                bestPredictedBounds = candidate.bounds
                explanations.append("mouse is inside current CG bounds")
            }

            /*
             Mission Control thumbnails are not exposed as public app windows. This
             approximation keeps each real window's position relative to the display
             center, then scales its frame through common Mission Control thumbnail
             sizes. It is only a diagnostic/best-effort mapping and is intentionally
             gated by a high confidence threshold before closing.
             */
            for scale in scaleFactors {
                let predictedBounds = scaledBounds(candidate.bounds, around: displayBounds, scale: scale).insetBy(dx: -16, dy: -16)
                let predictedCenter = CGPoint(x: predictedBounds.midX, y: predictedBounds.midY)
                let centerDistance = hypot(mousePoint.x - predictedCenter.x, mousePoint.y - predictedCenter.y)
                let normalizedDistance = min(centerDistance / max(predictedBounds.width, predictedBounds.height, 1), 1)

                if predictedBounds.contains(mousePoint) {
                    let scaledScore = 62 + Int((1 - normalizedDistance) * 25)
                    if scaledScore > score {
                        score = scaledScore
                        bestPredictedBounds = predictedBounds
                    }
                    explanations.append("mouse is inside predicted scaled bounds at scale \(String(format: "%.2f", scale)) with score \(scaledScore)")
                } else if centerDistance <= 80 {
                    let nearScore = 35 + Int((1 - min(centerDistance / 80, 1)) * 18)
                    if nearScore > score {
                        score = nearScore
                        bestPredictedBounds = predictedBounds
                    }
                    explanations.append("mouse is near predicted scaled center at scale \(String(format: "%.2f", scale)); distance=\(String(format: "%.1f", centerDistance)), score=\(nearScore)")
                }
            }

            if score > 0 {
                let zOrderBonus = max(0, 8 - min(candidate.orderIndex, 8))
                score += zOrderBonus
                explanations.append("z-order bonus \(zOrderBonus)")
            }

            let confidence: MatchingConfidence
            if score >= 92 {
                confidence = .high
            } else if score >= 60 {
                confidence = .medium
            } else if score >= 30 {
                confidence = .low
            } else {
                confidence = .none
                if explanations.isEmpty {
                    explanations.append("mouse did not match current or predicted bounds")
                }
            }

            return CGWindowGeometryMatch(
                candidate: candidate,
                score: score,
                confidence: confidence,
                predictedBounds: bestPredictedBounds,
                explanations: explanations
            )
        }
    }

    private func scaledBounds(_ bounds: CGRect, around displayBounds: CGRect, scale: CGFloat) -> CGRect {
        let displayCenter = CGPoint(x: displayBounds.midX, y: displayBounds.midY)
        let originalCenter = CGPoint(x: bounds.midX, y: bounds.midY)
        let scaledCenter = CGPoint(
            x: displayCenter.x + (originalCenter.x - displayCenter.x) * scale,
            y: displayCenter.y + (originalCenter.y - displayCenter.y) * scale
        )
        let scaledSize = CGSize(width: bounds.width * scale, height: bounds.height * scale)

        return CGRect(
            x: scaledCenter.x - scaledSize.width / 2,
            y: scaledCenter.y - scaledSize.height / 2,
            width: scaledSize.width,
            height: scaledSize.height
        )
    }

    private func minConfidence(_ lhs: MatchingConfidence, _ rhs: MatchingConfidence) -> MatchingConfidence {
        lhs < rhs ? lhs : rhs
    }

    private func selectMissionControlAXMatch(rankedMatch: AXWindowMatch?, thumbnailMatch: AXWindowMatch?) -> SelectedMissionControlAXMatch? {
        if let rankedMatch, rankedMatch.confidence == .high {
            if let thumbnailMatch,
               thumbnailMatch.confidence == .high,
                !sameAXWindow(rankedMatch.window, thumbnailMatch.window) {
                Logger.warning("Mission Control ranked and thumbnail AX matches disagree; preferring ranked match. rankedScore=\(rankedMatch.score), thumbnailScore=\(thumbnailMatch.score), rankedTitle=\"\(rankedMatch.window.title)\", thumbnailTitle=\"\(thumbnailMatch.window.title)\"")
                return SelectedMissionControlAXMatch(match: rankedMatch, source: "ranked-disputed")
            } else {
                Logger.info("Using high-confidence Mission Control ranked AX match")
            }
            return SelectedMissionControlAXMatch(match: rankedMatch, source: "ranked")
        }

        if let thumbnailMatch, thumbnailMatch.confidence == .high {
            Logger.info("Using high-confidence Mission Control thumbnail AX match")
            return SelectedMissionControlAXMatch(match: thumbnailMatch, source: "thumbnail")
        }

        if let rankedMatch, rankedMatch.confidence != .none {
            Logger.warning("Mission Control ranked AX match is not high confidence: \(rankedMatch.debugSummary)")
            return SelectedMissionControlAXMatch(match: rankedMatch, source: "ranked-low-confidence")
        }

        if let thumbnailMatch, thumbnailMatch.confidence != .none {
            Logger.warning("Mission Control thumbnail AX match is not high confidence: \(thumbnailMatch.debugSummary)")
            return SelectedMissionControlAXMatch(match: thumbnailMatch, source: "thumbnail-low-confidence")
        }

        return nil
    }

    private func sameAXWindow(_ lhs: AXWindowSnapshot, _ rhs: AXWindowSnapshot) -> Bool {
        lhs.title == rhs.title && lhs.frame == rhs.frame && lhs.role == rhs.role && lhs.subrole == rhs.subrole
    }

    private func reusableSwipePreflight(for mousePoint: CGPoint) -> (mousePoint: CGPoint, detection: MissionControlDetection, accepted: Bool)? {
        guard let cached = lastSwipePreflight else {
            return nil
        }

        let age = Date().timeIntervalSince(cached.createdAt)
        guard age <= swipePreflightReuseInterval else {
            return nil
        }

        let distance = hypot(mousePoint.x - cached.mousePoint.x, mousePoint.y - cached.mousePoint.y)
        guard distance <= swipePreflightReuseDistance else {
            return nil
        }

        return (cached.mousePoint, cached.detection, cached.accepted)
    }

    private func logTopGeometryMatches(_ matches: [CGWindowGeometryMatch]) {
        matches
            .sorted { $0.score > $1.score }
            .prefix(5)
            .forEach { match in
                Logger.info("Mission Control geometry diagnostic candidate: \(match.debugSummary)")
            }
    }

    private func closeSummary(
        action: MissionControlWindowAction,
        cgWindow: CGWindowCandidate,
        axMatch: AXWindowMatch,
        axSource: String,
        geometryConfidence: MatchingConfidence,
        finalConfidence: MatchingConfidence
    ) -> String {
        let axFrameText = axMatch.window.frame.map { "\($0.integral)" } ?? "nil"
        return "action=\(action.verb), owner=\(cgWindow.ownerName), pid=\(cgWindow.ownerPID), cgID=\(cgWindow.windowID), cgOrder=\(cgWindow.orderIndex), axSource=\(axSource), axTitle=\"\(axMatch.window.title)\", axFrame=\(axFrameText), geometry=\(geometryConfidence), ax=\(axMatch.confidence), final=\(finalConfidence)"
    }
}
