import CoreGraphics
import Foundation

final class MissionControlGestureProbe {
    private enum Constants {
        static let interval: TimeInterval = 0.10
        static let secondGestureWindow: ClosedRange<TimeInterval> = 0.30...2.00
    }

    private struct Snapshot {
        let isActive: Bool
        let score: Int
        let confidence: MatchingConfidence
        let reasons: [String]
        let entryCount: Int
        let dockOverlayCount: Int
        let largeOverlayCount: Int
        let appCandidateCount: Int
        let fingerprint: String

        var compactSummary: String {
            "active=\(isActive), score=\(score), confidence=\(confidence), dockOverlays=\(dockOverlayCount), largeOverlays=\(largeOverlayCount), appCandidates=\(appCandidateCount), entries=\(entryCount), fingerprint=\(fingerprint), reasons=\(reasons.joined(separator: " | "))"
        }
    }

    private let windowEnumerator: WindowEnumerator
    private let detector: MissionControlDetector
    private var timer: Timer?
    private var previousSnapshot: Snapshot?
    private var activeEnteredAt: Date?
    private var loggedSecondGestureCandidate = false

    init(
        windowEnumerator: WindowEnumerator = WindowEnumerator(),
        detector: MissionControlDetector = MissionControlDetector()
    ) {
        self.windowEnumerator = windowEnumerator
        self.detector = detector
    }

    var isRunning: Bool {
        timer != nil
    }

