import CoreGraphics
import Foundation

final class MissionControlJitterProbe {
    private enum Constants {
        static let interval: TimeInterval = 1.0 / 60.0
        static let inactiveInterval: TimeInterval = 0.10
        static let minMovedWindows = 3
        static let minAverageCenterDelta: CGFloat = 0.75
        static let minMaxCenterDelta: CGFloat = 1.50
        static let stableWarmup: TimeInterval = 1.10
        static let burstMergeGap: TimeInterval = 0.16
        static let inferenceCooldown: TimeInterval = 1.00
        static let minBurstSamples = 3
        static let minUniqueMovedWindows = 5
        static let maxBurstAverageDelta: CGFloat = 12.0
        static let maxBurstMaxDelta: CGFloat = 45.0
    }

    private struct WindowSnapshot {
        let id: CGWindowID
        let orderIndex: Int
        let ownerName: String
        let ownerPID: pid_t
        let bounds: CGRect

        var center: CGPoint {
            CGPoint(x: bounds.midX, y: bounds.midY)
        }
    }

    private struct MotionSummary {
        let movedWindows: Int
        let totalWindows: Int
        let averageCenterDelta: CGFloat
        let maxCenterDelta: CGFloat
        let maxWindowID: CGWindowID?
        let movedWindowIDs: Set<CGWindowID>
        let ownerSummary: String
        let boundsSummary: String

        var isJitterLike: Bool {
            movedWindows >= Constants.minMovedWindows &&
                averageCenterDelta >= Constants.minAverageCenterDelta &&
                maxCenterDelta >= Constants.minMaxCenterDelta
        }
    }

    private struct JitterBurst {
        let startedAt: Date
        var lastMotionAt: Date
        var samples: Int
        var peakMovedWindows: Int
        var peakAverageDelta: CGFloat
        var peakMaxDelta: CGFloat
        var movedWindowIDs: Set<CGWindowID>
        var ownerSummary: String
        var boundsSummary: String
        var emittedInference = false
    }

    private let windowEnumerator: WindowEnumerator
    private let detector: MissionControlDetector
    var onSecondMissionControlSwipeInferred: (() -> Void)?
    private var timer: Timer?
    private var lastSnapshots: [CGWindowID: WindowSnapshot] = [:]
    private var wasMissionControlActive = false
    private var activeStartedAt: Date?
    private var currentBurst: JitterBurst?
    private var lastInferenceAt: Date?
    private var inferredThisMissionControlSession = false
    private var loggedWarmupIgnore = false
    private var activeSampleCount = 0

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

