import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

final class WindowArranger {
    private enum Constants {
        static let missionControlExitRetryDelay: TimeInterval = 0.18
        static let missionControlExitSettleDelay: TimeInterval = 0.45
        static let maxMissionControlExitAttempts = 8
    }

    private struct ArrangeableWindow {
        let candidate: CGWindowCandidate
        let axWindow: AXWindowSnapshot
        let originalFrame: CGRect
        let displayFrame: CGRect
    }

    private struct DisplayLayout {
        let fullBounds: CGRect
        let usableBounds: CGRect
    }

    private struct PlannedFrame {
        let window: ArrangeableWindow
        let frame: CGRect
    }

    private let permissionManager: AccessibilityPermissionManager
    private let windowEnumerator: WindowEnumerator
    private let axWindowController: AXWindowController
    private let missionControlDetector: MissionControlDetector
    private var undoSnapshots: [AXWindowSnapshot] = []

    init(
        permissionManager: AccessibilityPermissionManager = AccessibilityPermissionManager(),
        windowEnumerator: WindowEnumerator = WindowEnumerator(),
        axWindowController: AXWindowController = AXWindowController(),
        missionControlDetector: MissionControlDetector = MissionControlDetector()
    ) {
        self.permissionManager = permissionManager
        self.windowEnumerator = windowEnumerator
        self.axWindowController = axWindowController
        self.missionControlDetector = missionControlDetector
    }

    func arrangeAfterExitingMissionControl(trigger: String, preferCurrentMouseExitPoint: Bool = false) {
        Logger.info("Auto arrange requested from \(trigger); exiting Mission Control before arranging")
        requestMissionControlExit(preferCurrentMouseExitPoint: preferCurrentMouseExitPoint)
        waitForMissionControlExitThenArrange(
            trigger: trigger,
            attempt: 1,
            startedAt: Date(),
            preferCurrentMouseExitPoint: preferCurrentMouseExitPoint
        )
    }

    func arrangeVisibleWindows(trigger: String) {
        Logger.info("Starting visible-window auto arrange from \(trigger)")

        guard permissionManager.isAccessibilityTrusted else {
            Logger.error("Accessibility permission is missing. Cannot arrange windows.")
            return
        }

        let candidates = windowEnumerator.visibleWindowCandidates()
        let arrangeableWindows = collectArrangeableWindows(from: candidates)
        guard !arrangeableWindows.isEmpty else {
            Logger.warning("No arrangeable visible windows found")
            return
        }

        undoSnapshots = arrangeableWindows.map(\.axWindow)
        let displayLayouts = activeDisplayLayouts()
        let groupedWindows = Dictionary(grouping: arrangeableWindows) { window in
            displayIndex(for: window.displayFrame, in: displayLayouts.map(\.fullBounds))
        }

        var movedCount = 0
        for (displayIndex, windows) in groupedWindows {
            guard displayLayouts.indices.contains(displayIndex) else {
                continue
            }

            let layout = displayLayouts[displayIndex]
            Logger.info("Auto arrange display layout: full=\(layout.fullBounds.integral), usable=\(layout.usableBounds.integral)")
            movedCount += arrange(windows: windows, inside: layout.usableBounds)
        }

        Logger.info("Visible-window auto arrange finished. moved=\(movedCount), total=\(arrangeableWindows.count)")
    }

    func undoLastArrange() {
        guard !undoSnapshots.isEmpty else {
            Logger.info("No previous auto arrange snapshot to undo")
            return
        }

        var restoredCount = 0
        for snapshot in undoSnapshots {
            guard let frame = snapshot.frame else {
                continue
            }

            if setFrame(frame, for: snapshot.element) {
                restoredCount += 1
            }
        }

        Logger.info("Undo last auto arrange finished. restored=\(restoredCount), total=\(undoSnapshots.count)")
        undoSnapshots.removeAll()
    }

