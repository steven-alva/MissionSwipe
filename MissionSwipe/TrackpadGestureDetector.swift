import AppKit
import CoreGraphics
import Foundation

enum TrackpadLayoutSwipeDirection {
    case upLeft
    case upRight
    case downLeft
    case downRight
}

final class TrackpadGestureDetector {
    enum State: String {
        case idle
        case tracking
        case triggered
        case coolingDown
    }

    var onSwipeUpDetected: (() -> Void)?
    var onSwipeDownDetected: (() -> Void)?
    var onSwipeLeftDetected: (() -> Void)?
    var onSwipeRightDetected: (() -> Void)?
    var onLayoutSwipeDetected: ((TrackpadLayoutSwipeDirection) -> Void)?
    var shouldBeginTracking: (() -> Bool)?
    var shouldTriggerSwipeUp: ((CGFloat) -> Bool)?
    var shouldTriggerSwipeDown: ((CGFloat) -> Bool)?
    var shouldTriggerSwipeLeft: ((CGFloat) -> Bool)?
    var shouldTriggerSwipeRight: ((CGFloat) -> Bool)?
    var shouldTriggerLayoutSwipe: ((TrackpadLayoutSwipeDirection, CGFloat) -> Bool)?
    var detectsSwipeUp: Bool = true
    var detectsSwipeDown: Bool = false
    var detectsSwipeLeftRight: Bool = false
    var detectsLayoutSwipe: Bool = false

    var isEnabled: Bool = true {
        didSet {
            Logger.info("Trackpad gesture detector enabled=\(isEnabled)")
            if !isEnabled {
                reset(reason: "detector disabled")
            }
        }
    }

    private enum Constants {
        static let invertSwipeDirection = true
        static let triggerThresholdY: CGFloat = 70
        static let triggerThresholdX: CGFloat = 120
        static let diagonalThresholdY: CGFloat = 58
        static let diagonalThresholdX: CGFloat = 58
        static let maxHorizontalRatio: CGFloat = 0.30
        static let maxHorizontalAbsolute: CGFloat = 48
        static let maxVerticalRatioForHorizontal: CGFloat = 0.34
        static let maxVerticalAbsoluteForHorizontal: CGFloat = 58
        static let directionalDominanceRatio: CGFloat = 2.20
        static let ambiguousDiagonalMinimum: CGFloat = 28
        static let trackingTimeout: TimeInterval = 0.28
        static let cooldown: TimeInterval = 0.70
        static let rejectedPreflightCooldown: TimeInterval = 0.50
    }

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var fallbackMonitor: Any?
    private var state: State = .idle
    private var accumulatedX: CGFloat = 0
    private var accumulatedY: CGFloat = 0
    private var resetWorkItem: DispatchWorkItem?

    func start() {
        guard eventTap == nil, fallbackMonitor == nil else {
            Logger.info("Trackpad swipe-up detector already started")
            return
        }

        installCGEventTap()
    }

    func stop() {
        if let fallbackMonitor {
            NSEvent.removeMonitor(fallbackMonitor)
            Logger.info("Removed NSEvent fallback scrollWheel monitor")
        }
        fallbackMonitor = nil

        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        }
        runLoopSource = nil

        if let eventTap {
            CGEvent.tapEnable(tap: eventTap, enable: false)
        }
        eventTap = nil