    func start() {
        guard timer == nil else {
            return
        }

        Logger.info("Mission Control gesture probe started")
        let timer = Timer(timeInterval: Constants.interval, repeats: true) { [weak self] _ in
            self?.tick()
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        tick()
    }

    func stop() {
        guard timer != nil else {
            return
        }

        timer?.invalidate()
        timer = nil
        previousSnapshot = nil
        activeEnteredAt = nil
        loggedSecondGestureCandidate = false
        Logger.info("Mission Control gesture probe stopped")
    }

    private func tick() {
        let mousePoint = windowEnumerator.currentMouseLocationInCGWindowCoordinates(logResult: false)
        let entries = windowEnumerator.allWindowEntries(options: [.optionOnScreenOnly])
        let detection = detector.detect(mousePoint: mousePoint, entries: entries)
        let snapshot = makeSnapshot(detection: detection, mousePoint: mousePoint, entries: entries)
        defer {
            previousSnapshot = snapshot
        }

        guard let previousSnapshot else {
            if snapshot.isActive {
                activeEnteredAt = Date()
                loggedSecondGestureCandidate = false
                Logger.info("Mission Control probe transition: \(snapshot.compactSummary), age=0.00")
            }
            return
        }

        if snapshot.isActive != previousSnapshot.isActive {
            if snapshot.isActive {
                activeEnteredAt = Date()
                loggedSecondGestureCandidate = false
            } else {
                activeEnteredAt = nil
                loggedSecondGestureCandidate = false
            }

            Logger.info("Mission Control probe transition: \(snapshot.compactSummary), age=\(activeAgeText())")
            return
        }

        guard snapshot.isActive else {
            return
        }

        let changedFields = changedFields(from: previousSnapshot, to: snapshot)
        guard !changedFields.isEmpty else {
            return
        }

        let age = activeAge()
        Logger.info("Mission Control probe active fingerprint changed: age=\(String(format: "%.2f", age)), changed=\(changedFields.joined(separator: ",")), \(snapshot.compactSummary)")

        if Constants.secondGestureWindow.contains(age), !loggedSecondGestureCandidate {
            loggedSecondGestureCandidate = true
            Logger.info("Mission Control probe possible second Mission Control gesture: age=\(String(format: "%.2f", age)), reason=active window-system fingerprint changed while Mission Control stayed active")
        }
    }

    private func makeSnapshot(
        detection: MissionControlDetection,
        mousePoint: CGPoint,
        entries: [CGWindowListEntry]
    ) -> Snapshot {
        let displayBounds = DisplayBoundsHelper.displayBounds(containing: mousePoint)
        let displayArea = max(displayBounds.width * displayBounds.height, 1)
        let systemOverlays = entries.filter { entry in
            guard let layer = entry.layer, layer > 0 else {
                return false
            }
            return isSystemOverlayOwner(entry.ownerName)
        }
        let dockOverlays = systemOverlays.filter { isDockOwner($0.ownerName) }
        let largeOverlays = systemOverlays.filter { entry in
            guard let bounds = entry.bounds else {
                return false
            }
            let intersection = bounds.intersection(displayBounds)
            guard !intersection.isNull, !intersection.isEmpty else {
                return false
            }
            return (intersection.width * intersection.height) >= displayArea * 0.20
        }
        let appCandidateCount = windowEnumerator.visibleWindowCandidates(from: entries).count

        return Snapshot(
            isActive: detection.isLikelyActive,
            score: detection.score,
            confidence: detection.confidence,
            reasons: detection.reasons,
            entryCount: entries.count,
            dockOverlayCount: dockOverlays.count,
            largeOverlayCount: largeOverlays.count,
            appCandidateCount: appCandidateCount,
            fingerprint: fingerprint(for: entries)
        )
    }

    private func changedFields(from old: Snapshot, to new: Snapshot) -> [String] {
        var fields: [String] = []

        if old.score != new.score {
            fields.append("score")
        }
        if old.confidence != new.confidence {
            fields.append("confidence")
        }
        if old.entryCount != new.entryCount {
            fields.append("entries")
        }
        if old.dockOverlayCount != new.dockOverlayCount {
            fields.append("dockOverlays")
        }
        if old.largeOverlayCount != new.largeOverlayCount {
            fields.append("largeOverlays")
        }
        if old.appCandidateCount != new.appCandidateCount {
            fields.append("appCandidates")
        }
        if old.fingerprint != new.fingerprint {
            fields.append("fingerprint")
        }

        return fields
    }

    private func fingerprint(for entries: [CGWindowListEntry]) -> String {
        let rawParts = entries.prefix(80).compactMap { entry -> String? in
            guard let layer = entry.layer, let bounds = entry.bounds else {
                return nil
            }

            let owner = entry.ownerName
            let includeSystemOverlay = layer > 0 && isSystemOverlayOwner(owner)
            let includeAppWindow = layer == 0 &&
                !WindowEnumerator.ignoredSystemOwnerNames.contains(owner) &&
                bounds.width >= 40 &&
                bounds.height >= 40 &&
                entry.isOnscreen != false

            guard includeSystemOverlay || includeAppWindow else {
                return nil
            }

            let rect = bounds.integral
            let windowID = entry.windowID.map(String.init) ?? "nil"
            return "\(entry.orderIndex):\(windowID):\(owner):\(layer):\(Int(rect.minX)),\(Int(rect.minY)),\(Int(rect.width)),\(Int(rect.height))"
        }

        return fnv1a64(rawParts.joined(separator: "|"))
    }

    private func fnv1a64(_ string: String) -> String {
        var hash: UInt64 = 14_695_981_039_346_656_037
        let prime: UInt64 = 1_099_511_628_211

        for byte in string.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* prime
        }

        return String(format: "%016llx", hash)
    }

    private func activeAge() -> TimeInterval {
        guard let activeEnteredAt else {
            return 0
        }

        return Date().timeIntervalSince(activeEnteredAt)
    }

    private func activeAgeText() -> String {
        String(format: "%.2f", activeAge())
    }

    private func isDockOwner(_ ownerName: String) -> Bool {
        ownerName == "Dock" || ownerName == "程序坞"
    }

    private func isSystemOverlayOwner(_ ownerName: String) -> Bool {
        isDockOwner(ownerName) ||
            ownerName == "SystemUIServer" ||
            ownerName == "Control Center" ||
            ownerName == "控制中心" ||
            ownerName == "WindowServer" ||
            ownerName == "Window Server"
    }
}