    private func collectArrangeableWindows(from candidates: [CGWindowCandidate]) -> [ArrangeableWindow] {
        var seenWindowKeys = Set<String>()
        var arrangeableWindows: [ArrangeableWindow] = []
        let visiblePIDs = Set(candidates.map(\.ownerPID))
        let candidatesByPID = Dictionary(grouping: candidates, by: \.ownerPID)

        for ownerPID in visiblePIDs {
            let axWindows = axWindowController.windows(forPID: ownerPID)
            let pidCandidates = candidatesByPID[ownerPID] ?? []

            for axWindow in axWindows {
                guard isArrangeable(axWindow),
                      let originalFrame = axWindow.frame else {
                    continue
                }

                let key = "\(ownerPID)|\(axWindow.title)|\(originalFrame.integral)"
                guard !seenWindowKeys.contains(key) else {
                    continue
                }
                seenWindowKeys.insert(key)

                let candidate = bestCandidate(for: axWindow, ownerPID: ownerPID, candidates: pidCandidates)
                guard let candidate else {
                    Logger.info("Skipping AX window without a visible CG candidate: pid=\(ownerPID), window=\(axWindow.debugSummary)")
                    continue
                }

                arrangeableWindows.append(
                    ArrangeableWindow(
                        candidate: candidate,
                        axWindow: axWindow,
                        originalFrame: originalFrame,
                        displayFrame: originalFrame
                    )
                )
            }
        }

        Logger.info("Collected \(arrangeableWindows.count) arrangeable AX window(s) from \(candidates.count) visible CG candidate(s)")
        return arrangeableWindows
    }

    private func bestCandidate(for axWindow: AXWindowSnapshot, ownerPID: pid_t, candidates: [CGWindowCandidate]) -> CGWindowCandidate? {
        guard let frame = axWindow.frame else {
            return nil
        }

        let matches = candidates.map { candidate -> (candidate: CGWindowCandidate, score: CGFloat) in
            let intersectionScore = intersectionArea(candidate.bounds, frame) / max(min(candidate.bounds.width * candidate.bounds.height, frame.width * frame.height), 1)
            let centerDistance = hypot(candidate.bounds.midX - frame.midX, candidate.bounds.midY - frame.midY)
            let normalizedDistanceScore = max(0, 1 - min(centerDistance / 500, 1))
            let titleScore: CGFloat
            if !candidate.title.isEmpty, !axWindow.title.isEmpty, candidate.title == axWindow.title {
                titleScore = 0.15
            } else {
                titleScore = 0
            }

            return (candidate, intersectionScore + normalizedDistanceScore * 0.25 + titleScore)
        }

        guard let best = matches.max(by: { $0.score < $1.score }),
              best.score >= 0.05 else {
            Logger.info("No visible CG candidate matched AX window for pid=\(ownerPID), window=\(axWindow.debugSummary)")
            return nil
        }

        Logger.debug("Matched AX window to CG candidate for arrange: score=\(String(format: "%.2f", best.score)), candidate={\(best.candidate.debugSummary)}, window={\(axWindow.debugSummary)}")
        return best.candidate
    }

    private func isArrangeable(_ window: AXWindowSnapshot) -> Bool {
        guard window.role == kAXWindowRole as String,
              window.subrole == kAXStandardWindowSubrole as String,
              window.frame != nil else {
            return false
        }

        return boolAttribute(window.element, kAXMinimizedAttribute as CFString) != true
    }

