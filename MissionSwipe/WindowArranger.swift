import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

final class WindowArranger {
    enum PrimarySide: String {
        case left
        case right
    }

    enum PrimaryPlacement: String {
        case left
        case right
        case topLeft
        case topRight
        case bottomLeft
        case bottomRight

        init(side: PrimarySide) {
            switch side {
            case .left:
                self = .left
            case .right:
                self = .right
            }
        }
    }

    struct SmartFitReport {
        let totalWindows: Int
        let arrangedCount: Int
        let minimizedCount: Int
        let stackedCount: Int
        let stubbornCount: Int
        let adapted: Bool
        let strategy: SmartFitOverflowStrategy
    }

    private enum Constants {
        static let missionControlExitRetryDelay: TimeInterval = 0.18
        static let missionControlExitSettleDelay: TimeInterval = 0.45
        static let maxMissionControlExitAttempts = 8
        // Settle delays between AX writes during setFrame. macOS dispatches AX
        // attribute writes to the target process; if a size write arrives before
        // the previous position write has been processed, the target may apply
        // only one of them (observed on Chrome on macOS 26.3.1 / M4 / 16GB —
        // setPosition + setSize within 4ms left windows at Chrome's default size).
        // Cross-display moves need longer because macOS also has to migrate the
        // window to the new display, which can take an extra frame.
        static let sameDisplaySettleDelay: TimeInterval = 0.02
        static let sameDisplayVerifyDelay: TimeInterval = 0.03
        static let crossDisplaySettleDelay: TimeInterval = 0.06
        static let crossDisplaySizeSettleDelay: TimeInterval = 0.04
        static let stubbornSizeSlack: CGFloat = 42
        static let overlapMinimumArea: CGFloat = 2_500
        static let smartFitMinWindowCount = 4
        static let windowGap: CGFloat = 4
        static let stackPeekOffsetX: CGFloat = 48
        static let stackPeekOffsetY: CGFloat = 48
        static let stackPeekMinUsableWidth: CGFloat = 360
        static let stackPeekMinUsableHeight: CGFloat = 260
        // When packing a non-stubborn (flexible) window into the adaptive second pass,
        // pretend it is no wider/taller than this. Each cell will get stretched up to
        // fill the row/column afterwards, so these numbers only decide row breaks.
        // Using a small flexible footprint keeps multiple flexible windows in the
        // same row instead of pretending they each need their original tile size.
        static let flexibleMinPackWidth: CGFloat = 480
        static let flexibleMinPackHeight: CGFloat = 375
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
        let screen: NSScreen?
    }

    private struct PlannedFrame {
        let window: ArrangeableWindow
        let frame: CGRect
    }

    private struct AppliedFrame {
        let window: ArrangeableWindow
        let target: CGRect
        let actual: CGRect?
        let didMove: Bool
    }

    private struct UndoSnapshot {
        let window: AXWindowSnapshot
        let wasMinimized: Bool
    }

    private struct ArrangeOutcome {
        var arrangedCount: Int = 0
        var minimizedCount: Int = 0
        var stackedCount: Int = 0
        var stubbornCount: Int = 0
        var adapted: Bool = false
    }

    var isSmartFitEnabled: Bool = true
    var smartFitCapacityProfile: SmartFitCapacityProfile = .default
    var smartFitOverflowStrategy: SmartFitOverflowStrategy = .minimize
    var smartFitOverlapTolerance: Double = 0.06
    var threeWindowLayout: ThreeWindowLayout = .primaryPlusTwo
    var fourWindowLayout: FourWindowLayout = .grid2x2
    var fiveWindowLayout: FiveWindowLayout = .threeOverTwoEqual
    var onSmartFitReport: ((SmartFitReport) -> Void)?

