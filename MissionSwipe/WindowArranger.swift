import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

final class WindowArranger {
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

    private let permissionManager: AccessibilityPermissionManager
    private let windowEnumerator: WindowEnumerator
    private let axWindowController: AXWindowController
    private var undoSnapshots: [AXWindowSnapshot] = []

    init(
        permissionManager: AccessibilityPermissionManager = AccessibilityPermissionManager(),
        windowEnumerator: WindowEnumerator = WindowEnumerator(),
        axWindowController: AXWindowController = AXWindowController()
    ) {
        self.permissionManager = permissionManager
        self.windowEnumerator = windowEnumerator
        self.axWindowController = axWindowController
    }

    func arrangeAfterExitingMissionControl(trigger: String) {
        Logger.info("Auto arrange requested from \(trigger); exiting Mission Control before arranging")
        postEscapeKey()

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { [weak self] in
            self?.arrangeVisibleWindows(trigger: trigger)
        }
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
        let appKitLayouts = NSScreen.screens.map { screen in
            let fullBounds = appKitRectToCGWindowRect(screen.frame)
            let visibleBounds = appKitRectToCGWindowRect(screen.visibleFrame).intersection(fullBounds)
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
            return true
        }

        Logger.warning("Failed to set arranged window frame. sizeError=\(sizeResult.rawValue), positionError=\(positionResult.rawValue)")
        return false
    }

    private func boolAttribute(_ element: AXUIElement, _ attribute: CFString) -> Bool? {
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, attribute, &value)
        guard result == .success else {
            return nil
        }

        return value as? Bool
    }

    private func postEscapeKey() {
        let escapeKeyCode: CGKeyCode = 53
        let source = CGEventSource(stateID: .combinedSessionState)
        let keyDown = CGEvent(keyboardEventSource: source, virtualKey: escapeKeyCode, keyDown: true)
        let keyUp = CGEvent(keyboardEventSource: source, virtualKey: escapeKeyCode, keyDown: false)

        keyDown?.post(tap: .cgSessionEventTap)
        keyUp?.post(tap: .cgSessionEventTap)
    }
}