    private func arrange(windows: [ArrangeableWindow], inside bounds: CGRect) -> Int {
        let sortedWindows = windows.sorted {
            if abs($0.candidate.bounds.minY - $1.candidate.bounds.minY) > 8 {
                return $0.candidate.bounds.minY < $1.candidate.bounds.minY
            }
            return $0.candidate.bounds.minX < $1.candidate.bounds.minX
        }

        if sortedWindows.count == 3 {
            return arrangeThreeWindows(sortedWindows, inside: bounds)
        }

        if sortedWindows.count >= 4 {
            return arrangeBalancedRows(sortedWindows, inside: bounds)
        }

        let count = sortedWindows.count
        let columns = gridColumnCount(for: count)
        let rows = Int(ceil(Double(count) / Double(columns)))
        let gap: CGFloat = 10
        let cellWidth = (bounds.width - CGFloat(columns - 1) * gap) / CGFloat(columns)
        let cellHeight = (bounds.height - CGFloat(rows - 1) * gap) / CGFloat(rows)

        var movedCount = 0
        for (index, window) in sortedWindows.enumerated() {
            let row = index / columns
            let column = index % columns
            let frame = CGRect(
                x: bounds.minX + CGFloat(column) * (cellWidth + gap),
                y: bounds.minY + CGFloat(row) * (cellHeight + gap),
                width: cellWidth,
                height: cellHeight
            ).integral

            Logger.info("Auto arrange target: owner=\(window.candidate.ownerName), title=\"\(window.axWindow.title)\", frame=\(frame)")
            if setFrame(frame, for: window.axWindow.element) {
                movedCount += 1
            }
        }

        return movedCount
    }

    private func arrangeBalancedRows(_ windows: [ArrangeableWindow], inside bounds: CGRect) -> Int {
        let gap: CGFloat = 10
        let rowCounts = balancedRowCounts(for: windows.count)
        let rowHeight = floor((bounds.height - CGFloat(rowCounts.count - 1) * gap) / CGFloat(rowCounts.count))
        let rowSummary = rowCounts.map(String.init).joined(separator: "+")

        Logger.info("Auto arrange using balanced-row layout: count=\(windows.count), rows=\(rowSummary)")

        var plannedFrames: [PlannedFrame] = []
        var windowIndex = 0
        for (rowIndex, columnsInRow) in rowCounts.enumerated() {
            let rowY = bounds.minY + CGFloat(rowIndex) * (rowHeight + gap)
            let height = rowIndex == rowCounts.count - 1
                ? bounds.maxY - rowY
                : rowHeight
            let cellWidth = floor((bounds.width - CGFloat(columnsInRow - 1) * gap) / CGFloat(columnsInRow))

            for column in 0..<columnsInRow {
                guard windows.indices.contains(windowIndex) else {
                    break
                }

                let window = windows[windowIndex]
                let x = bounds.minX + CGFloat(column) * (cellWidth + gap)
                let width = column == columnsInRow - 1
                    ? bounds.maxX - x
                    : cellWidth
                let frame = CGRect(
                    x: x,
                    y: rowY,
                    width: width,
                    height: height
                ).integral

                plannedFrames.append(PlannedFrame(window: window, frame: frame))
                windowIndex += 1
            }
        }

        return apply(plannedFrames)
    }

    private func balancedRowCounts(for count: Int) -> [Int] {
        guard count > 0 else {
            return []
        }

        if count == 4 {
            return [2, 2]
        }

        let rowCount = max(1, Int(floor(sqrt(Double(count)))))
        let baseCount = count / rowCount
        let remainder = count % rowCount

        return (0..<rowCount).map { index in
            baseCount + (index < remainder ? 1 : 0)
        }
    }