        resetTracking()
        Logger.info("Second Mission Control swipe monitor started")
        scheduleTimer(interval: Constants.inactiveInterval)
        tick()
    }

    func stop() {
        guard timer != nil else {
            return
        }

        timer?.invalidate()
        timer = nil
        resetTracking()
        Logger.info("Second Mission Control swipe monitor stopped")
    }

    func suppressCurrentMissionControlSession(reason: String) {
        inferredThisMissionControlSession = true
        currentBurst = nil
        Logger.info("Second Mission Control swipe monitor suppressed for current Mission Control session: \(reason)")
    }

    private func scheduleTimer(interval: TimeInterval) {
        timer?.invalidate()
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            self?.tick()
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func updateTimerForActiveState(_ isActive: Bool) {
        let desiredInterval = isActive ? Constants.interval : Constants.inactiveInterval
        guard let timer, abs(timer.timeInterval - desiredInterval) > 0.001 else {
            return
        }
        scheduleTimer(interval: desiredInterval)
    }

    private func tick() {
        let mousePoint = windowEnumerator.currentMouseLocationInCGWindowCoordinates(logResult: false)
        let entries = windowEnumerator.allWindowEntries(options: [.optionOnScreenOnly])
        let detection = detector.detect(mousePoint: mousePoint, entries: entries)
        let isActive = detection.isLikelyActive
        updateTimerForActiveState(isActive)

        guard isActive else {
            if wasMissionControlActive {
                Logger.info("Second Mission Control swipe monitor inactive; leaving active sampling")
            }
            wasMissionControlActive = false
            resetTracking()
            return
        }

        let snapshots = makeSnapshots(from: entries)
        if !wasMissionControlActive {
            wasMissionControlActive = true
            activeStartedAt = Date()
            activeSampleCount = 0
            lastSnapshots = snapshots
            Logger.info("Second Mission Control swipe monitor active: candidates=\(snapshots.count), detection=\(detection.debugSummary)")
            return
        }

        activeSampleCount += 1
        defer {
            lastSnapshots = snapshots
        }

        guard !lastSnapshots.isEmpty, !snapshots.isEmpty else {
            return
        }

        let motion = summarizeMotion(previous: lastSnapshots, current: snapshots)
        let now = Date()
        if motion.isJitterLike {
            handleJitterLikeMotion(motion: motion, detection: detection, now: now)
        } else if let currentBurst, now.timeIntervalSince(currentBurst.lastMotionAt) > Constants.burstMergeGap {
            finishBurst(currentBurst, reason: "stable gap elapsed")
            self.currentBurst = nil
        }
    }

    private func makeSnapshots(from entries: [CGWindowListEntry]) -> [CGWindowID: WindowSnapshot] {
        let candidates = windowEnumerator.visibleWindowCandidates(from: entries)
        var snapshots: [CGWindowID: WindowSnapshot] = [:]

        for candidate in candidates {
            snapshots[candidate.windowID] = WindowSnapshot(
                id: candidate.windowID,
                orderIndex: candidate.orderIndex,
                ownerName: candidate.ownerName,
                ownerPID: candidate.ownerPID,
                bounds: candidate.bounds.integral
            )
        }

        return snapshots
    }

    private func summarizeMotion(
        previous: [CGWindowID: WindowSnapshot],
            current: [CGWindowID: WindowSnapshot]
    ) -> MotionSummary {
        var movedWindows = 0
        var totalDelta: CGFloat = 0
        var maxDelta: CGFloat = 0
        var maxWindowID: CGWindowID?
        var movedWindowIDs = Set<CGWindowID>()
        var ownerCounts: [String: Int] = [:]
        var movedBounds: [String] = []

        for (id, currentSnapshot) in current {
            guard let previousSnapshot = previous[id] else {
                continue
            }

            let centerDelta = distance(previousSnapshot.center, currentSnapshot.center)
            let sizeDelta = abs(previousSnapshot.bounds.width - currentSnapshot.bounds.width) +
                abs(previousSnapshot.bounds.height - currentSnapshot.bounds.height)
            let effectiveDelta = max(centerDelta, sizeDelta)

            guard effectiveDelta >= Constants.minMaxCenterDelta else {
                continue
            }

            movedWindows += 1
            movedWindowIDs.insert(id)
            totalDelta += effectiveDelta
            ownerCounts[currentSnapshot.ownerName, default: 0] += 1

            if effectiveDelta > maxDelta {
                maxDelta = effectiveDelta
                maxWindowID = id
            }

            if movedBounds.count < 5 {
                movedBounds.append("\(id):\(currentSnapshot.ownerName):\(rectSummary(currentSnapshot.bounds))")
            }
        }

        let averageDelta = movedWindows > 0 ? totalDelta / CGFloat(movedWindows) : 0
        let ownerSummary = ownerCounts
            .sorted { lhs, rhs in
                if lhs.value == rhs.value {
                    return lhs.key < rhs.key
                }
                return lhs.value > rhs.value
            }
            .prefix(5)
            .map { "\($0.key)=\($0.value)" }
            .joined(separator: ",")

        return MotionSummary(
            movedWindows: movedWindows,
            totalWindows: current.count,
            averageCenterDelta: averageDelta,
            maxCenterDelta: maxDelta,
            maxWindowID: maxWindowID,
            movedWindowIDs: movedWindowIDs,
            ownerSummary: ownerSummary.isEmpty ? "none" : ownerSummary,
            boundsSummary: movedBounds.joined(separator: " | ")
        )
    }

    private func handleJitterLikeMotion(
        motion: MotionSummary,
        detection: MissionControlDetection,
        now: Date
    ) {
        let age = activeStartedAt.map { now.timeIntervalSince($0) } ?? 0
        guard age >= Constants.stableWarmup else {
            if !loggedWarmupIgnore {
                loggedWarmupIgnore = true
                Logger.info(
                    "Mission Control jitter ignored during warmup: age=\(String(format: "%.3f", age)), movedWindows=\(motion.movedWindows)/\(motion.totalWindows), avgDelta=\(format(motion.averageCenterDelta)), maxDelta=\(format(motion.maxCenterDelta))"
                )
            }
            return
        }

        if var burst = currentBurst, now.timeIntervalSince(burst.lastMotionAt) <= Constants.burstMergeGap {
            burst.lastMotionAt = now
            burst.samples += 1
            burst.peakMovedWindows = max(burst.peakMovedWindows, motion.movedWindows)
            burst.peakAverageDelta = max(burst.peakAverageDelta, motion.averageCenterDelta)
            burst.peakMaxDelta = max(burst.peakMaxDelta, motion.maxCenterDelta)
            burst.movedWindowIDs.formUnion(motion.movedWindowIDs)
            if motion.movedWindows >= burst.peakMovedWindows {
                burst.ownerSummary = motion.ownerSummary
                burst.boundsSummary = motion.boundsSummary
            }
            currentBurst = burst
        } else {
            currentBurst = JitterBurst(
                startedAt: now,
                lastMotionAt: now,
                samples: 1,
                peakMovedWindows: motion.movedWindows,
                peakAverageDelta: motion.averageCenterDelta,
                peakMaxDelta: motion.maxCenterDelta,
                movedWindowIDs: motion.movedWindowIDs,
                ownerSummary: motion.ownerSummary,
                boundsSummary: motion.boundsSummary
            )
        }

        guard var burst = currentBurst else {
            return
        }

        let enoughSamples = burst.samples >= Constants.minBurstSamples
        let enoughUniqueWindows = burst.movedWindowIDs.count >= Constants.minUniqueMovedWindows
        let movementIsStillJitterSized = burst.peakAverageDelta <= Constants.maxBurstAverageDelta &&
            burst.peakMaxDelta <= Constants.maxBurstMaxDelta
        let cooldownElapsed = lastInferenceAt.map { now.timeIntervalSince($0) >= Constants.inferenceCooldown } ?? true

        if enoughSamples && !movementIsStillJitterSized {
            Logger.info(
                "Second Mission Control swipe candidate rejected: reason=movement too large for in-place jitter, age=\(String(format: "%.3f", age)), samples=\(burst.samples), duration=\(String(format: "%.3f", now.timeIntervalSince(burst.startedAt))), uniqueMovedWindows=\(burst.movedWindowIDs.count), peakAvgDelta=\(format(burst.peakAverageDelta)), peakMaxDelta=\(format(burst.peakMaxDelta)), detectionScore=\(detection.score), confidence=\(detection.confidence)"
            )
            burst.emittedInference = true
            currentBurst = burst
            return
        }

        guard !inferredThisMissionControlSession,
              !burst.emittedInference,
              cooldownElapsed,
              enoughSamples,
              enoughUniqueWindows,
              movementIsStillJitterSized else {
            return
        }

        burst.emittedInference = true
        currentBurst = burst
        lastInferenceAt = now
        inferredThisMissionControlSession = true

        let maxWindowIDText = motion.maxWindowID.map(String.init) ?? "nil"
        Logger.info(
            "Second Mission Control swipe inferred: age=\(String(format: "%.3f", age)), samples=\(burst.samples), duration=\(String(format: "%.3f", now.timeIntervalSince(burst.startedAt))), movedWindows=\(burst.peakMovedWindows)/\(motion.totalWindows), uniqueMovedWindows=\(burst.movedWindowIDs.count), peakAvgDelta=\(format(burst.peakAverageDelta)), peakMaxDelta=\(format(burst.peakMaxDelta)), maxWindowID=\(maxWindowIDText), owners=\(burst.ownerSummary), detectionScore=\(detection.score), confidence=\(detection.confidence), movedBounds=\(burst.boundsSummary)"
        )
        onSecondMissionControlSwipeInferred?()
    }

    private func finishBurst(_ burst: JitterBurst, reason: String) {
        guard burst.emittedInference else {
            return
        }

        Logger.info(
            "Mission Control jitter burst finished: reason=\(reason), samples=\(burst.samples), duration=\(String(format: "%.3f", burst.lastMotionAt.timeIntervalSince(burst.startedAt))), uniqueMovedWindows=\(burst.movedWindowIDs.count), peakMovedWindows=\(burst.peakMovedWindows), peakAvgDelta=\(format(burst.peakAverageDelta)), peakMaxDelta=\(format(burst.peakMaxDelta))"
        )
    }

    private func resetTracking() {
        lastSnapshots = [:]
        wasMissionControlActive = false
        activeStartedAt = nil
        if let currentBurst {
            finishBurst(currentBurst, reason: "tracking reset")
        }
        currentBurst = nil
        lastInferenceAt = nil
        inferredThisMissionControlSession = false
        loggedWarmupIgnore = false
        activeSampleCount = 0
    }

    private func distance(_ lhs: CGPoint, _ rhs: CGPoint) -> CGFloat {
        hypot(lhs.x - rhs.x, lhs.y - rhs.y)
    }

    private func rectSummary(_ rect: CGRect) -> String {
        "\(Int(rect.minX)),\(Int(rect.minY)),\(Int(rect.width)),\(Int(rect.height))"
    }

    private func format(_ value: CGFloat) -> String {
        String(format: "%.2f", value)
    }
}
