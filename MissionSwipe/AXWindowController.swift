import ApplicationServices
import CoreGraphics
import Foundation

struct AXWindowSnapshot {
    let element: AXUIElement
    let title: String
    let position: CGPoint?
    let size: CGSize?
    let role: String
    let subrole: String

    var frame: CGRect? {
        guard let position, let size else {
            return nil
        }
        return CGRect(origin: position, size: size)
    }

    var debugSummary: String {
        let frameText = frame.map { "\($0.integral)" } ?? "nil"
        return "title=\"\(title)\", role=\(role), subrole=\(subrole), frame=\(frameText)"
    }
}

struct AXCloseButtonDiagnostics {
    let exists: Bool
    let supportsPress: Bool
    let actions: [String]
}

final class AXWindowController {
    func windows(forPID pid: pid_t) -> [AXWindowSnapshot] {
        let appElement = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(appElement, 0.75)

        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &value)
        guard result == .success else {
            Logger.error("Failed to copy AX windows for pid=\(pid). AXError=\(result.rawValue)")
            return []
        }

        guard let windowElements = value as? [AXUIElement] else {
            Logger.warning("AX windows attribute for pid=\(pid) was not an AXUIElement array")
            return []
        }

        Logger.info("AX returned \(windowElements.count) windows for pid=\(pid)")