    private func arrangeThreeWindows(_ windows: [ArrangeableWindow], inside bounds: CGRect) -> Int {
        let gap: CGFloat = 10
        guard let primary = windows.max(by: { lhs, rhs in
            let lhsScore = primaryWindowScore(lhs)
            let rhsScore = primaryWindowScore(rhs)
            if abs(lhsScore - rhsScore) > 1 {
                return lhsScore < rhsScore
            }
            return lhs.candidate.orderIndex > rhs.candidate.orderIndex
        }) else {
            return 0
        }

        let primaryWasOnRight = primary.originalFrame.midX >= bounds.midX
        let primaryWidth = floor((bounds.width - gap) * 0.50)
        let secondaryWidth = floor(bounds.width - gap - primaryWidth)
        let secondaryHeight = floor((bounds.height - gap) / 2)

        let primaryFrame: CGRect
        let secondaryX: CGFloat
        if primaryWasOnRight {
            secondaryX = bounds.minX
            primaryFrame = CGRect(
                x: bounds.maxX - primaryWidth,
                y: bounds.minY,
                width: primaryWidth,
                height: bounds.height
            ).integral
        } else {
            secondaryX = bounds.minX + primaryWidth + gap
            primaryFrame = CGRect(
                x: bounds.minX,
                y: bounds.minY,
                width: primaryWidth,
                height: bounds.height
            ).integral
        }

        let secondaryWindows = windows
            .filter { $0.candidate.windowID != primary.candidate.windowID }
            .sorted {
                if abs($0.originalFrame.minY - $1.originalFrame.minY) > 8 {
                    return $0.originalFrame.minY < $1.originalFrame.minY
                }
                return $0.originalFrame.minX < $1.originalFrame.minX
            }

        let targetFrames = [
            (primary, primaryFrame),
            (
                secondaryWindows[0],
                CGRect(
                    x: secondaryX,
                    y: bounds.minY,
                    width: secondaryWidth,
                    height: secondaryHeight
                ).integral
            ),
            (
                secondaryWindows[1],
                CGRect(
                    x: secondaryX,
                    y: bounds.minY + secondaryHeight + gap,
                    width: secondaryWidth,
                    height: bounds.height - secondaryHeight - gap
                ).integral
            )
        ]

        Logger.info(
            "Auto arrange using 1+2 layout for 3 windows: primaryOwner=\(primary.candidate.ownerName), primaryTitle=\"\(primary.axWindow.title)\", primarySide=\(primaryWasOnRight ? "right" : "left")"
        )

        return apply(targetFrames.map { PlannedFrame(window: $0.0, frame: $0.1) })
    }

    private func apply(_ plannedFrames: [PlannedFrame]) -> Int {
        var movedCount = 0
        for plannedFrame in plannedFrames {
            let window = plannedFrame.window
            let frame = plannedFrame.frame
            Logger.info("Auto arrange target: owner=\(window.candidate.ownerName), title=\"\(window.axWindow.title)\", frame=\(frame)")
            if setFrame(frame, for: window.axWindow.element) {
                movedCount += 1
            }
        }

        return movedCount
    }

    private func primaryWindowScore(_ window: ArrangeableWindow) -> CGFloat {
        let area = window.originalFrame.width * window.originalFrame.height
        let owner = window.candidate.ownerName.lowercased()
        let title = window.axWindow.title.lowercased()

        var weight: CGFloat = 1.0
        if owner.contains("chrome") ||
            owner.contains("safari") ||
            owner.contains("arc") ||
            owner.contains("firefox") ||
            owner.contains("xcode") ||
            owner.contains("codex") {
            weight += 0.35
        }

        if owner.contains("微信") ||
            owner.contains("wechat") ||
            owner.contains("slack") ||
            owner.contains("telegram") ||
            owner.contains("discord") {
            weight -= 0.30
        }

        if title.contains("backtest") ||
            title.contains("analysis") ||
            title.contains("earnings") ||
            title.contains("github") {
            weight += 0.15
        }

        return area * max(weight, 0.50)
    }

    private func gridColumnCount(for count: Int) -> Int {
        switch count {
        case 0...1:
            return 1
        case 2:
            return 2
        case 3...4:
            return 2
        default:
            return Int(ceil(sqrt(Double(count))))
        }
    }

    private func activeDisplayLayouts() -> [DisplayLayout] {
        let appKitLayouts = NSScreen.screens.compactMap { screen -> DisplayLayout? in
            guard let screenNumber = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
                return nil
            }

            let displayID = CGDirectDisplayID(screenNumber.uint32Value)
            let fullBounds = CGDisplayBounds(displayID)
            guard !fullBounds.isNull, !fullBounds.isEmpty else {
                return nil
            }

            let visibleBounds = cgWindowRect(
                forVisibleFrame: screen.visibleFrame,
                screenFrame: screen.frame,
                cgFullBounds: fullBounds
            ).intersection(fullBounds)
            let usableBounds = normalizedUsableBounds(visibleBounds, fallback: fullBounds)
            return DisplayLayout(fullBounds: fullBounds.integral, usableBounds: usableBounds.integral)
        }

        if !appKitLayouts.isEmpty {
            return appKitLayouts
        }