    private let permissionManager: AccessibilityPermissionManager
    private let windowEnumerator: WindowEnumerator
    private let axWindowController: AXWindowController
    private let missionControlDetector: MissionControlDetector
    private var undoSnapshots: [UndoSnapshot] = []

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
            preferCurrentMouseExitPoint: preferCurrentMouseExitPoint,
            primaryWindow: nil,
            primaryPlacement: nil
        )
    }

    func arrangeAfterExitingMissionControl(
        trigger: String,
        primaryWindow: AXWindowSnapshot,
        primarySide: PrimarySide,
        preferCurrentMouseExitPoint: Bool = false
    ) {
        Logger.info("Primary-window auto arrange requested from \(trigger); primarySide=\(primarySide.rawValue), primary={\(primaryWindow.debugSummary)}")
        requestMissionControlExit(preferCurrentMouseExitPoint: preferCurrentMouseExitPoint)
        waitForMissionControlExitThenArrange(
            trigger: trigger,
            attempt: 1,
            startedAt: Date(),
            preferCurrentMouseExitPoint: preferCurrentMouseExitPoint,
            primaryWindow: primaryWindow,
            primaryPlacement: PrimaryPlacement(side: primarySide)
        )
    }

    func arrangeAfterExitingMissionControl(
        trigger: String,
        primaryWindow: AXWindowSnapshot,
        primaryPlacement: PrimaryPlacement,
        preferCurrentMouseExitPoint: Bool = false
    ) {
        Logger.info("Primary-window auto arrange requested from \(trigger); primaryPlacement=\(primaryPlacement.rawValue), primary={\(primaryWindow.debugSummary)}")
        requestMissionControlExit(preferCurrentMouseExitPoint: preferCurrentMouseExitPoint)
        waitForMissionControlExitThenArrange(
            trigger: trigger,
            attempt: 1,
            startedAt: Date(),
            preferCurrentMouseExitPoint: preferCurrentMouseExitPoint,
            primaryWindow: primaryWindow,
            primaryPlacement: primaryPlacement
        )
    }

    func arrangeVisibleWindows(trigger: String) {
        Logger.info("Starting visible-window auto arrange from \(trigger)")
        arrangeVisibleWindowsInternal(trigger: trigger, primaryWindow: nil, primarySide: nil)
    }

    func arrangeVisibleWindows(
        trigger: String,
        primaryWindow: AXWindowSnapshot,
        primaryPlacement: PrimaryPlacement
    ) {
        Logger.info("Starting visible-window primary auto arrange from \(trigger); primaryPlacement=\(primaryPlacement.rawValue), primary={\(primaryWindow.debugSummary)}")
        arrangeVisibleWindowsInternal(
            trigger: trigger,
            primaryWindow: primaryWindow,
            primaryPlacement: primaryPlacement,
            scopeToPrimaryDisplay: true
        )
    }

    func arrangeableWindowCountForPreview(primaryWindow: AXWindowSnapshot) -> Int {
        guard permissionManager.isAccessibilityTrusted else {
            Logger.error("Accessibility permission is missing. Cannot count arrangeable windows for preview.")
            return 0
        }

        let candidates = windowEnumerator.visibleWindowCandidates()
        let arrangeableWindows = collectArrangeableWindows(from: candidates)
        guard let primaryFrame = primaryWindow.frame else {
            return arrangeableWindows.count
        }

        let displayLayouts = activeDisplayLayouts()
        let displayBounds = displayLayouts.map(\.fullBounds)
        let primaryDisplayIndex = displayIndex(for: primaryFrame, in: displayBounds)
        let count = arrangeableWindows.filter { window in
            displayIndex(for: window.displayFrame, in: displayBounds) == primaryDisplayIndex
        }.count
        Logger.info("Preview arrangeable window count scoped to display \(primaryDisplayIndex): count=\(count), total=\(arrangeableWindows.count)")
        return count
    }

    private func arrangeVisibleWindowsInternal(trigger: String, primaryWindow: AXWindowSnapshot?, primarySide: PrimarySide?) {
        arrangeVisibleWindowsInternal(
            trigger: trigger,
            primaryWindow: primaryWindow,
            primaryPlacement: primarySide.map(PrimaryPlacement.init(side:)),
            scopeToPrimaryDisplay: false
        )
    }

    private func arrangeVisibleWindowsInternal(
        trigger: String,
        primaryWindow: AXWindowSnapshot?,
        primaryPlacement: PrimaryPlacement?,
        scopeToPrimaryDisplay: Bool
    ) {
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

        undoSnapshots = arrangeableWindows.map { window in
            UndoSnapshot(
                window: window.axWindow,
                wasMinimized: boolAttribute(window.axWindow.element, kAXMinimizedAttribute as CFString) == true
            )
        }
        let displayLayouts = activeDisplayLayouts()
        let displayBounds = displayLayouts.map(\.fullBounds)
        var groupedWindows = Dictionary(grouping: arrangeableWindows) { window in
            displayIndex(for: window.displayFrame, in: displayBounds)
        }

        if scopeToPrimaryDisplay,
           let primaryFrame = primaryWindow?.frame {
            let primaryDisplayIndex = displayIndex(for: primaryFrame, in: displayBounds)
            groupedWindows = groupedWindows.filter { displayIndex, _ in
                displayIndex == primaryDisplayIndex
            }
            Logger.info("Auto arrange scoped to primary display index \(primaryDisplayIndex)")
        }

        var movedCount = 0
        var totalMinimized = 0
        var totalStacked = 0
        var totalStubborn = 0
        var didAdaptAny = false
        for (displayIndex, windows) in groupedWindows {
            guard displayLayouts.indices.contains(displayIndex) else {
                continue
            }

            let layout = displayLayouts[displayIndex]
            Logger.info("Auto arrange display layout: full=\(layout.fullBounds.integral), usable=\(layout.usableBounds.integral)")
            if let primaryWindow,
               let primaryPlacement,
               let primary = windows.first(where: { isSameWindow($0.axWindow, primaryWindow) }) {
                let result = arrangeWithPrimaryWindow(primary, windows: windows, primaryPlacement: primaryPlacement, inside: layout.usableBounds)
                movedCount += result.arrangedCount
                totalMinimized += result.minimizedCount
                totalStacked += result.stackedCount
                totalStubborn += result.stubbornCount
                if result.adapted { didAdaptAny = true }
            } else {
                let result = arrange(windows: windows, inside: layout.usableBounds, screen: layout.screen)
                movedCount += result.arrangedCount
                totalMinimized += result.minimizedCount
                totalStacked += result.stackedCount
                totalStubborn += result.stubbornCount
                if result.adapted { didAdaptAny = true }
            }
        }

        Logger.info(
            "Visible-window auto arrange finished. moved=\(movedCount), minimized=\(totalMinimized), stacked=\(totalStacked), stubborn=\(totalStubborn), adapted=\(didAdaptAny), strategy=\(smartFitOverflowStrategy.rawValue), total=\(arrangeableWindows.count)"
        )

        let report = SmartFitReport(
            totalWindows: arrangeableWindows.count,
            arrangedCount: movedCount,
            minimizedCount: totalMinimized,
            stackedCount: totalStacked,
            stubbornCount: totalStubborn,
            adapted: didAdaptAny,
            strategy: smartFitOverflowStrategy
        )
        onSmartFitReport?(report)
    }

    func undoLastArrange() {
        guard !undoSnapshots.isEmpty else {
            Logger.info("No previous auto arrange snapshot to undo")
            return
        }

        var restoredCount = 0
        var restoredMinimizedCount = 0
        for snapshot in undoSnapshots {
            if !snapshot.wasMinimized {
                if setMinimized(false, for: snapshot.window.element) {
                    restoredMinimizedCount += 1
                }
            }

            guard let frame = snapshot.window.frame else {
                continue
            }

            if setFrame(frame, for: snapshot.window.element) {
                restoredCount += 1
            }
        }

        Logger.info("Undo last auto arrange finished. restored=\(restoredCount), unminimized=\(restoredMinimizedCount), total=\(undoSnapshots.count)")
        undoSnapshots.removeAll()
    }

    private func collectArrangeableWindows(from candidates: [CGWindowCandidate]) -> [ArrangeableWindow] {
        var seenWindowKeys = Set<String>()
        var usedCandidateIDs = Set<CGWindowID>()
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

                let candidate = bestCandidate(
                    for: axWindow,
                    ownerPID: ownerPID,
                    candidates: pidCandidates,
                    excluding: usedCandidateIDs
                )
                guard let candidate else {
                    Logger.info("Skipping AX window without a visible CG candidate: pid=\(ownerPID), window=\(axWindow.debugSummary)")
                    continue
                }
                usedCandidateIDs.insert(candidate.windowID)

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

    private func bestCandidate(
        for axWindow: AXWindowSnapshot,
        ownerPID: pid_t,
        candidates: [CGWindowCandidate],
        excluding usedCandidateIDs: Set<CGWindowID>
    ) -> CGWindowCandidate? {
        guard let frame = axWindow.frame else {
            return nil
        }

        let availableCandidates = candidates.filter { !usedCandidateIDs.contains($0.windowID) }
        let matches = availableCandidates.map { candidate -> (candidate: CGWindowCandidate, score: CGFloat) in
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
            Logger.info("No unused visible CG candidate matched AX window for pid=\(ownerPID), usedCandidates=\(usedCandidateIDs.count), window=\(axWindow.debugSummary)")
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

    private func arrange(windows: [ArrangeableWindow], inside bounds: CGRect, screen: NSScreen?) -> ArrangeOutcome {
        let spatiallySorted = windows.sorted {
            if abs($0.candidate.bounds.minY - $1.candidate.bounds.minY) > 8 {
                return $0.candidate.bounds.minY < $1.candidate.bounds.minY
            }
            return $0.candidate.bounds.minX < $1.candidate.bounds.minX
        }

        var working = spatiallySorted
        var capacityMinimizedCount = 0
        if isSmartFitEnabled, spatiallySorted.count >= Constants.smartFitMinWindowCount {
            let capacity = windowCapacity(for: screen)
            if spatiallySorted.count > capacity {
                let byMRU = spatiallySorted.sorted { $0.candidate.orderIndex < $1.candidate.orderIndex }
                let keepIDs = Set(byMRU.prefix(capacity).map(\.candidate.windowID))
                let kept = spatiallySorted.filter { keepIDs.contains($0.candidate.windowID) }
                let trimmed = spatiallySorted.filter { !keepIDs.contains($0.candidate.windowID) }
                Logger.info("Smart Fit capacity cap: capacity=\(capacity), total=\(spatiallySorted.count), keep=\(kept.count), minimize=\(trimmed.count)")
                working = kept
                for window in trimmed {
                    Logger.info("Smart Fit capacity minimize: owner=\(window.candidate.ownerName), title=\"\(window.axWindow.title)\"")
                    if setMinimized(true, for: window.axWindow.element) {
                        capacityMinimizedCount += 1
                    }
                }
            }
        }

        var outcome: ArrangeOutcome
        switch working.count {
        case 3:
            outcome = arrangeThreeWindows(working, inside: bounds)
        case 4:
            outcome = arrangeFourWindows(working, inside: bounds)
        case 5:
            outcome = arrangeFiveWindows(working, inside: bounds)
        default:
            if working.count >= 6 {
                outcome = arrangeBalancedRows(working, inside: bounds)
            } else {
                outcome = arrangeSimpleGrid(working, inside: bounds)
            }
        }
        outcome.minimizedCount += capacityMinimizedCount
        return outcome
    }

    private func arrangeStackWithPeek(_ windows: [ArrangeableWindow], inside bounds: CGRect) -> ArrangeOutcome {
        // Sort by area descending: biggest window goes to the back (placed and raised
        // first; later raises push it down the z-order). Smallest is raised last so it
        // ends up fully visible on top.
        let bigToSmall = windows.sorted {
            ($0.originalFrame.width * $0.originalFrame.height) >
            ($1.originalFrame.width * $1.originalFrame.height)
        }
        let count = bigToSmall.count
        guard count > 0 else {
            return ArrangeOutcome()
        }

        // Each window fills from its offset corner down to the screen's bottom-right.
        // Each subsequent layer is pushed (offsetX, offsetY) in/down, so every layer
        // shows a peek strip on its top and left edges where the layer behind it sticks
        // out. Right and bottom edges all align at the screen edge.
        //
        // If there are so many windows that the front-most one would shrink below a
        // usable size, the offset is scaled down proportionally so everyone stays
        // big enough to use.
        let stepsAvailable = CGFloat(max(1, count - 1))
        let maxOffsetX = max(0, (bounds.width - Constants.stackPeekMinUsableWidth) / stepsAvailable)
        let maxOffsetY = max(0, (bounds.height - Constants.stackPeekMinUsableHeight) / stepsAvailable)
        let offsetX = min(Constants.stackPeekOffsetX, maxOffsetX)
        let offsetY = min(Constants.stackPeekOffsetY, maxOffsetY)

        Logger.info("Stack-with-peek arrange: count=\(count), bounds=\(bounds.integral), offset=(\(Int(offsetX)),\(Int(offsetY)))")

        var outcome = ArrangeOutcome()
        for (index, window) in bigToSmall.enumerated() {
            let stepX = CGFloat(index) * offsetX
            let stepY = CGFloat(index) * offsetY
            let x = bounds.minX + stepX
            let y = bounds.minY + stepY
            let width = bounds.maxX - x
            let height = bounds.maxY - y

            let frame = CGRect(x: x, y: y, width: width, height: height).integral
            Logger.info("Stack-with-peek target: owner=\(window.candidate.ownerName), title=\"\(window.axWindow.title)\", layer=\(index), originalArea=\(Int(window.originalFrame.width * window.originalFrame.height)), frame=\(frame)")
            if setFrame(frame, for: window.axWindow.element) {
                outcome.stackedCount += 1
            }

            // Raise as we go: iteration order becomes z-order.
            // Big-to-small iteration → biggest raised first (deepest), smallest raised
            // last (on top).
            AXUIElementPerformAction(window.axWindow.element, kAXRaiseAction as CFString)
        }

        outcome.arrangedCount = outcome.stackedCount
        return outcome
    }

    private func arrangeSimpleGrid(_ windows: [ArrangeableWindow], inside bounds: CGRect) -> ArrangeOutcome {
        let count = windows.count
        guard count > 0 else {
            return ArrangeOutcome()
        }
        let columns = gridColumnCount(for: count)
        let rows = Int(ceil(Double(count) / Double(columns)))
        let gap: CGFloat = Constants.windowGap
        let cellWidth = (bounds.width - CGFloat(columns - 1) * gap) / CGFloat(columns)
        let cellHeight = (bounds.height - CGFloat(rows - 1) * gap) / CGFloat(rows)

        var planned: [PlannedFrame] = []
        for (index, window) in windows.enumerated() {
            let row = index / columns
            let column = index % columns
            let frame = CGRect(
                x: bounds.minX + CGFloat(column) * (cellWidth + gap),
                y: bounds.minY + CGFloat(row) * (cellHeight + gap),
                width: cellWidth,
                height: cellHeight
            ).integral
            planned.append(PlannedFrame(window: window, frame: frame))
        }
        return applyWithVerify(planned, inside: bounds, gap: gap)
    }

    private func arrangeWithPrimaryWindow(
        _ primary: ArrangeableWindow,
        windows: [ArrangeableWindow],
        primaryPlacement: PrimaryPlacement,
        inside bounds: CGRect
    ) -> ArrangeOutcome {
        let gap: CGFloat = Constants.windowGap
        let primaryFrame = primaryFrame(for: primaryPlacement, inside: bounds, gap: gap)
        let secondaryRegions = secondaryRegions(for: primaryPlacement, inside: bounds, primaryFrame: primaryFrame, gap: gap)

        let secondaryWindows = windows
            .filter { !isSameWindow($0.axWindow, primary.axWindow) }
            .sorted {
                if abs($0.originalFrame.minY - $1.originalFrame.minY) > 8 {
                    return $0.originalFrame.minY < $1.originalFrame.minY
                }
                return $0.originalFrame.minX < $1.originalFrame.minX
            }

        var plannedFrames = [PlannedFrame(window: primary, frame: primaryFrame)]
        plannedFrames += secondaryFrames(for: secondaryWindows, inside: secondaryRegions, gap: gap)

        Logger.info(
            "Auto arrange using primary placement layout: primaryOwner=\(primary.candidate.ownerName), primaryTitle=\"\(primary.axWindow.title)\", primaryPlacement=\(primaryPlacement.rawValue), secondaryCount=\(secondaryWindows.count)"
        )

        return applyWithVerify(plannedFrames, inside: bounds, gap: gap, allowMinimization: false)
    }

    private func primaryFrame(for placement: PrimaryPlacement, inside bounds: CGRect, gap: CGFloat) -> CGRect {
        switch placement {
        case .left:
            let width = floor((bounds.width - gap) * 0.50)
            return CGRect(x: bounds.minX, y: bounds.minY, width: width, height: bounds.height).integral
        case .right:
            let width = floor((bounds.width - gap) * 0.50)
            return CGRect(x: bounds.maxX - width, y: bounds.minY, width: width, height: bounds.height).integral
        case .topLeft:
            let width = floor((bounds.width - gap) * 0.50)
            let height = floor((bounds.height - gap) * 0.50)
            return CGRect(x: bounds.minX, y: bounds.minY, width: width, height: height).integral
        case .topRight:
            let width = floor((bounds.width - gap) * 0.50)
            let height = floor((bounds.height - gap) * 0.50)
            return CGRect(x: bounds.maxX - width, y: bounds.minY, width: width, height: height).integral
        case .bottomLeft:
            let width = floor((bounds.width - gap) * 0.50)
            let height = floor((bounds.height - gap) * 0.50)
            return CGRect(x: bounds.minX, y: bounds.maxY - height, width: width, height: height).integral
        case .bottomRight:
            let width = floor((bounds.width - gap) * 0.50)
            let height = floor((bounds.height - gap) * 0.50)
            return CGRect(x: bounds.maxX - width, y: bounds.maxY - height, width: width, height: height).integral
        }
    }

    private func secondaryRegions(
        for placement: PrimaryPlacement,
        inside bounds: CGRect,
        primaryFrame: CGRect,
        gap: CGFloat
    ) -> [CGRect] {
        switch placement {
        case .left:
            return [CGRect(x: primaryFrame.maxX + gap, y: bounds.minY, width: bounds.maxX - primaryFrame.maxX - gap, height: bounds.height).integral]
        case .right:
            return [CGRect(x: bounds.minX, y: bounds.minY, width: primaryFrame.minX - bounds.minX - gap, height: bounds.height).integral]
        case .topLeft:
            return [
                CGRect(x: primaryFrame.maxX + gap, y: bounds.minY, width: bounds.maxX - primaryFrame.maxX - gap, height: bounds.height).integral,
                CGRect(x: bounds.minX, y: primaryFrame.maxY + gap, width: primaryFrame.width, height: bounds.maxY - primaryFrame.maxY - gap).integral
            ]
        case .topRight:
            return [
                CGRect(x: bounds.minX, y: bounds.minY, width: primaryFrame.minX - bounds.minX - gap, height: bounds.height).integral,
                CGRect(x: primaryFrame.minX, y: primaryFrame.maxY + gap, width: primaryFrame.width, height: bounds.maxY - primaryFrame.maxY - gap).integral
            ]
        case .bottomLeft:
            return [
                CGRect(x: primaryFrame.maxX + gap, y: bounds.minY, width: bounds.maxX - primaryFrame.maxX - gap, height: bounds.height).integral,
                CGRect(x: bounds.minX, y: bounds.minY, width: primaryFrame.width, height: primaryFrame.minY - bounds.minY - gap).integral
            ]
        case .bottomRight:
            return [
                CGRect(x: bounds.minX, y: bounds.minY, width: primaryFrame.minX - bounds.minX - gap, height: bounds.height).integral,
                CGRect(x: primaryFrame.minX, y: bounds.minY, width: primaryFrame.width, height: primaryFrame.minY - bounds.minY - gap).integral
            ]
        }
    }

    private func secondaryFrames(
        for windows: [ArrangeableWindow],
        inside regions: [CGRect],
        gap: CGFloat
    ) -> [PlannedFrame] {
        let usableRegions = regions.filter { !$0.isNull && !$0.isEmpty && $0.width >= 80 && $0.height >= 80 }
        guard !windows.isEmpty, !usableRegions.isEmpty else {
            return []
        }

        guard usableRegions.count > 1, windows.count > 1 else {
            return secondaryColumnFrames(for: windows, inside: usableRegions[0], gap: gap)
        }

        let totalArea = usableRegions.reduce(CGFloat(0)) { partial, region in
            partial + region.width * region.height
        }
        var remainingWindows = windows
        var frames: [PlannedFrame] = []

        for (index, region) in usableRegions.enumerated() {
            guard !remainingWindows.isEmpty else {
                break
            }

            let count: Int
            if index == usableRegions.count - 1 {
                count = remainingWindows.count
            } else {
                let proportional = Int(round(CGFloat(windows.count) * (region.width * region.height / max(totalArea, 1))))
                count = min(max(1, proportional), remainingWindows.count - 1)
            }

            let regionWindows = Array(remainingWindows.prefix(count))
            remainingWindows.removeFirst(count)
            frames += secondaryColumnFrames(for: regionWindows, inside: region, gap: gap)
        }

        return frames
    }

    private func secondaryColumnFrames(
        for windows: [ArrangeableWindow],
        inside bounds: CGRect,
        gap: CGFloat
    ) -> [PlannedFrame] {
        guard !windows.isEmpty else {
            return []
        }

        if windows.count <= 3 {
            let cellHeight = floor((bounds.height - CGFloat(windows.count - 1) * gap) / CGFloat(windows.count))
            return windows.enumerated().map { index, window in
                let y = bounds.minY + CGFloat(index) * (cellHeight + gap)
                let height = index == windows.count - 1 ? bounds.maxY - y : cellHeight
                return PlannedFrame(
                    window: window,
                    frame: CGRect(x: bounds.minX, y: y, width: bounds.width, height: height).integral
                )
            }
        }

        let columns = 2
        let rows = Int(ceil(Double(windows.count) / Double(columns)))
        let cellWidth = floor((bounds.width - CGFloat(columns - 1) * gap) / CGFloat(columns))
        let cellHeight = floor((bounds.height - CGFloat(rows - 1) * gap) / CGFloat(rows))

        return windows.enumerated().map { index, window in
            let row = index / columns
            let column = index % columns
            let x = bounds.minX + CGFloat(column) * (cellWidth + gap)
            let y = bounds.minY + CGFloat(row) * (cellHeight + gap)
            let width = column == columns - 1 ? bounds.maxX - x : cellWidth
            let height = row == rows - 1 ? bounds.maxY - y : cellHeight
            return PlannedFrame(
                window: window,
                frame: CGRect(x: x, y: y, width: width, height: height).integral
            )
        }
    }

    private func arrangeFourWindows(_ windows: [ArrangeableWindow], inside bounds: CGRect) -> ArrangeOutcome {
        switch fourWindowLayout {
        case .grid2x2:
            return arrangeBalancedRows(windows, inside: bounds)
        case .primaryPlusThree:
            return arrangePrimaryPlusN(windows, inside: bounds, secondaryCount: 3)
        }
    }

    private func arrangeFiveWindows(_ windows: [ArrangeableWindow], inside bounds: CGRect) -> ArrangeOutcome {
        switch fiveWindowLayout {
        case .threeOverTwoEqual:
            return arrangeBalancedRows(windows, inside: bounds)
        case .leftTwoBigRightThreeSmall:
            return arrangeFiveAsLeftTwoBigRightThreeSmall(windows, inside: bounds)
        case .bottomTwoBigTopThreeSmall:
            return arrangeFiveAsBottomTwoBigTopThreeSmall(windows, inside: bounds)
        }
    }

    private func arrangeColumnsLayout(_ windows: [ArrangeableWindow], inside bounds: CGRect, columnCount: Int) -> ArrangeOutcome {
        let gap: CGFloat = Constants.windowGap
        let count = windows.count
        guard count > 0, columnCount > 0 else {
            return ArrangeOutcome()
        }

        let sorted = windows.sorted { lhs, rhs in
            if abs(lhs.originalFrame.minX - rhs.originalFrame.minX) > 8 {
                return lhs.originalFrame.minX < rhs.originalFrame.minX
            }
            return lhs.originalFrame.minY < rhs.originalFrame.minY
        }

        let columnWidth = floor((bounds.width - CGFloat(columnCount - 1) * gap) / CGFloat(columnCount))
        var planned: [PlannedFrame] = []
        for (index, window) in sorted.enumerated() {
            let x = bounds.minX + CGFloat(index) * (columnWidth + gap)
            let width = index == count - 1 ? bounds.maxX - x : columnWidth
            let frame = CGRect(x: x, y: bounds.minY, width: width, height: bounds.height).integral
            planned.append(PlannedFrame(window: window, frame: frame))
        }

        Logger.info("Auto arrange using \(columnCount)-column layout: count=\(count), columnWidth=\(columnWidth)")
        return applyWithVerify(planned, inside: bounds, gap: gap)
    }

    private func arrangePrimaryPlusN(_ windows: [ArrangeableWindow], inside bounds: CGRect, secondaryCount: Int) -> ArrangeOutcome {
        let gap: CGFloat = Constants.windowGap
        guard let primary = windows.max(by: { lhs, rhs in
            let lhsScore = primaryWindowScore(lhs)
            let rhsScore = primaryWindowScore(rhs)
            if abs(lhsScore - rhsScore) > 1 {
                return lhsScore < rhsScore
            }
            return lhs.candidate.orderIndex > rhs.candidate.orderIndex
        }) else {
            return ArrangeOutcome()
        }

        let primaryWasOnRight = primary.originalFrame.midX >= bounds.midX
        let primaryWidth = floor((bounds.width - gap) * 0.50)
        let secondaryWidth = floor(bounds.width - gap - primaryWidth)

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
            .prefix(secondaryCount)

        let secondaryRowHeight = floor((bounds.height - CGFloat(secondaryCount - 1) * gap) / CGFloat(secondaryCount))
        var planned: [PlannedFrame] = [PlannedFrame(window: primary, frame: primaryFrame)]
        for (rowIndex, window) in secondaryWindows.enumerated() {
            let y = bounds.minY + CGFloat(rowIndex) * (secondaryRowHeight + gap)
            let height = rowIndex == secondaryCount - 1 ? bounds.maxY - y : secondaryRowHeight
            let frame = CGRect(x: secondaryX, y: y, width: secondaryWidth, height: height).integral
            planned.append(PlannedFrame(window: window, frame: frame))
        }

        Logger.info("Auto arrange using 1+\(secondaryCount) layout: primaryOwner=\(primary.candidate.ownerName), primarySide=\(primaryWasOnRight ? "right" : "left")")
        return applyWithVerify(planned, inside: bounds, gap: gap)
    }

    private func arrangeFiveAsLeftTwoBigRightThreeSmall(_ windows: [ArrangeableWindow], inside bounds: CGRect) -> ArrangeOutcome {
        let gap: CGFloat = Constants.windowGap
        // Two biggest windows go to the left column (stacked at half-height each);
        // the remaining three smaller windows fill the right column.
        let sortedByArea = windows.sorted {
            ($0.originalFrame.width * $0.originalFrame.height) >
            ($1.originalFrame.width * $1.originalFrame.height)
        }
        let leftWindows = Array(sortedByArea.prefix(2))
        let rightWindows = Array(sortedByArea.suffix(from: 2).prefix(3))

        let leftWidth = floor((bounds.width - gap) * 0.50)
        let rightWidth = floor(bounds.width - gap - leftWidth)
        let rightX = bounds.minX + leftWidth + gap

        let leftCellHeight = floor((bounds.height - gap) / 2)
        let rightCellHeight = floor((bounds.height - 2 * gap) / 3)

        var planned: [PlannedFrame] = []
        for (index, window) in leftWindows.enumerated() {
            let y = bounds.minY + CGFloat(index) * (leftCellHeight + gap)
            let height = index == leftWindows.count - 1 ? bounds.maxY - y : leftCellHeight
            let frame = CGRect(x: bounds.minX, y: y, width: leftWidth, height: height).integral
            planned.append(PlannedFrame(window: window, frame: frame))
        }
        for (index, window) in rightWindows.enumerated() {
            let y = bounds.minY + CGFloat(index) * (rightCellHeight + gap)
            let height = index == rightWindows.count - 1 ? bounds.maxY - y : rightCellHeight
            let frame = CGRect(x: rightX, y: y, width: rightWidth, height: height).integral
            planned.append(PlannedFrame(window: window, frame: frame))
        }

        Logger.info("Auto arrange using 5-window left-2-big-right-3-small layout")
        return applyWithVerify(planned, inside: bounds, gap: gap)
    }

    private func arrangeFiveAsBottomTwoBigTopThreeSmall(_ windows: [ArrangeableWindow], inside bounds: CGRect) -> ArrangeOutcome {
        let gap: CGFloat = Constants.windowGap
        // Two biggest windows go to the bottom row (each 50% width, 60% height);
        // the other three fill the top row (each 33% width, 40% height).
        let sortedByArea = windows.sorted {
            ($0.originalFrame.width * $0.originalFrame.height) >
            ($1.originalFrame.width * $1.originalFrame.height)
        }
        let bottomWindows = Array(sortedByArea.prefix(2))
        let topWindows = Array(sortedByArea.suffix(from: 2).prefix(3))

        let topHeight = floor((bounds.height - gap) * 0.40)
        let bottomHeight = floor(bounds.height - gap - topHeight)
        let bottomY = bounds.minY + topHeight + gap

        let topCellWidth = floor((bounds.width - 2 * gap) / 3)
        let bottomCellWidth = floor((bounds.width - gap) / 2)

        var planned: [PlannedFrame] = []
        for (index, window) in topWindows.enumerated() {
            let x = bounds.minX + CGFloat(index) * (topCellWidth + gap)
            let width = index == topWindows.count - 1 ? bounds.maxX - x : topCellWidth
            let frame = CGRect(x: x, y: bounds.minY, width: width, height: topHeight).integral
            planned.append(PlannedFrame(window: window, frame: frame))
        }
        for (index, window) in bottomWindows.enumerated() {
            let x = bounds.minX + CGFloat(index) * (bottomCellWidth + gap)
            let width = index == bottomWindows.count - 1 ? bounds.maxX - x : bottomCellWidth
            let frame = CGRect(x: x, y: bottomY, width: width, height: bottomHeight).integral
            planned.append(PlannedFrame(window: window, frame: frame))
        }

        Logger.info("Auto arrange using 5-window bottom-2-big-top-3-small layout")
        return applyWithVerify(planned, inside: bounds, gap: gap)
    }

    private func arrangeBalancedRows(_ windows: [ArrangeableWindow], inside bounds: CGRect) -> ArrangeOutcome {
        let gap: CGFloat = Constants.windowGap
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

        return applyWithVerify(plannedFrames, inside: bounds, gap: gap)
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

    private func arrangeThreeWindows(_ windows: [ArrangeableWindow], inside bounds: CGRect) -> ArrangeOutcome {
        switch threeWindowLayout {
        case .primaryPlusTwo:
            return arrangeThreeWindowsPrimaryPlusTwo(windows, inside: bounds)
        case .threeColumns:
            return arrangeColumnsLayout(windows, inside: bounds, columnCount: 3)
        }
    }

    private func arrangeThreeWindowsPrimaryPlusTwo(_ windows: [ArrangeableWindow], inside bounds: CGRect) -> ArrangeOutcome {
        let gap: CGFloat = Constants.windowGap
        guard let primary = windows.max(by: { lhs, rhs in
            let lhsScore = primaryWindowScore(lhs)
            let rhsScore = primaryWindowScore(rhs)
            if abs(lhsScore - rhsScore) > 1 {
                return lhsScore < rhsScore
            }
            return lhs.candidate.orderIndex > rhs.candidate.orderIndex
        }) else {
            return ArrangeOutcome()
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

        return applyWithVerify(
            targetFrames.map { PlannedFrame(window: $0.0, frame: $0.1) },
            inside: bounds,
            gap: gap
        )
    }

    private func applyAndMeasure(_ plannedFrames: [PlannedFrame]) -> [AppliedFrame] {
        plannedFrames.map { plannedFrame in
            let window = plannedFrame.window
            Logger.info("Auto arrange target: owner=\(window.candidate.ownerName), title=\"\(window.axWindow.title)\", frame=\(plannedFrame.frame)")
            let didMove = setFrame(plannedFrame.frame, for: window.axWindow.element)
            let actual = currentFrame(for: window.axWindow.element)?.integral
            return AppliedFrame(window: window, target: plannedFrame.frame, actual: actual, didMove: didMove)
        }
    }

    private func applyWithVerify(_ plannedFrames: [PlannedFrame], inside bounds: CGRect, gap: CGFloat, allowMinimization: Bool = true) -> ArrangeOutcome {
        let applied = applyAndMeasure(plannedFrames)

        guard isSmartFitEnabled else {
            return ArrangeOutcome(arrangedCount: applied.filter(\.didMove).count, minimizedCount: 0, stubbornCount: 0, adapted: false)
        }

        let stubbornFrames = applied.filter { isStubborn($0) }
        let actualFrames = applied.compactMap(\.actual)
        let hasOverlap = framesHaveMeaningfulOverlap(actualFrames)

        if stubbornFrames.isEmpty, !hasOverlap {
            return ArrangeOutcome(arrangedCount: applied.filter(\.didMove).count, minimizedCount: 0, stubbornCount: 0, adapted: false)
        }

        Logger.info("Smart Fit verify: stubborn=\(stubbornFrames.count), overlap=\(hasOverlap), allowMinimize=\(allowMinimization); running adaptive second pass")
        for stubborn in stubbornFrames {
            let actualText = stubborn.actual.map { "\($0.integral)" } ?? "nil"
            Logger.info("Smart Fit stubborn detail: owner=\(stubborn.window.candidate.ownerName), title=\"\(stubborn.window.axWindow.title)\", target=\(stubborn.target.integral), actual=\(actualText), didMove=\(stubborn.didMove)")
        }

        var effective = applied.map { effectiveWindow(for: $0, inside: bounds) }
        let maxColumns = maximumColumns(in: plannedFrames)

        // Primary-placement path: the user explicitly picked one window as primary and
        // told the algorithm where it goes. Even if the secondaries refuse their cell
        // sizes, we must NOT let adapt rewrite the primary out of position. Keep the
        // first-pass placement, even with overlap.
        if !allowMinimization {
            Logger.info("Smart Fit: primary placement keeps first-pass even if stubborn/overlap detected (adapt skipped entirely)")
            var outcome = ArrangeOutcome()
            outcome.stubbornCount = stubbornFrames.count
            outcome.adapted = false
            outcome.arrangedCount = applied.filter(\.didMove).count
            return outcome
        }

        var latestApplied = applied

        // First, try the adaptive packing without dropping anyone. The result must be
        // verified after AX writes; Chrome can accept a planned non-overlap frame as a
        // different actual frame, so a plan being geometrically valid is not enough.
        if let frames = adaptiveLayout(effective, inside: bounds, gap: gap, maxColumns: maxColumns) {
            let secondPass = applyAndMeasure(frames)
            latestApplied = secondPass
            let secondPassOverlap = framesHaveMeaningfulOverlap(secondPass.compactMap(\.actual))
            if !secondPassOverlap {
                var outcome = ArrangeOutcome()
                outcome.stubbornCount = stubbornFrames.count
                outcome.adapted = true
                outcome.arrangedCount = secondPass.filter(\.didMove).count
                return outcome
            }
            Logger.info("Smart Fit adaptive second pass still overlaps; continuing to overflow strategy")
        }

        switch smartFitOverflowStrategy {
        case .tolerateOverlap:
            Logger.info("Smart Fit: tolerateOverlap strategy keeps latest placement")
            var outcome = ArrangeOutcome()
            outcome.stubbornCount = stubbornFrames.count
            outcome.adapted = false
            outcome.arrangedCount = latestApplied.filter(\.didMove).count
            return outcome

        case .stackWithPeek:
            if !hasOverlap {
                // No real overlap; first-pass is good enough. No need to disturb the tile.
                Logger.info("Smart Fit: stackWithPeek fallback skipped — no meaningful overlap, keeping first-pass tile")
                var outcome = ArrangeOutcome()
                outcome.stubbornCount = stubbornFrames.count
                outcome.adapted = false
                outcome.arrangedCount = applied.filter(\.didMove).count
                return outcome
            }
            Logger.info("Smart Fit: stackWithPeek fallback engaging because tile produced overlap")
            let windows = plannedFrames.map(\.window)
            var stackOutcome = arrangeStackWithPeek(windows, inside: bounds)
            stackOutcome.stubbornCount = stubbornFrames.count
            stackOutcome.adapted = true
            return stackOutcome

        case .minimize:
            break
        }

        // Minimize strategy continues below: only drop when there's real overlap.
        let latestOverlap = framesHaveMeaningfulOverlap(latestApplied.compactMap(\.actual))
        if !latestOverlap {
            Logger.info("Smart Fit: minimize strategy keeps first-pass placement — no overlap above tolerance (\(String(format: "%.0f", smartFitOverlapTolerance * 100))%)")
            var outcome = ArrangeOutcome()
            outcome.stubbornCount = stubbornFrames.count
            outcome.adapted = false
            outcome.arrangedCount = latestApplied.filter(\.didMove).count
            return outcome
        }

        // We have real overlap. Drop the least-recently-used window and retry, up to 3 attempts.
        var droppedToMinimize: [ArrangeableWindow] = []
        var adaptiveFrames: [PlannedFrame]?

        for attempt in 1...3 {
            guard let dropIndex = chooseDropIndex(effective) else {
                break
            }
            let dropped = effective.remove(at: dropIndex)
            droppedToMinimize.append(dropped.window)
            Logger.info("Smart Fit dropping window to retry adaptive layout (attempt \(attempt)): owner=\(dropped.window.candidate.ownerName), title=\"\(dropped.window.axWindow.title)\"")
            if let frames = adaptiveLayout(effective, inside: bounds, gap: gap, maxColumns: maxColumns) {
                adaptiveFrames = frames
                Logger.info("Smart Fit adaptive layout succeeded after dropping \(attempt) window(s)")
                break
            }
        }

        var outcome = ArrangeOutcome()
        outcome.stubbornCount = stubbornFrames.count
        outcome.adapted = true

        if let adaptiveFrames {
            let secondPass = applyAndMeasure(adaptiveFrames)
            outcome.arrangedCount = secondPass.filter(\.didMove).count
        } else {
            outcome.arrangedCount = latestApplied.filter(\.didMove).count
        }

        for window in droppedToMinimize {
            Logger.info("Smart Fit adaptive minimize: owner=\(window.candidate.ownerName), title=\"\(window.axWindow.title)\"")
            if setMinimized(true, for: window.axWindow.element) {
                outcome.minimizedCount += 1
            }
        }

        return outcome
    }

    private func maximumColumns(in plannedFrames: [PlannedFrame]) -> Int? {
        guard plannedFrames.count > 1 else {
            return nil
        }

        var rowYs: [CGFloat] = []
        var rowCounts: [Int] = []
        for plannedFrame in plannedFrames {
            let y = plannedFrame.frame.minY
            if let index = rowYs.firstIndex(where: { abs($0 - y) <= 8 }) {
                rowCounts[index] += 1
            } else {
                rowYs.append(y)
                rowCounts.append(1)
            }
        }

        guard let maxCount = rowCounts.max(), maxCount > 0 else {
            return nil
        }
        return maxCount
    }

    private func effectiveWindow(for frame: AppliedFrame, inside bounds: CGRect) -> EffectiveWindow {
        let stubborn = isStubborn(frame)
        let size: CGSize
        if stubborn {
            size = conservativeStubbornPackSize(for: frame, inside: bounds)
        } else {
            // Flexible windows can be packed smaller than their target size; their
            // final cell width/height will be stretched up to fill the row anyway.
            // Using a small flexible footprint keeps multiple flexible windows in the
            // same row instead of pretending each one needs its original tile size.
            size = CGSize(
                width: min(frame.target.width, Constants.flexibleMinPackWidth),
                height: min(frame.target.height, Constants.flexibleMinPackHeight)
            )
        }
        let clampedSize = CGSize(
            width: min(bounds.width, max(160, size.width)),
            height: min(bounds.height, max(120, size.height))
        )
        return EffectiveWindow(window: frame.window, size: clampedSize, isStubborn: stubborn)
    }

    private func conservativeStubbornPackSize(for frame: AppliedFrame, inside bounds: CGRect) -> CGSize {
        guard let actual = frame.actual else {
            return frame.target.size
        }

        // Treat "refused to shrink" as useful minimum-size evidence, but cap extreme
        // first-pass results. A common failure mode is position-first AX writes moving
        // a tall Chrome window to the bottom before resizing; macOS clamps it back into
        // screen bounds and the snapshot reports a huge height such as 840 pt. That is
        // not a real minimum height, and using it as a hard constraint makes Smart Fit
        // minimize windows that can actually coexist.
        let target = frame.target.size
        let original = frame.window.originalFrame.size
        let isClampArtifact = looksLikeScreenClampArtifact(frame, actual: actual, inside: bounds)

        let width = conservativePackDimension(
            actual: actual.width,
            target: target.width,
            original: original.width,
            flexibleMinimum: Constants.flexibleMinPackWidth,
            maximum: bounds.width,
            isClampArtifact: false
        )
        let height = conservativePackDimension(
            actual: actual.height,
            target: target.height,
            original: original.height,
            flexibleMinimum: Constants.flexibleMinPackHeight,
            maximum: bounds.height,
            isClampArtifact: isClampArtifact
        )

        return CGSize(width: min(bounds.width, width), height: min(bounds.height, height))
    }

    private func conservativePackDimension(
        actual: CGFloat,
        target: CGFloat,
        original: CGFloat,
        flexibleMinimum: CGFloat,
        maximum: CGFloat,
        isClampArtifact: Bool
    ) -> CGFloat {
        let baseline = min(target, max(flexibleMinimum, min(actual, original)))

        if actual > target + Constants.stubbornSizeSlack {
            return min(maximum, isClampArtifact ? baseline : actual)
        }

        if actual < target - Constants.stubbornSizeSlack {
            return min(maximum, max(actual, flexibleMinimum))
        }

        return min(maximum, baseline)
    }

    private func looksLikeScreenClampArtifact(_ frame: AppliedFrame, actual: CGRect, inside bounds: CGRect) -> Bool {
        let target = frame.target
        let actualMuchTaller = actual.height > target.height + Constants.stubbornSizeSlack * 2
        let targetWasLowerHalf = target.midY > bounds.midY
        let actualMovedUp = actual.minY < target.minY - Constants.stubbornSizeSlack
        let actualPinnedToBottom = abs(actual.maxY - bounds.maxY) <= Constants.stubbornSizeSlack

        return actualMuchTaller && targetWasLowerHalf && actualMovedUp && actualPinnedToBottom
    }

    private func isStubborn(_ frame: AppliedFrame) -> Bool {
        guard frame.didMove, let actual = frame.actual else {
            return true
        }
        // A window is "stubborn" whenever its actual size differs significantly from
        // the target — both directions count. Apps that refuse to *shrink* below their
        // minimum are the obvious case, but apps that refuse to *grow* to the target
        // (Chrome often refuses full-height layouts and falls back to a half-height)
        // also need the adaptive pass to react around the real size.
        let widthDiff = abs(actual.width - frame.target.width)
        let heightDiff = abs(actual.height - frame.target.height)
        return widthDiff > Constants.stubbornSizeSlack || heightDiff > Constants.stubbornSizeSlack
    }

    private func framesHaveMeaningfulOverlap(_ frames: [CGRect]) -> Bool {
        guard frames.count > 1 else {
            return false
        }
        let ratioThreshold = CGFloat(smartFitOverlapTolerance)
        for lhsIndex in frames.indices {
            for rhsIndex in frames.indices where rhsIndex > lhsIndex {
                let lhs = frames[lhsIndex]
                let rhs = frames[rhsIndex]
                let overlap = intersectionArea(lhs, rhs)
                let smallerArea = max(1, min(lhs.width * lhs.height, rhs.width * rhs.height))
                if overlap > Constants.overlapMinimumArea, overlap / smallerArea > ratioThreshold {
                    return true
                }
            }
        }
        return false
    }

    private struct EffectiveWindow {
        let window: ArrangeableWindow
        let size: CGSize
        let isStubborn: Bool
    }

    private func adaptiveLayout(_ candidates: [EffectiveWindow], inside bounds: CGRect, gap: CGFloat, maxColumns: Int?) -> [PlannedFrame]? {
        guard !candidates.isEmpty else {
            return []
        }

        if candidates.count == 3, maxColumns.map({ $0 <= 2 }) ?? false {
            return adaptiveThreeAsPrimaryLeftTwoRight(candidates, inside: bounds, gap: gap)
        }

        // Preserve the caller's planned order. Smart Fit may adjust row heights and
        // cell widths, but it should not visually reshuffle the user's chosen layout.
        let orderedCandidates = candidates

        var rows: [[EffectiveWindow]] = [[]]
        var rowWidths: [CGFloat] = [0]
        var rowHeights: [CGFloat] = [0]

        for window in orderedCandidates {
            let lastIndex = rows.count - 1
            let isRowEmpty = rows[lastIndex].isEmpty
            let projectedWidth = rowWidths[lastIndex] + window.size.width + (isRowEmpty ? 0 : gap)
            let projectedColumnCount = rows[lastIndex].count + 1
            let exceedsColumnLimit = maxColumns.map { projectedColumnCount > $0 } ?? false

            if !isRowEmpty && (projectedWidth > bounds.width || exceedsColumnLimit) {
                rows.append([window])
                rowWidths.append(window.size.width)
                rowHeights.append(window.size.height)
            } else {
                rows[lastIndex].append(window)
                rowWidths[lastIndex] = projectedWidth
                rowHeights[lastIndex] = max(rowHeights[lastIndex], window.size.height)
            }
        }

        let totalRowHeight = rowHeights.reduce(0, +) + CGFloat(max(0, rowHeights.count - 1)) * gap
        if totalRowHeight > bounds.height + 1 {
            return nil
        }

        // Sum slack so we can pad row heights (stretch all rows proportionally so they fill the screen vertically).
        let verticalSlack = max(0, bounds.height - totalRowHeight)
        let perRowSlack = rowHeights.isEmpty ? 0 : floor(verticalSlack / CGFloat(rowHeights.count))

        var frames: [PlannedFrame] = []
        var rowY = bounds.minY
        for (rowIndex, row) in rows.enumerated() {
            let baseHeight = rowHeights[rowIndex]
            let rowHeight = rowIndex == rows.count - 1
                ? max(baseHeight, bounds.maxY - rowY)
                : baseHeight + perRowSlack

            let stubbornInRow = row.filter(\.isStubborn)
            let othersInRow = row.filter { !$0.isStubborn }
            let stubbornWidth = stubbornInRow.map(\.size.width).reduce(0, +)
            let totalGaps = CGFloat(max(0, row.count - 1)) * gap
            let availableForOthers = bounds.width - stubbornWidth - totalGaps
            let otherCellWidth = othersInRow.isEmpty
                ? 0
                : floor(availableForOthers / CGFloat(othersInRow.count))

            // If non-stubborn cells would be too small, the layout is unworkable.
            if !othersInRow.isEmpty, otherCellWidth < 200 {
                return nil
            }

            var x = bounds.minX
            for window in row {
                let width: CGFloat
                if window.isStubborn {
                    width = window.size.width
                } else {
                    width = otherCellWidth
                }
                let frame = CGRect(x: x, y: rowY, width: width, height: rowHeight).integral
                frames.append(PlannedFrame(window: window.window, frame: frame))
                x += width + gap
            }

            rowY += rowHeight + gap
        }

        return frames
    }

    private func adaptiveThreeAsPrimaryLeftTwoRight(_ candidates: [EffectiveWindow], inside bounds: CGRect, gap: CGFloat) -> [PlannedFrame]? {
        guard candidates.count == 3,
              let primary = candidates.max(by: { lhs, rhs in
                  let lhsScore = primaryWindowScore(lhs.window)
                  let rhsScore = primaryWindowScore(rhs.window)
                  if abs(lhsScore - rhsScore) > 1 {
                      return lhsScore < rhsScore
                  }
                  return (lhs.size.width * lhs.size.height) < (rhs.size.width * rhs.size.height)
              }) else {
            return nil
        }

        let secondaryWindows = candidates
            .filter { $0.window.candidate.windowID != primary.window.candidate.windowID }
            .sorted {
                if abs($0.window.originalFrame.minY - $1.window.originalFrame.minY) > 8 {
                    return $0.window.originalFrame.minY < $1.window.originalFrame.minY
                }
                return $0.window.originalFrame.minX < $1.window.originalFrame.minX
            }
        guard secondaryWindows.count == 2 else {
            return nil
        }

        let secondaryRequiredWidth = max(
            Constants.flexibleMinPackWidth,
            secondaryWindows.map(\.size.width).max() ?? Constants.flexibleMinPackWidth
        )
        let desiredPrimaryWidth = floor((bounds.width - gap) * 0.50)
        let maxPrimaryWidth = bounds.width - gap - secondaryRequiredWidth
        let primaryWidth = min(max(desiredPrimaryWidth, primary.size.width), maxPrimaryWidth)
        let secondaryWidth = bounds.width - gap - primaryWidth

        guard primaryWidth >= 240, secondaryWidth >= secondaryRequiredWidth else {
            return nil
        }

        let secondaryMinimumHeights = secondaryWindows.map {
            min(bounds.height, max(180, $0.size.height))
        }
        let requiredSecondaryHeight = secondaryMinimumHeights.reduce(0, +) + gap
        guard requiredSecondaryHeight <= bounds.height + 1 else {
            return nil
        }

        let secondarySlack = max(0, bounds.height - gap - secondaryMinimumHeights.reduce(0, +))
        let topHeight = floor(secondaryMinimumHeights[0] + secondarySlack / 2)
        let bottomY = bounds.minY + topHeight + gap
        let bottomHeight = bounds.maxY - bottomY

        Logger.info(
            "Smart Fit adaptive 3-window primary-left layout: primaryOwner=\(primary.window.candidate.ownerName), rightStackCount=2"
        )

        return [
            PlannedFrame(
                window: primary.window,
                frame: CGRect(x: bounds.minX, y: bounds.minY, width: primaryWidth, height: bounds.height).integral
            ),
            PlannedFrame(
                window: secondaryWindows[0].window,
                frame: CGRect(x: bounds.minX + primaryWidth + gap, y: bounds.minY, width: secondaryWidth, height: topHeight).integral
            ),
            PlannedFrame(
                window: secondaryWindows[1].window,
                frame: CGRect(x: bounds.minX + primaryWidth + gap, y: bottomY, width: secondaryWidth, height: bottomHeight).integral
            )
        ]
    }

    private func chooseDropIndex(_ candidates: [EffectiveWindow]) -> Int? {
        guard !candidates.isEmpty else {
            return nil
        }

        // Drop the least-recently-used window first (highest orderIndex = furthest from frontmost).
        var bestIndex: Int?
        var bestOrder: Int = .min
        for (index, candidate) in candidates.enumerated() {
            if candidate.window.candidate.orderIndex > bestOrder {
                bestOrder = candidate.window.candidate.orderIndex
                bestIndex = index
            }
        }
        return bestIndex
    }

    private func setMinimized(_ minimized: Bool, for element: AXUIElement) -> Bool {
        let value: CFTypeRef = (minimized ? kCFBooleanTrue : kCFBooleanFalse)!
        let result = AXUIElementSetAttributeValue(element, kAXMinimizedAttribute as CFString, value)
        if result != .success {
            Logger.warning("Failed to set AXMinimized=\(minimized). error=\(result.rawValue)")
            return false
        }
        return true
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

    private func isSameWindow(_ lhs: AXWindowSnapshot, _ rhs: AXWindowSnapshot) -> Bool {
        if CFEqual(lhs.element, rhs.element) {
            return true
        }

        guard lhs.title == rhs.title,
              let lhsFrame = lhs.frame,
              let rhsFrame = rhs.frame else {
            return false
        }

        return abs(lhsFrame.minX - rhsFrame.minX) <= 24 &&
            abs(lhsFrame.minY - rhsFrame.minY) <= 24 &&
            abs(lhsFrame.width - rhsFrame.width) <= 32 &&
            abs(lhsFrame.height - rhsFrame.height) <= 32
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
            return DisplayLayout(fullBounds: fullBounds.integral, usableBounds: usableBounds.integral, screen: screen)
        }

        if !appKitLayouts.isEmpty {
            return appKitLayouts
        }

        var displayCount: UInt32 = 0
        var displayIDs = [CGDirectDisplayID](repeating: 0, count: 16)

        let result = CGGetActiveDisplayList(UInt32(displayIDs.count), &displayIDs, &displayCount)
        guard result == .success else {
            let bounds = CGDisplayBounds(CGMainDisplayID())
            return [DisplayLayout(fullBounds: bounds, usableBounds: normalizedUsableBounds(bounds, fallback: bounds), screen: nil)]
        }

        return displayIDs.prefix(Int(displayCount)).map { displayID in
            let bounds = CGDisplayBounds(displayID)
            return DisplayLayout(fullBounds: bounds, usableBounds: normalizedUsableBounds(bounds, fallback: bounds), screen: nil)
        }
    }

    func hasLargeScreenAttached() -> Bool {
        for screen in NSScreen.screens {
            if let inches = diagonalInches(for: screen), inches >= 29.5 {
                return true
            }
        }
        return false
    }

    private func diagonalInches(for screen: NSScreen) -> CGFloat? {
        guard let screenNumber = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
            return nil
        }
        let displayID = CGDirectDisplayID(screenNumber.uint32Value)
        let sizeMM = CGDisplayScreenSize(displayID)
        guard sizeMM.width > 0, sizeMM.height > 0 else {
            return nil
        }
        let diagonalMM = sqrt(sizeMM.width * sizeMM.width + sizeMM.height * sizeMM.height)
        return diagonalMM / 25.4
    }

    private func windowCapacity(for screen: NSScreen?) -> Int {
        let profile = smartFitCapacityProfile

        if let screen, let inches = diagonalInches(for: screen) {
            switch inches {
            case ..<15.5:
                return profile.compact
            case 15.5..<20.5:
                return profile.laptop
            case 20.5..<25.5:
                return profile.desktop
            case 25.5..<29.5:
                return profile.large
            default:
                return profile.huge
            }
        }

        // Fallback when physical size is not reported (virtual or unknown display).
        // Estimate from logical point dimensions of the screen.
        guard let screen else {
            return profile.large
        }
        let frame = screen.frame
        let diagonalPts = sqrt(frame.width * frame.width + frame.height * frame.height)
        switch diagonalPts {
        case ..<1800:
            return profile.compact
        case 1800..<2200:
            return profile.laptop
        case 2200..<2900:
            return profile.desktop
        case 2900..<3500:
            return profile.large
        default:
            return profile.huge
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

        let currentBeforeMove = currentFrame(for: element)
        let crossDisplay = isCrossDisplayMove(target: frame, currentFrame: currentBeforeMove)
        if crossDisplay {
            Logger.info("setFrame is moving the window across displays; using settle delays. current=\(currentBeforeMove?.integral.debugDescription ?? "nil"), target=\(frame.integral)")
        }

        // AX writes are dispatched to the target process asynchronously. Without a
        // settle pump between setPosition and setSize, the target sometimes only
        // applies one of them. Cross-display moves need a longer pump because the
        // OS also migrates the window to its new display between writes; same-display
        // moves still need a smaller pump for apps that are slow to process AX writes
        // (Chrome on M4 / macOS 26.3.1 / 16GB needed at least ~20ms to consistently
        // accept the size that follows a position write).
        let positionSettle = crossDisplay ? Constants.crossDisplaySettleDelay : Constants.sameDisplaySettleDelay
        let sizeSettle = crossDisplay ? Constants.crossDisplaySizeSettleDelay : Constants.sameDisplaySettleDelay

        let shouldShrinkBeforeMove: Bool = {
            guard !crossDisplay, let currentBeforeMove else {
                return false
            }
            return frame.width < currentBeforeMove.width - Constants.stubbornSizeSlack ||
                frame.height < currentBeforeMove.height - Constants.stubbornSizeSlack
        }()

        func writePosition(settle: TimeInterval = positionSettle) -> AXError {
            let result = AXUIElementSetAttributeValue(element, kAXPositionAttribute as CFString, positionValue)
            pumpRunLoop(forSeconds: settle)
            return result
        }

        func writeSize(settle: TimeInterval = sizeSettle) -> AXError {
            let result = AXUIElementSetAttributeValue(element, kAXSizeAttribute as CFString, sizeValue)
            pumpRunLoop(forSeconds: settle)
            return result
        }

        var writeResults: [(String, AXError)] = []
        if shouldShrinkBeforeMove {
            Logger.info("setFrame shrink-before-move sequence. current=\(currentBeforeMove?.integral.debugDescription ?? "nil"), target=\(frame.integral)")
            writeResults.append(("initialSize", writeSize()))
            writeResults.append(("position", writePosition()))
            writeResults.append(("confirmSize", writeSize()))
            writeResults.append(("finalPosition", writePosition(settle: Constants.sameDisplayVerifyDelay)))
        } else {
            writeResults.append(("initialPosition", writePosition()))
            writeResults.append(("size", writeSize()))
            writeResults.append(("postSizePosition", writePosition(settle: Constants.sameDisplayVerifyDelay)))
        }

        if writeResults.allSatisfy({ $0.1 == .success }) {
            if frameMatchesTarget(element: element, target: frame) {
                return true
            }

            pumpRunLoop(forSeconds: Constants.sameDisplayVerifyDelay)
            let retryResults: [(String, AXError)]
            if shouldShrinkBeforeMove {
                retryResults = [
                    ("retrySize", writeSize()),
                    ("retryPosition", writePosition(settle: Constants.sameDisplayVerifyDelay))
                ]
            } else {
                retryResults = [
                    ("retrySize", writeSize()),
                    ("finalPosition", writePosition(settle: Constants.sameDisplayVerifyDelay))
                ]
            }

            if retryResults.allSatisfy({ $0.1 == .success }) {
                if let actualFrame = currentFrame(for: element) {
                    Logger.warning("Arranged window settled away from target after retry. target=\(frame), actual=\(actualFrame.integral), crossDisplay=\(crossDisplay)")
                }
                return true
            }

            let retryErrorText = retryResults.map { "\($0.0)=\($0.1.rawValue)" }.joined(separator: ", ")
            Logger.warning(
                "Arranged window did not match target and retry failed. errors=[\(retryErrorText)], crossDisplay=\(crossDisplay)"
            )
            return true
        }

        let errorText = writeResults.map { "\($0.0)=\($0.1.rawValue)" }.joined(separator: ", ")
        Logger.warning(
            "Failed to set arranged window frame. errors=[\(errorText)], crossDisplay=\(crossDisplay)"
        )
        return false
    }

    private func isCrossDisplayMove(target: CGRect, currentFrame: CGRect?) -> Bool {
        guard let currentFrame else {
            return false
        }
        let layouts = activeDisplayLayouts().map(\.fullBounds)
        guard layouts.count > 1 else {
            return false
        }
        let currentDisplay = displayIndex(for: currentFrame, in: layouts)
        let targetDisplay = displayIndex(for: target, in: layouts)
        return currentDisplay != targetDisplay
    }

    private func pumpRunLoop(forSeconds seconds: TimeInterval) {
        let deadline = Date(timeIntervalSinceNow: seconds)
        RunLoop.main.run(until: deadline)
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
        preferCurrentMouseExitPoint: Bool,
        primaryWindow: AXWindowSnapshot?,
        primaryPlacement: PrimaryPlacement?
    ) {
        let detection = currentMissionControlDetection()
        if !detection.isLikelyActive {
            let elapsed = Date().timeIntervalSince(startedAt)
            Logger.info(
                "Mission Control exited before auto arrange: trigger=\(trigger), attempts=\(attempt), elapsed=\(String(format: "%.2f", elapsed))s, detection=\(detection.debugSummary)"
            )
            DispatchQueue.main.asyncAfter(deadline: .now() + Constants.missionControlExitSettleDelay) { [weak self] in
                self?.arrangeVisibleWindowsInternal(
                    trigger: trigger,
                    primaryWindow: primaryWindow,
                    primaryPlacement: primaryPlacement,
                    scopeToPrimaryDisplay: false
                )
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
                preferCurrentMouseExitPoint: preferCurrentMouseExitPoint,
                primaryWindow: primaryWindow,
                primaryPlacement: primaryPlacement
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