        return windowElements.map { element in
            AXWindowSnapshot(
                element: element,
                title: stringAttribute(element, kAXTitleAttribute as CFString) ?? "",
                position: pointAttribute(element, kAXPositionAttribute as CFString),
                size: sizeAttribute(element, kAXSizeAttribute as CFString),
                role: stringAttribute(element, kAXRoleAttribute as CFString) ?? "",
                subrole: stringAttribute(element, kAXSubroleAttribute as CFString) ?? ""
            )
        }
    }

    func bestMatch(for cgWindow: CGWindowCandidate, in axWindows: [AXWindowSnapshot]) -> AXWindowMatch? {
        guard !axWindows.isEmpty else {
            Logger.warning("No AX windows available to match CG window id=\(cgWindow.windowID)")
            return nil
        }

        /*
         AppKit does not expose a public way to map a CGWindowID directly to an AXUIElement.
         The closest stable public match is a weighted comparison inside the same owning
         process: title, top-left position, size, center point, and AX role/subrole.
         Geometry gets tolerance because CGWindow bounds can include shadows while AX size
         normally describes the accessible window frame.
         */
        let scoredWindows = axWindows.map { window -> AXWindowMatch in
            let scoreResult = matchScore(cgWindow: cgWindow, axWindow: window)
            let confidence = confidence(forAXScore: scoreResult.score)
            let match = AXWindowMatch(
                window: window,
                score: scoreResult.score,
                confidence: confidence,
                explanations: scoreResult.explanations
            )
            Logger.debug("AX match for CG id=\(cgWindow.windowID): \(match.debugSummary)")
            return match
        }

        guard let best = scoredWindows.max(by: { $0.score < $1.score }) else {
            return nil
        }

        guard best.confidence != .none else {
            Logger.warning("Best AX match has no confidence for CG window: \(cgWindow.debugSummary)")
            return nil
        }

        Logger.info("Best AX match for CG window id=\(cgWindow.windowID): \(best.debugSummary)")
        return best
    }

    func bestMissionControlThumbnailMatch(for cgWindow: CGWindowCandidate, in axWindows: [AXWindowSnapshot]) -> AXWindowMatch? {
        guard !axWindows.isEmpty else {
            Logger.warning("No AX windows available for Mission Control thumbnail match. CG window id=\(cgWindow.windowID)")
            return nil
        }

        /*
         In Mission Control, CGWindowList can expose app-owned layer-0 thumbnail
         frames with empty titles and scaled bounds. The AX windows for that app
         still report their real desktop frames. This matcher therefore avoids
         title dependence and compares display membership, aspect ratio, uniform
         scale, and relative center instead of raw frame equality.
         */
        let matches = axWindows.map { window -> AXWindowMatch in
            let scoreResult = missionControlThumbnailScore(cgWindow: cgWindow, axWindow: window)
            let confidence = confidence(forMissionControlThumbnailScore: scoreResult.score)
            let match = AXWindowMatch(
                window: window,
                score: scoreResult.score,
                confidence: confidence,
                explanations: scoreResult.explanations
            )
            return match
        }

        let sortedMatches = matches.sorted { $0.score > $1.score }
        guard let best = sortedMatches.first,
              best.confidence != .none else {
            Logger.warning("No usable Mission Control AX thumbnail match for CG window: \(cgWindow.debugSummary)")
            return nil
        }

        if let secondBest = sortedMatches.dropFirst().first,
           best.confidence == .high,
           secondBest.confidence == .high,
           best.score - secondBest.score < 18 {
            let ambiguousMatch = AXWindowMatch(
                window: best.window,
                score: best.score,
                confidence: .medium,
                explanations: best.explanations + ["ambiguous thumbnail match: second best score \(secondBest.score) is too close"]
            )
            Logger.warning("Mission Control thumbnail AX match is ambiguous. bestScore=\(best.score), secondScore=\(secondBest.score), bestTitle=\"\(best.window.title)\", secondTitle=\"\(secondBest.window.title)\"")
            return ambiguousMatch
        }
        return best
    }

    func missionControlRankedMatch(
        for cgWindow: CGWindowCandidate,
        samePIDCandidates: [CGWindowCandidate],
        axWindows: [AXWindowSnapshot]
    ) -> AXWindowMatch? {
        guard let candidateRank = samePIDCandidates.firstIndex(where: { $0.windowID == cgWindow.windowID }) else {
            Logger.warning("Unable to compute same-PID CG rank for Mission Control candidate id=\(cgWindow.windowID)")
            return nil
        }

        guard candidateRank < axWindows.count else {
            Logger.warning("Mission Control same-PID CG rank \(candidateRank) exceeds AX window count \(axWindows.count) for pid=\(cgWindow.ownerPID)")
            return nil
        }

        let window = axWindows[candidateRank]
        let scoreResult = missionControlRankedScore(cgWindow: cgWindow, axWindow: window, candidateRank: candidateRank)
        let match = AXWindowMatch(
            window: window,
            score: scoreResult.score,
            confidence: confidence(forMissionControlRankedScore: scoreResult.score),
            explanations: scoreResult.explanations
        )

        Logger.info("Mission Control ranked AX match for CG window id=\(cgWindow.windowID): score=\(match.score), confidence=\(match.confidence)")
        return match
    }

    func close(_ window: AXWindowSnapshot) -> Bool {
        Logger.info("Attempting to close AX window: \(window.debugSummary)")

        if let closeButton = elementAttribute(window.element, kAXCloseButtonAttribute as CFString) {
            let pressResult = AXUIElementPerformAction(closeButton, kAXPressAction as CFString)
            if pressResult == .success {
                Logger.info("Pressed AX close button successfully")
                return true
            }

            Logger.warning("AX close button press failed. AXError=\(pressResult.rawValue)")
        } else {
            Logger.warning("AX close button attribute is unavailable")
        }

        let actions = actionNames(for: window.element)
        Logger.debug("Available AX actions on matched window: \(actions)")

        for action in ["AXClose", kAXCancelAction as String] {
            guard actions.contains(action) else {
                continue
            }

            let result = AXUIElementPerformAction(window.element, action as CFString)
            if result == .success {
                Logger.info("Performed AX window action \(action) successfully")
                return true
            }

            Logger.warning("AX window action \(action) failed. AXError=\(result.rawValue)")
        }

        Logger.error("Unable to close matched AX window without force quitting")
        return false
    }

    func minimize(_ window: AXWindowSnapshot) -> Bool {
        Logger.info("Attempting to minimize AX window with native minimize button: \(window.debugSummary)")

        if let minimizeButton = elementAttribute(window.element, kAXMinimizeButtonAttribute as CFString) {
            let pressResult = AXUIElementPerformAction(minimizeButton, kAXPressAction as CFString)
            if pressResult == .success {
                Logger.info("Pressed AX minimize button successfully")
                return true
            }

            Logger.warning("AX minimize button press failed. AXError=\(pressResult.rawValue)")
        } else {
            Logger.warning("AX minimize button attribute is unavailable")
        }

        let setResult = AXUIElementSetAttributeValue(window.element, kAXMinimizedAttribute as CFString, kCFBooleanTrue)
        if setResult == .success {
            Logger.info("Set AXMinimized=true successfully")
            return true
        }

        Logger.error("Unable to minimize matched AX window. AXError=\(setResult.rawValue)")
        return false
    }

    func closeButtonDiagnostics(for window: AXWindowSnapshot) -> AXCloseButtonDiagnostics {
        guard let closeButton = elementAttribute(window.element, kAXCloseButtonAttribute as CFString) else {
            return AXCloseButtonDiagnostics(exists: false, supportsPress: false, actions: [])
        }

        let actions = actionNames(for: closeButton)
        return AXCloseButtonDiagnostics(
            exists: true,
            supportsPress: actions.contains(kAXPressAction as String),
            actions: actions
        )
    }

    private func matchScore(cgWindow: CGWindowCandidate, axWindow: AXWindowSnapshot) -> (score: Int, explanations: [String]) {
        var score = 0
        var explanations: [String] = []

        let cgTitle = cgWindow.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let axTitle = axWindow.title.trimmingCharacters(in: .whitespacesAndNewlines)

        if !cgTitle.isEmpty, !axTitle.isEmpty {
            if cgTitle == axTitle {
                score += 50
                explanations.append("exact title match")
            } else if cgTitle.caseInsensitiveCompare(axTitle) == .orderedSame {
                score += 45
                explanations.append("case-insensitive title match")
            } else if cgTitle.localizedCaseInsensitiveContains(axTitle) || axTitle.localizedCaseInsensitiveContains(cgTitle) {
                score += 25
                explanations.append("partial title match")
            }
        } else if cgTitle.isEmpty, axTitle.isEmpty {
            score += 5
            explanations.append("both titles are empty")
        } else {
            explanations.append("title mismatch cg=\"\(cgTitle)\" ax=\"\(axTitle)\"")
        }

        if let axFrame = axWindow.frame {
            let positionDelta = max(abs(axFrame.minX - cgWindow.bounds.minX), abs(axFrame.minY - cgWindow.bounds.minY))
            if positionDelta <= 4 {
                score += 40
                explanations.append("position delta <= 4")
            } else if positionDelta <= 24 {
                score += 30
                explanations.append("position delta <= 24")
            } else if positionDelta <= 80 {
                score += 12
                explanations.append("position delta <= 80")
            } else {
                explanations.append("position delta too large: \(String(format: "%.1f", positionDelta))")
            }

            let sizeDelta = max(abs(axFrame.width - cgWindow.bounds.width), abs(axFrame.height - cgWindow.bounds.height))
            if sizeDelta <= 4 {
                score += 35
                explanations.append("size delta <= 4")
            } else if sizeDelta <= 36 {
                score += 25
                explanations.append("size delta <= 36")
            } else if sizeDelta <= 120 {
                score += 10
                explanations.append("size delta <= 120")
            } else {
                explanations.append("size delta too large: \(String(format: "%.1f", sizeDelta))")
            }

            let centerDelta = hypot(axFrame.midX - cgWindow.bounds.midX, axFrame.midY - cgWindow.bounds.midY)
            if centerDelta <= 40 {
                score += 20
                explanations.append("center delta <= 40")
            } else if centerDelta <= 140 {
                score += 10
                explanations.append("center delta <= 140")
            } else {
                explanations.append("center delta too large: \(String(format: "%.1f", centerDelta))")
            }
        } else {
            explanations.append("AX frame unavailable")
        }

        if axWindow.role == kAXWindowRole as String {
            score += 5
            explanations.append("role is AXWindow")
        } else {
            explanations.append("role is \(axWindow.role)")
        }

        if axWindow.subrole == kAXStandardWindowSubrole as String || axWindow.subrole == kAXDialogSubrole as String {
            score += 5
            explanations.append("subrole is closeable window-like")
        } else {
            explanations.append("subrole is \(axWindow.subrole)")
        }

        return (score, explanations)
    }

    private func missionControlThumbnailScore(cgWindow: CGWindowCandidate, axWindow: AXWindowSnapshot) -> (score: Int, explanations: [String]) {
        var score = 0
        var explanations: [String] = []

        guard let axFrame = axWindow.frame, axFrame.width > 1, axFrame.height > 1 else {
            return (0, ["AX frame unavailable"])
        }

        let cgFrame = cgWindow.bounds
        let cgCenter = CGPoint(x: cgFrame.midX, y: cgFrame.midY)
        let axCenter = CGPoint(x: axFrame.midX, y: axFrame.midY)
        let cgDisplay = DisplayBoundsHelper.displayBounds(containing: cgCenter)
        let axDisplay = DisplayBoundsHelper.displayBounds(containing: axCenter)

        if cgDisplay == axDisplay {
            score += 45
            explanations.append("thumbnail and AX window centers are on the same display")
        } else {
            explanations.append("thumbnail and AX window centers are on different displays")
        }

        let cgAspect = cgFrame.width / cgFrame.height
        let axAspect = axFrame.width / axFrame.height
        let aspectDelta = abs(cgAspect - axAspect)

        if aspectDelta <= 0.03 {
            score += 30
            explanations.append("aspect ratio delta <= 0.03")
        } else if aspectDelta <= 0.08 {
            score += 18
            explanations.append("aspect ratio delta <= 0.08")
        } else {
            explanations.append("aspect ratio delta too large: \(String(format: "%.3f", aspectDelta))")
        }

        let widthScale = cgFrame.width / axFrame.width
        let heightScale = cgFrame.height / axFrame.height
        let scaleDelta = abs(widthScale - heightScale)
        let averageScale = (widthScale + heightScale) / 2

        if scaleDelta <= 0.04, averageScale > 0.10, averageScale < 1.05 {
            score += 25
            explanations.append("thumbnail scale is uniform: \(String(format: "%.3f", averageScale))")
        } else if scaleDelta <= 0.10, averageScale > 0.10, averageScale < 1.20 {
            score += 12
            explanations.append("thumbnail scale is roughly uniform: \(String(format: "%.3f", averageScale))")
        } else {
            explanations.append("scale mismatch width=\(String(format: "%.3f", widthScale)), height=\(String(format: "%.3f", heightScale))")
        }

        let cgRelativeCenter = relativeCenter(cgCenter, in: cgDisplay)
        let axRelativeCenter = relativeCenter(axCenter, in: axDisplay)
        let relativeXDelta = abs(cgRelativeCenter.x - axRelativeCenter.x)
        let relativeYDelta = abs(cgRelativeCenter.y - axRelativeCenter.y)

        if relativeXDelta <= 0.12 {
            score += 18
            explanations.append("relative x-center delta <= 0.12")
        } else if relativeXDelta <= 0.25 {
            score += 8
            explanations.append("relative x-center delta <= 0.25")
        } else {
            explanations.append("relative x-center delta too large: \(String(format: "%.3f", relativeXDelta))")
        }

        if relativeYDelta <= 0.18 {
            score += 10
            explanations.append("relative y-center delta <= 0.18")
        } else if relativeYDelta <= 0.35 {
            score += 4
            explanations.append("relative y-center delta <= 0.35")
        } else {
            explanations.append("relative y-center delta too large: \(String(format: "%.3f", relativeYDelta))")
        }

        if axWindow.role == kAXWindowRole as String {
            score += 5
            explanations.append("role is AXWindow")
        }

        if axWindow.subrole == kAXStandardWindowSubrole as String || axWindow.subrole == kAXDialogSubrole as String {
            score += 5
            explanations.append("subrole is closeable window-like")
        }

        return (score, explanations)
    }

    private func missionControlRankedScore(
        cgWindow: CGWindowCandidate,
        axWindow: AXWindowSnapshot,
        candidateRank: Int
    ) -> (score: Int, explanations: [String]) {
        var score = 40
        var explanations = ["same-PID CG thumbnail rank \(candidateRank) mapped to AX window index \(candidateRank)"]

        guard let axFrame = axWindow.frame, axFrame.width > 1, axFrame.height > 1 else {
            return (score, explanations + ["AX frame unavailable"])
        }

        let cgFrame = cgWindow.bounds
        let cgAspect = cgFrame.width / cgFrame.height
        let axAspect = axFrame.width / axFrame.height
        let aspectDelta = abs(cgAspect - axAspect)

        if aspectDelta <= 0.03 {
            score += 30
            explanations.append("aspect ratio delta <= 0.03")
        } else if aspectDelta <= 0.08 {
            score += 18
            explanations.append("aspect ratio delta <= 0.08")
        } else {
            explanations.append("aspect ratio delta too large: \(String(format: "%.3f", aspectDelta))")
        }

        let widthScale = cgFrame.width / axFrame.width
        let heightScale = cgFrame.height / axFrame.height
        let scaleDelta = abs(widthScale - heightScale)
        let averageScale = (widthScale + heightScale) / 2

        if scaleDelta <= 0.04, averageScale > 0.10, averageScale < 1.05 {
            score += 25
            explanations.append("thumbnail scale is uniform: \(String(format: "%.3f", averageScale))")
        } else if scaleDelta <= 0.10, averageScale > 0.10, averageScale < 1.20 {
            score += 12
            explanations.append("thumbnail scale is roughly uniform: \(String(format: "%.3f", averageScale))")
        } else {
            explanations.append("scale mismatch width=\(String(format: "%.3f", widthScale)), height=\(String(format: "%.3f", heightScale))")
        }

        if axWindow.role == kAXWindowRole as String {
            score += 5
            explanations.append("role is AXWindow")
        }

        if axWindow.subrole == kAXStandardWindowSubrole as String || axWindow.subrole == kAXDialogSubrole as String {
            score += 5
            explanations.append("subrole is closeable window-like")
        }

        return (score, explanations)
    }

    private func relativeCenter(_ point: CGPoint, in bounds: CGRect) -> CGPoint {
        guard bounds.width > 0, bounds.height > 0 else {
            return .zero
        }

        return CGPoint(
            x: (point.x - bounds.minX) / bounds.width,
            y: (point.y - bounds.minY) / bounds.height
        )
    }

    private func confidence(forAXScore score: Int) -> MatchingConfidence {
        if score >= 90 {
            return .high
        }
        if score >= 45 {
            return .medium
        }
        if score >= 20 {
            return .low
        }
        return .none
    }

    private func confidence(forMissionControlThumbnailScore score: Int) -> MatchingConfidence {
        if score >= 100 {
            return .high
        }
        if score >= 60 {
            return .medium
        }
        if score >= 35 {
            return .low
        }
        return .none
    }

    private func confidence(forMissionControlRankedScore score: Int) -> MatchingConfidence {
        if score >= 95 {
            return .high
        }
        if score >= 65 {
            return .medium
        }
        if score >= 40 {
            return .low
        }
        return .none
    }

    private func stringAttribute(_ element: AXUIElement, _ attribute: CFString) -> String? {
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, attribute, &value)
        guard result == .success else {
            return nil
        }
        return value as? String
    }

    private func pointAttribute(_ element: AXUIElement, _ attribute: CFString) -> CGPoint? {
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, attribute, &value)
        guard result == .success, let value, CFGetTypeID(value) == AXValueGetTypeID() else {
            return nil
        }

        let axValue = value as! AXValue
        var point = CGPoint.zero
        guard AXValueGetValue(axValue, .cgPoint, &point) else {
            return nil
        }
        return point
    }

    private func sizeAttribute(_ element: AXUIElement, _ attribute: CFString) -> CGSize? {
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, attribute, &value)
        guard result == .success, let value, CFGetTypeID(value) == AXValueGetTypeID() else {
            return nil
        }

        let axValue = value as! AXValue
        var size = CGSize.zero
        guard AXValueGetValue(axValue, .cgSize, &size) else {
            return nil
        }
        return size
    }

    private func elementAttribute(_ element: AXUIElement, _ attribute: CFString) -> AXUIElement? {
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, attribute, &value)
        guard result == .success, let value, CFGetTypeID(value) == AXUIElementGetTypeID() else {
            Logger.debug("Missing AX element attribute \(attribute). AXError=\(result.rawValue)")
            return nil
        }
        return (value as! AXUIElement)
    }

    private func actionNames(for element: AXUIElement) -> [String] {
        var actionNames: CFArray?
        let result = AXUIElementCopyActionNames(element, &actionNames)
        guard result == .success else {
            Logger.debug("Unable to read AX action names. AXError=\(result.rawValue)")
            return []
        }
        return actionNames as? [String] ?? []
    }
}
