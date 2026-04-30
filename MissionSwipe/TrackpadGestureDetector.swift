import AppKit
import CoreGraphics
import Foundation

final class TrackpadGestureDetector {
    enum State: String {
        case idle
        case tracking
        case triggered
        case coolingDown
    }

    var onSwipeUpDetected: (() -> Void)?
    var shouldBeginTracking: (() -> Bool)?

    var isEnabled: Bool = true {
        didSet {
            Logger.info("Trackpad swipe-up detector enabled=\(isEnabled)")
            if !isEnabled {
                reset(reason: "detector disabled")
            }
        }
    }

    private enum Constants {
        static let invertSwipeDirection = true
        static let triggerThresholdY: CGFloat = 70
        static let maxHorizontalRatio: CGFloat = 0.55
        static let maxHorizontalAbsolute: CGFloat = 90
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
        Logger.info("Installed CGEventTap listen-only scrollWheel monitor for trackpad swipe-up prototype")
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

        accumulatedX += rawDeltaX
        accumulatedY += interpretedDeltaY

        let interpretedDirection: String
        if accumulatedY > 0 {
            interpretedDirection = "swipe up"
        } else if accumulatedY < 0 {
            interpretedDirection = "swipe down"
        } else {
            interpretedDirection = "neutral"
        }

        let horizontalLimit = min(Constants.maxHorizontalAbsolute, abs(accumulatedY) * Constants.maxHorizontalRatio)
        let horizontalIsSmall = abs(accumulatedX) <= max(20, horizontalLimit)
        let didReachVerticalThreshold = accumulatedY >= Constants.triggerThresholdY
        let looksLikeSwipeUp = didReachVerticalThreshold && horizontalIsSmall

        let accumulationMessage = "Trackpad swipe accumulation: accumulatedY=\(format(accumulatedY)), accumulatedX=\(format(accumulatedX)), interpreted=\(interpretedDirection), verticalThreshold=\(didReachVerticalThreshold), horizontalSmall=\(horizontalIsSmall), source=\(source), momentum=\(hasMomentum), trigger=\(looksLikeSwipeUp)"
        if looksLikeSwipeUp {
            Logger.info(accumulationMessage)
        } else {
            Logger.debug(accumulationMessage)
        }

        if looksLikeSwipeUp {
            state = .triggered
            cancelScheduledReset()
            Logger.info("Trackpad swipe-up detected; firing callback once for this gesture")
            onSwipeUpDetected?()
            beginCooldown(reason: "swipe-up triggered", duration: Constants.cooldown)
            return
        }

        if accumulatedY <= -Constants.triggerThresholdY {
            Logger.info("Trackpad gesture interpreted as swipe down; not closing")
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