        reset(reason: "detector stopped")
    }

    fileprivate func handleEventTap(type: CGEventType, event: CGEvent) {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            Logger.warning("Trackpad CGEventTap was disabled by \(type); attempting to re-enable")
            if let eventTap {
                CGEvent.tapEnable(tap: eventTap, enable: true)
            }
            return
        }

        guard type == .scrollWheel else {
            return
        }

        let pointDeltaY = CGFloat(event.getIntegerValueField(.scrollWheelEventPointDeltaAxis1))
        let pointDeltaX = CGFloat(event.getIntegerValueField(.scrollWheelEventPointDeltaAxis2))
        let fallbackDeltaY = CGFloat(event.getIntegerValueField(.scrollWheelEventDeltaAxis1))
        let fallbackDeltaX = CGFloat(event.getIntegerValueField(.scrollWheelEventDeltaAxis2))
        let deltaY = pointDeltaY != 0 ? pointDeltaY : fallbackDeltaY
        let deltaX = pointDeltaX != 0 ? pointDeltaX : fallbackDeltaX
        let phaseRaw = event.getIntegerValueField(.scrollWheelEventScrollPhase)
        let momentumPhaseRaw = event.getIntegerValueField(.scrollWheelEventMomentumPhase)

        handleScrollWheel(
            source: "CGEventTap",
            rawDeltaX: deltaX,
            rawDeltaY: deltaY,
            hasPreciseScrollingDeltas: pointDeltaY != 0 || pointDeltaX != 0,
            phaseRaw: phaseRaw,
            momentumPhaseRaw: momentumPhaseRaw
        )
    }

    private func installCGEventTap() {
        let eventMask = CGEventMask(1 << CGEventType.scrollWheel.rawValue)
        let userInfo = UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: eventMask,
            callback: missionSwipeTrackpadEventTapCallback,
            userInfo: userInfo
        ) else {
            Logger.error("Failed to install CGEventTap scrollWheel monitor; falling back to NSEvent global monitor")
            installNSEventFallback()
            return
        }

        eventTap = tap
        guard let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0) else {
            Logger.error("Failed to create CGEventTap run loop source; falling back to NSEvent global monitor")
            eventTap = nil
            installNSEventFallback()
            return
        }

        runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        Logger.info("Installed CGEventTap listen-only scrollWheel monitor for trackpad gesture prototype")
    }

    private func installNSEventFallback() {
        fallbackMonitor = NSEvent.addGlobalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            self?.handleScrollWheel(
                source: "NSEventFallback",
                rawDeltaX: event.scrollingDeltaX,
                rawDeltaY: event.scrollingDeltaY,
                hasPreciseScrollingDeltas: event.hasPreciseScrollingDeltas,
                phaseRaw: Int64(event.phase.rawValue),
                momentumPhaseRaw: Int64(event.momentumPhase.rawValue)
            )
        }

        if fallbackMonitor == nil {
            Logger.error("Failed to install NSEvent fallback scrollWheel monitor")
        } else {
            Logger.info("Installed NSEvent fallback scrollWheel monitor")
        }
    }

    private func handleScrollWheel(
        source: String,
        rawDeltaX: CGFloat,
        rawDeltaY: CGFloat,
        hasPreciseScrollingDeltas: Bool,
        phaseRaw: Int64,
        momentumPhaseRaw: Int64
    ) {
        guard isEnabled else {
            return
        }

        guard rawDeltaX != 0 || rawDeltaY != 0 else {
            return
        }

        let interpretedDeltaY = Constants.invertSwipeDirection ? -rawDeltaY : rawDeltaY
        let interpretedDeltaX = Constants.invertSwipeDirection ? -rawDeltaX : rawDeltaX
        let phaseText = phaseDescription(rawValue: phaseRaw)
        let momentumPhaseText = phaseDescription(rawValue: momentumPhaseRaw)
        let hasMomentum = momentumPhaseRaw != 0

        if state == .coolingDown {
            return
        }

        Logger.debug(
            "Trackpad scroll event [\(source)]: deltaY=\(format(rawDeltaY)), deltaX=\(format(rawDeltaX)), interpretedY=\(format(interpretedDeltaY)), hasPrecise=\(hasPreciseScrollingDeltas), phase=\(phaseText), momentumPhase=\(momentumPhaseText), state=\(state.rawValue), invertSwipeDirection=\(Constants.invertSwipeDirection)"
        )

        if state == .triggered {
            Logger.debug("Ignoring scroll event because this physical gesture already triggered")
            if phaseEndedOrCancelled(phaseRaw) || phaseEndedOrCancelled(momentumPhaseRaw) {
                beginCooldown(reason: "gesture ended after trigger", duration: Constants.cooldown)
            }
            return
        }

        if state == .idle {
            if let shouldBeginTracking, !shouldBeginTracking() {
                Logger.info("Trackpad swipe preflight rejected; Mission Control is not active enough to arm gesture")
                beginCooldown(reason: "preflight rejected", duration: Constants.rejectedPreflightCooldown)
                return
            }

            state = .tracking
            accumulatedX = 0
            accumulatedY = 0
            Logger.debug("Trackpad swipe state transition: idle -> tracking\(hasMomentum ? " from momentum event" : "")")
        }

        accumulatedX += interpretedDeltaX
        accumulatedY += interpretedDeltaY

        let interpretedDirection: String
        if abs(accumulatedX) > abs(accumulatedY), accumulatedX < 0 {
            interpretedDirection = "swipe left"
        } else if abs(accumulatedX) > abs(accumulatedY), accumulatedX > 0 {
            interpretedDirection = "swipe right"
        } else if accumulatedY > 0 {
            interpretedDirection = "swipe up"
        } else if accumulatedY < 0 {
            interpretedDirection = "swipe down"
        } else {
            interpretedDirection = "neutral"
        }

        let horizontalLimit = min(Constants.maxHorizontalAbsolute, abs(accumulatedY) * Constants.maxHorizontalRatio)
        let horizontalIsSmall = abs(accumulatedX) <= max(20, horizontalLimit)
        let verticalLimit = min(Constants.maxVerticalAbsoluteForHorizontal, abs(accumulatedX) * Constants.maxVerticalRatioForHorizontal)
        let verticalIsSmallForHorizontal = abs(accumulatedY) <= max(20, verticalLimit)
        let didReachUpThreshold = accumulatedY >= Constants.triggerThresholdY
        let didReachDownThreshold = accumulatedY <= -Constants.triggerThresholdY
        let didReachLeftThreshold = accumulatedX <= -Constants.triggerThresholdX
        let didReachRightThreshold = accumulatedX >= Constants.triggerThresholdX
        let layoutDirection = layoutSwipeDirection(accumulatedX: accumulatedX, accumulatedY: accumulatedY)
        let horizontalMagnitude = abs(accumulatedX)
        let verticalMagnitude = abs(accumulatedY)
        let verticalDominates = verticalMagnitude >= horizontalMagnitude * Constants.directionalDominanceRatio
        let horizontalDominates = horizontalMagnitude >= verticalMagnitude * Constants.directionalDominanceRatio
        let hasDiagonalIntent = layoutDirection != nil && !verticalDominates && !horizontalDominates
        let hasAmbiguousDiagonalMotion = detectsLayoutSwipe &&
            horizontalMagnitude >= Constants.ambiguousDiagonalMinimum &&
            verticalMagnitude >= Constants.ambiguousDiagonalMinimum
        let layoutModeBlocksVertical = hasAmbiguousDiagonalMotion && !verticalDominates
        let layoutModeBlocksHorizontal = hasAmbiguousDiagonalMotion && !horizontalDominates
        let canConsiderLayoutSwipe = hasDiagonalIntent && detectsLayoutSwipe
        let canConsiderSwipeUp = didReachUpThreshold && horizontalIsSmall && detectsSwipeUp && !layoutModeBlocksVertical
        let canConsiderSwipeDown = didReachDownThreshold && horizontalIsSmall && detectsSwipeDown && !layoutModeBlocksVertical
        let canConsiderSwipeLeft = didReachLeftThreshold && verticalIsSmallForHorizontal && detectsSwipeLeftRight && !layoutModeBlocksHorizontal
        let canConsiderSwipeRight = didReachRightThreshold && verticalIsSmallForHorizontal && detectsSwipeLeftRight && !layoutModeBlocksHorizontal

        let layoutSwipeTriggerAllowed = canConsiderLayoutSwipe
            ? (layoutDirection.map { direction in shouldTriggerLayoutSwipe?(direction, hypot(accumulatedX, accumulatedY)) ?? true } ?? true)
            : false
        let swipeUpTriggerAllowed = canConsiderSwipeUp ? (shouldTriggerSwipeUp?(accumulatedY) ?? true) : false
        let swipeDownTriggerAllowed = canConsiderSwipeDown ? (shouldTriggerSwipeDown?(accumulatedY) ?? true) : false
        let swipeLeftTriggerAllowed = canConsiderSwipeLeft ? (shouldTriggerSwipeLeft?(abs(accumulatedX)) ?? true) : false
        let swipeRightTriggerAllowed = canConsiderSwipeRight ? (shouldTriggerSwipeRight?(accumulatedX) ?? true) : false
        let looksLikeLayoutSwipe = canConsiderLayoutSwipe && layoutSwipeTriggerAllowed
        let looksLikeSwipeUp = canConsiderSwipeUp && swipeUpTriggerAllowed
        let looksLikeSwipeDown = canConsiderSwipeDown && swipeDownTriggerAllowed
        let looksLikeSwipeLeft = canConsiderSwipeLeft && swipeLeftTriggerAllowed
        let looksLikeSwipeRight = canConsiderSwipeRight && swipeRightTriggerAllowed
        let didTrigger = looksLikeSwipeUp || looksLikeSwipeDown || looksLikeSwipeLeft || looksLikeSwipeRight || looksLikeLayoutSwipe

        let accumulationMessage = "Trackpad swipe accumulation: accumulatedY=\(format(accumulatedY)), accumulatedX=\(format(accumulatedX)), interpreted=\(interpretedDirection), upThreshold=\(didReachUpThreshold), upAllowed=\(swipeUpTriggerAllowed), downThreshold=\(didReachDownThreshold), downAllowed=\(swipeDownTriggerAllowed), leftThreshold=\(didReachLeftThreshold), leftAllowed=\(swipeLeftTriggerAllowed), rightThreshold=\(didReachRightThreshold), rightAllowed=\(swipeRightTriggerAllowed), layoutDirection=\(layoutDirection.map(String.init(describing:)) ?? "none"), layoutAllowed=\(layoutSwipeTriggerAllowed), diagonalIntent=\(hasDiagonalIntent), verticalDominates=\(verticalDominates), horizontalDominates=\(horizontalDominates), horizontalSmall=\(horizontalIsSmall), verticalSmallForHorizontal=\(verticalIsSmallForHorizontal), source=\(source), momentum=\(hasMomentum), trigger=\(didTrigger)"
        if didTrigger {
            Logger.info(accumulationMessage)
        } else {
            Logger.debug(accumulationMessage)
        }

        if looksLikeLayoutSwipe, let layoutDirection {
            state = .triggered
            cancelScheduledReset()
            Logger.info("Trackpad layout swipe detected: \(layoutDirection); firing callback once for this gesture")
            onLayoutSwipeDetected?(layoutDirection)
            beginCooldown(reason: "layout swipe triggered", duration: Constants.cooldown)
            return
        }

        if looksLikeSwipeUp {
            state = .triggered
            cancelScheduledReset()
            Logger.info("Trackpad swipe-up detected; firing callback once for this gesture")
            onSwipeUpDetected?()
            beginCooldown(reason: "swipe-up triggered", duration: Constants.cooldown)
            return
        }

        if looksLikeSwipeDown {
            state = .triggered
            cancelScheduledReset()
            Logger.info("Trackpad swipe-down detected; firing callback once for this gesture")
            onSwipeDownDetected?()
            beginCooldown(reason: "swipe-down triggered", duration: Constants.cooldown)
            return
        }

        if looksLikeSwipeLeft {
            state = .triggered
            cancelScheduledReset()
            Logger.info("Trackpad swipe-left detected; firing callback once for this gesture")
            onSwipeLeftDetected?()
            beginCooldown(reason: "swipe-left triggered", duration: Constants.cooldown)
            return
        }

        if looksLikeSwipeRight {
            state = .triggered
            cancelScheduledReset()
            Logger.info("Trackpad swipe-right detected; firing callback once for this gesture")
            onSwipeRightDetected?()
            beginCooldown(reason: "swipe-right triggered", duration: Constants.cooldown)
            return
        }

        if phaseEndedOrCancelled(phaseRaw) || phaseEndedOrCancelled(momentumPhaseRaw) {
            reset(reason: "scroll phase ended before trigger")
        } else {
            scheduleTrackingTimeout()
        }
    }

    private func beginCooldown(reason: String, duration: TimeInterval) {
        Logger.debug("Trackpad swipe state transition: \(state.rawValue) -> coolingDown (\(reason))")
        state = .coolingDown
        accumulatedX = 0
        accumulatedY = 0
        cancelScheduledReset()

        DispatchQueue.main.asyncAfter(deadline: .now() + duration) { [weak self] in
            self?.reset(reason: "cooldown elapsed")
        }
    }

    private func reset(reason: String) {
        if state != .idle || accumulatedX != 0 || accumulatedY != 0 {
            Logger.debug("Trackpad swipe reset: reason=\(reason), previousState=\(state.rawValue), accumulatedY=\(format(accumulatedY)), accumulatedX=\(format(accumulatedX))")
        }

        state = .idle
        accumulatedX = 0
        accumulatedY = 0
        cancelScheduledReset()
    }

    private func scheduleTrackingTimeout() {
        cancelScheduledReset()

        let workItem = DispatchWorkItem { [weak self] in
            self?.reset(reason: "tracking timeout")
        }
        resetWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + Constants.trackingTimeout, execute: workItem)
    }

    private func cancelScheduledReset() {
        resetWorkItem?.cancel()
        resetWorkItem = nil
    }

    private func layoutSwipeDirection(accumulatedX: CGFloat, accumulatedY: CGFloat) -> TrackpadLayoutSwipeDirection? {
        guard abs(accumulatedX) >= Constants.diagonalThresholdX,
              abs(accumulatedY) >= Constants.diagonalThresholdY else {
            return nil
        }

        let ratio = abs(accumulatedY / accumulatedX)
        guard ratio >= 0.45, ratio <= 1.60 else {
            return nil
        }

        switch (accumulatedX < 0, accumulatedY < 0) {
        case (true, false):
            return .upLeft
        case (false, false):
            return .upRight
        case (true, true):
            return .downLeft
        case (false, true):
            return .downRight
        }
    }

    private func phaseDescription(rawValue: Int64) -> String {
        guard rawValue != 0 else {
            return "none"
        }

        var parts: [String] = []
        if phaseContains(rawValue, .began) { parts.append("began") }
        if phaseContains(rawValue, .stationary) { parts.append("stationary") }
        if phaseContains(rawValue, .changed) { parts.append("changed") }
        if phaseContains(rawValue, .ended) { parts.append("ended") }
        if phaseContains(rawValue, .cancelled) { parts.append("cancelled") }
        if phaseContains(rawValue, .mayBegin) { parts.append("mayBegin") }

        if parts.isEmpty {
            parts.append("raw=\(rawValue)")
        }

        return parts.joined(separator: "|")
    }

    private func phaseEndedOrCancelled(_ rawValue: Int64) -> Bool {
        phaseContains(rawValue, .ended) || phaseContains(rawValue, .cancelled)
    }

    private func phaseContains(_ rawValue: Int64, _ phase: NSEvent.Phase) -> Bool {
        (UInt(rawValue) & phase.rawValue) != 0
    }

    private func format(_ value: CGFloat) -> String {
        String(format: "%.2f", value)
    }
}

private func missionSwipeTrackpadEventTapCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    userInfo: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard let userInfo else {
        return Unmanaged.passUnretained(event)
    }

    let detector = Unmanaged<TrackpadGestureDetector>.fromOpaque(userInfo).takeUnretainedValue()
    detector.handleEventTap(type: type, event: event)
    return Unmanaged.passUnretained(event)
}