        var displayCount: UInt32 = 0
        var displayIDs = [CGDirectDisplayID](repeating: 0, count: 16)

        let result = CGGetActiveDisplayList(UInt32(displayIDs.count), &displayIDs, &displayCount)
        guard result == .success else {
            let bounds = CGDisplayBounds(CGMainDisplayID())
            return [DisplayLayout(fullBounds: bounds, usableBounds: normalizedUsableBounds(bounds, fallback: bounds))]
        }

        return displayIDs.prefix(Int(displayCount)).map { displayID in
            let bounds = CGDisplayBounds(displayID)
            return DisplayLayout(fullBounds: bounds, usableBounds: normalizedUsableBounds(bounds, fallback: bounds))
        }
    }

    private func normalizedUsableBounds(_ visibleBounds: CGRect, fallback fullBounds: CGRect) -> CGRect {
        let candidate = visibleBounds.isNull || visibleBounds.isEmpty ? fullBounds : visibleBounds
        let boundedCandidate = candidate.intersection(fullBounds)
        let usableCandidate = boundedCandidate.isNull || boundedCandidate.isEmpty ? fullBounds : boundedCandidate
        return usableCandidate.insetBy(dx: 8, dy: 8)
    }

    private func cgWindowRect(forVisibleFrame visibleFrame: CGRect, screenFrame: CGRect, cgFullBounds: CGRect) -> CGRect {
        let leftInset = max(0, visibleFrame.minX - screenFrame.minX)
        let rightInset = max(0, screenFrame.maxX - visibleFrame.maxX)
        let bottomInset = max(0, visibleFrame.minY - screenFrame.minY)
        let topInset = max(0, screenFrame.maxY - visibleFrame.maxY)

        return CGRect(
            x: cgFullBounds.minX + leftInset,
            y: cgFullBounds.minY + topInset,
            width: max(1, cgFullBounds.width - leftInset - rightInset),
            height: max(1, cgFullBounds.height - topInset - bottomInset)
        )
    }

    private func appKitRectToCGWindowRect(_ rect: CGRect) -> CGRect {
        let mainScreenHeight = NSScreen.screens.first?.frame.height ?? CGDisplayBounds(CGMainDisplayID()).height
        return CGRect(
            x: rect.minX,
            y: mainScreenHeight - rect.maxY,
            width: rect.width,
            height: rect.height
        )
    }

    private func displayIndex(for windowBounds: CGRect, in displayBounds: [CGRect]) -> Int {
        guard !displayBounds.isEmpty else {
            return 0
        }

        return displayBounds.indices.max { lhs, rhs in
            intersectionArea(windowBounds, displayBounds[lhs]) < intersectionArea(windowBounds, displayBounds[rhs])
        } ?? 0
    }

    private func intersectionArea(_ lhs: CGRect, _ rhs: CGRect) -> CGFloat {
        let intersection = lhs.intersection(rhs)
        guard !intersection.isNull, !intersection.isEmpty else {
            return 0
        }
        return intersection.width * intersection.height
    }

    private func setFrame(_ frame: CGRect, for element: AXUIElement) -> Bool {
        var size = frame.size
        var position = frame.origin

        guard let sizeValue = AXValueCreate(.cgSize, &size),
              let positionValue = AXValueCreate(.cgPoint, &position) else {
            Logger.error("Unable to create AX frame values for auto arrange")
            return false
        }

        let sizeResult = AXUIElementSetAttributeValue(element, kAXSizeAttribute as CFString, sizeValue)
        let positionResult = AXUIElementSetAttributeValue(element, kAXPositionAttribute as CFString, positionValue)

        if sizeResult == .success, positionResult == .success {
            if frameMatchesTarget(element: element, target: frame) {
                return true
            }

            let retryPositionResult = AXUIElementSetAttributeValue(element, kAXPositionAttribute as CFString, positionValue)
            let retrySizeResult = AXUIElementSetAttributeValue(element, kAXSizeAttribute as CFString, sizeValue)
            let finalPositionResult = AXUIElementSetAttributeValue(element, kAXPositionAttribute as CFString, positionValue)
            if retryPositionResult == .success,
               retrySizeResult == .success,
               finalPositionResult == .success {
                if let actualFrame = currentFrame(for: element) {
                    Logger.warning("Arranged window settled away from target after retry. target=\(frame), actual=\(actualFrame.integral)")
                }
                return true
            }

            Logger.warning(
                "Arranged window did not match target and retry failed. retryPositionError=\(retryPositionResult.rawValue), retrySizeError=\(retrySizeResult.rawValue), finalPositionError=\(finalPositionResult.rawValue)"
            )
            return true
        }

        Logger.warning("Failed to set arranged window frame. sizeError=\(sizeResult.rawValue), positionError=\(positionResult.rawValue)")
        return false
    }

    private func frameMatchesTarget(element: AXUIElement, target: CGRect) -> Bool {
        guard let actual = currentFrame(for: element) else {
            return true
        }

        let positionTolerance: CGFloat = 18
        let sizeTolerance: CGFloat = 28
        return abs(actual.minX - target.minX) <= positionTolerance &&
            abs(actual.minY - target.minY) <= positionTolerance &&
            abs(actual.width - target.width) <= sizeTolerance &&
            abs(actual.height - target.height) <= sizeTolerance
    }

    private func currentFrame(for element: AXUIElement) -> CGRect? {
        guard let position = pointAttribute(element, kAXPositionAttribute as CFString),
              let size = sizeAttribute(element, kAXSizeAttribute as CFString) else {
            return nil
        }

        return CGRect(origin: position, size: size)
    }

    private func pointAttribute(_ element: AXUIElement, _ attribute: CFString) -> CGPoint? {
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, attribute, &value)
        guard result == .success,
              let value,
              CFGetTypeID(value) == AXValueGetTypeID() else {
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
        guard result == .success,
              let value,
              CFGetTypeID(value) == AXValueGetTypeID() else {
            return nil
        }

        let axValue = value as! AXValue
        var size = CGSize.zero
        guard AXValueGetValue(axValue, .cgSize, &size) else {
            return nil
        }

        return size
    }

    private func boolAttribute(_ element: AXUIElement, _ attribute: CFString) -> Bool? {
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, attribute, &value)
        guard result == .success else {
            return nil
        }

        return value as? Bool
    }

    private func waitForMissionControlExitThenArrange(
        trigger: String,
        attempt: Int,
        startedAt: Date,
        preferCurrentMouseExitPoint: Bool
    ) {
        let detection = currentMissionControlDetection()
        if !detection.isLikelyActive {
            let elapsed = Date().timeIntervalSince(startedAt)
            Logger.info(
                "Mission Control exited before auto arrange: trigger=\(trigger), attempts=\(attempt), elapsed=\(String(format: "%.2f", elapsed))s, detection=\(detection.debugSummary)"
            )
            DispatchQueue.main.asyncAfter(deadline: .now() + Constants.missionControlExitSettleDelay) { [weak self] in
                self?.arrangeVisibleWindows(trigger: trigger)
            }
            return
        }

        guard attempt < Constants.maxMissionControlExitAttempts else {
            let elapsed = Date().timeIntervalSince(startedAt)
            Logger.warning(
                "Mission Control did not exit after auto arrange request; cancelling arrange to avoid delayed surprise. trigger=\(trigger), attempts=\(attempt), elapsed=\(String(format: "%.2f", elapsed))s, detection=\(detection.debugSummary)"
            )
            return
        }

        if attempt == 3 {
            Logger.info("Mission Control still active after Escape; trying Control+Up fallback")
            postControlUpKey()
        } else {
            requestMissionControlExit(preferCurrentMouseExitPoint: preferCurrentMouseExitPoint)
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + Constants.missionControlExitRetryDelay) { [weak self] in
            self?.waitForMissionControlExitThenArrange(
                trigger: trigger,
                attempt: attempt + 1,
                startedAt: startedAt,
                preferCurrentMouseExitPoint: preferCurrentMouseExitPoint
            )
        }
    }

    private func currentMissionControlDetection() -> MissionControlDetection {
        let mousePoint = windowEnumerator.currentMouseLocationInCGWindowCoordinates(logResult: false)
        let entries = windowEnumerator.allWindowEntries(options: [.optionOnScreenOnly])
        return missionControlDetector.detect(mousePoint: mousePoint, entries: entries)
    }

    private func postEscapeKey() {
        let escapeKeyCode: CGKeyCode = 53
        postKey(escapeKeyCode)
    }

    private func postControlUpKey() {
        let upArrowKeyCode: CGKeyCode = 126
        postKey(upArrowKeyCode, flags: .maskControl)
    }

    private func requestMissionControlExit(preferCurrentMouseExitPoint: Bool) {
        postEscapeKey()

        let detection = currentMissionControlDetection()
        if preferCurrentMouseExitPoint {
            let currentMousePoint = windowEnumerator.currentMouseLocationInCGWindowCoordinates(logResult: false)
            Logger.info("Clicking current Mission Control blank area to request exit: point=\(currentMousePoint)")
            postMouseClick(at: currentMousePoint)
            return
        }

        guard let blankPoint = blankMissionControlExitPoint(from: detection) else {
            Logger.info("No safe Mission Control blank point found for synthetic exit click")
            return
        }

        let currentMousePoint = windowEnumerator.currentMouseLocationInCGWindowCoordinates(logResult: false)
        Logger.info("Clicking Mission Control blank area to request exit: point=\(blankPoint), restoreMouse=\(currentMousePoint)")
        postMouseClick(at: blankPoint)

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            self?.postMouseMove(to: currentMousePoint)
        }
    }

    private func blankMissionControlExitPoint(from detection: MissionControlDetection) -> CGPoint? {
        let mousePoint = windowEnumerator.currentMouseLocationInCGWindowCoordinates(logResult: false)
        let displayBounds = DisplayBoundsHelper.displayBounds(containing: mousePoint)
        let thumbnailBounds = windowEnumerator
            .visibleWindowCandidates(from: detection.entries)
            .map { $0.bounds.insetBy(dx: -24, dy: -24) }

        let xFractions: [CGFloat] = [0.50, 0.08, 0.92, 0.25, 0.75, 0.14, 0.86]
        let yFractions: [CGFloat] = [0.14, 0.86, 0.50, 0.25, 0.75, 0.08, 0.92]
        for yFraction in yFractions {
            for xFraction in xFractions {
                let point = CGPoint(
                    x: displayBounds.minX + displayBounds.width * xFraction,
                    y: displayBounds.minY + displayBounds.height * yFraction
                )

                guard displayBounds.contains(point),
                      !thumbnailBounds.contains(where: { $0.contains(point) }) else {
                    continue
                }

                return point
            }
        }

        return nil
    }

    private func postKey(_ keyCode: CGKeyCode, flags: CGEventFlags = []) {
        let source = CGEventSource(stateID: .hidSystemState)
        let keyDown = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true)
        let keyUp = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false)

        keyDown?.flags = flags
        keyUp?.flags = flags

        keyDown?.post(tap: .cghidEventTap)
        keyUp?.post(tap: .cghidEventTap)
    }

    private func postMouseClick(at point: CGPoint) {
        let source = CGEventSource(stateID: .hidSystemState)
        let down = CGEvent(
            mouseEventSource: source,
            mouseType: .leftMouseDown,
            mouseCursorPosition: point,
            mouseButton: .left
        )
        let up = CGEvent(
            mouseEventSource: source,
            mouseType: .leftMouseUp,
            mouseCursorPosition: point,
            mouseButton: .left
        )

        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)
    }

    private func postMouseMove(to point: CGPoint) {
        let source = CGEventSource(stateID: .hidSystemState)
        let event = CGEvent(
            mouseEventSource: source,
            mouseType: .mouseMoved,
            mouseCursorPosition: point,
            mouseButton: .left
        )
        event?.post(tap: .cghidEventTap)
    }
}
