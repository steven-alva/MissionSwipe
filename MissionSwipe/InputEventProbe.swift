import AppKit
import CoreGraphics
import Foundation

final class InputEventProbe {
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var globalMonitor: Any?
    private var sequenceID = 0
    private var lastEventAt: Date?

    private enum Constants {
        static let sequenceGap: TimeInterval = 0.22
    }

    var isRunning: Bool {
        eventTap != nil || globalMonitor != nil
    }

    func start() {
        guard !isRunning else {
            return
        }

        sequenceID = 0
        lastEventAt = nil
        installCGEventTap()
        installNSEventMonitor()
        Logger.info("Input event probe started")
    }

    func stop() {
        if let globalMonitor {
            NSEvent.removeMonitor(globalMonitor)
        }
        globalMonitor = nil

        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        }
        runLoopSource = nil

        if let eventTap {
            CGEvent.tapEnable(tap: eventTap, enable: false)
        }
        eventTap = nil

        Logger.info("Input event probe stopped")
    }

    fileprivate func handleEventTap(type: CGEventType, event: CGEvent) {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            Logger.warning("Input event probe CGEventTap disabled by \(type); attempting to re-enable")
            if let eventTap {
                CGEvent.tapEnable(tap: eventTap, enable: true)
            }
            return
        }

        guard type == .scrollWheel else {
            logCGEvent(type: type, event: event)
            return
        }

        logCGEvent(type: type, event: event)
    }

    private func installCGEventTap() {
        let scrollMask = CGEventMask(1 << CGEventType.scrollWheel.rawValue)
        let flagsMask = CGEventMask(1 << CGEventType.flagsChanged.rawValue)
        let eventMask = scrollMask | flagsMask
        let userInfo = UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .tailAppendEventTap,
            options: .listenOnly,
            eventsOfInterest: eventMask,
            callback: missionSwipeInputProbeEventTapCallback,
            userInfo: userInfo
        ) else {
            Logger.error("Input event probe failed to install CGEventTap")
            return
        }

        eventTap = tap
        guard let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0) else {
            Logger.error("Input event probe failed to create CGEventTap run loop source")
            eventTap = nil
            return
        }

        runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        Logger.info("Input event probe installed CGEventTap for scrollWheel and flagsChanged")
    }

    private func installNSEventMonitor() {
        let mask: NSEvent.EventTypeMask = [
            .scrollWheel,
            .gesture,
            .magnify,
            .swipe,
            .rotate,
            .beginGesture,
            .endGesture,
            .smartMagnify
        ]

        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: mask) { [weak self] event in
            self?.logNSEvent(event)
        }

        if globalMonitor == nil {
            Logger.error("Input event probe failed to install NSEvent global monitor")
        } else {
            Logger.info("Input event probe installed NSEvent global monitor for gesture event masks")
        }
    }

    private func logCGEvent(type: CGEventType, event: CGEvent) {
        let sequence = nextSequenceID()
        let pointDeltaY = event.getIntegerValueField(.scrollWheelEventPointDeltaAxis1)
        let pointDeltaX = event.getIntegerValueField(.scrollWheelEventPointDeltaAxis2)
        let fixedDeltaY = event.getIntegerValueField(.scrollWheelEventFixedPtDeltaAxis1)
        let fixedDeltaX = event.getIntegerValueField(.scrollWheelEventFixedPtDeltaAxis2)
        let lineDeltaY = event.getIntegerValueField(.scrollWheelEventDeltaAxis1)
        let lineDeltaX = event.getIntegerValueField(.scrollWheelEventDeltaAxis2)
        let phaseRaw = event.getIntegerValueField(.scrollWheelEventScrollPhase)
        let momentumPhaseRaw = event.getIntegerValueField(.scrollWheelEventMomentumPhase)
        let continuous = event.getIntegerValueField(.scrollWheelEventIsContinuous)
        let location = event.location

        Logger.info(
            "InputProbe CGEvent seq=\(sequence), type=\(cgEventTypeDescription(type)), loc=(\(format(location.x)),\(format(location.y))), pointDelta=(x:\(pointDeltaX),y:\(pointDeltaY)), fixedDelta=(x:\(fixedDeltaX),y:\(fixedDeltaY)), lineDelta=(x:\(lineDeltaX),y:\(lineDeltaY)), phase=\(phaseDescription(rawValue: phaseRaw)), momentum=\(phaseDescription(rawValue: momentumPhaseRaw)), continuous=\(continuous), flags=\(event.flags.rawValue)"
        )
    }

    private func logNSEvent(_ event: NSEvent) {
        let sequence = nextSequenceID()
        let location = event.locationInWindow
        let touches = touchCount(for: event)

        Logger.info(
            "InputProbe NSEvent seq=\(sequence), type=\(nsEventTypeDescription(event.type)), subtype=\(event.subtype.rawValue), timestamp=\(String(format: "%.5f", event.timestamp)), loc=(\(format(location.x)),\(format(location.y))), scrollDelta=(x:\(format(event.scrollingDeltaX)),y:\(format(event.scrollingDeltaY))), delta=(x:\(format(event.deltaX)),y:\(format(event.deltaY)),z:\(format(event.deltaZ))), magnification=\(format(event.magnification)), rotation=\(format(event.rotation)), phase=\(phaseDescription(rawValue: Int64(event.phase.rawValue))), momentum=\(phaseDescription(rawValue: Int64(event.momentumPhase.rawValue))), precise=\(event.hasPreciseScrollingDeltas), touches=\(touches), flags=\(event.modifierFlags.rawValue)"
        )
    }

    private func touchCount(for event: NSEvent) -> Int {
        event.touches(matching: .any, in: nil).count
    }

    private func nextSequenceID() -> Int {
        let now = Date()
        if let lastEventAt, now.timeIntervalSince(lastEventAt) > Constants.sequenceGap {
            sequenceID += 1
        } else if lastEventAt == nil {
            sequenceID += 1
        }
        lastEventAt = now
        return sequenceID
    }

    private func cgEventTypeDescription(_ type: CGEventType) -> String {
        switch type {
        case .scrollWheel:
            return "scrollWheel"
        case .flagsChanged:
            return "flagsChanged"
        case .tapDisabledByTimeout:
            return "tapDisabledByTimeout"
        case .tapDisabledByUserInput:
            return "tapDisabledByUserInput"
        default:
            return "raw=\(type.rawValue)"
        }
    }

    private func nsEventTypeDescription(_ type: NSEvent.EventType) -> String {
        switch type {
        case .scrollWheel:
            return "scrollWheel"
        case .gesture:
            return "gesture"
        case .magnify:
            return "magnify"
        case .swipe:
            return "swipe"
        case .rotate:
            return "rotate"
        case .beginGesture:
            return "beginGesture"
        case .endGesture:
            return "endGesture"
        case .smartMagnify:
            return "smartMagnify"
        default:
            return "raw=\(type.rawValue)"
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

    private func phaseContains(_ rawValue: Int64, _ phase: NSEvent.Phase) -> Bool {
        (UInt(rawValue) & phase.rawValue) != 0
    }

    private func format(_ value: CGFloat) -> String {
        String(format: "%.2f", value)
    }

    private func format(_ value: Float) -> String {
        String(format: "%.2f", value)
    }

    private func format(_ value: Double) -> String {
        String(format: "%.2f", value)
    }
}

private func missionSwipeInputProbeEventTapCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    userInfo: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard let userInfo else {
        return Unmanaged.passUnretained(event)
    }

    let probe = Unmanaged<InputEventProbe>.fromOpaque(userInfo).takeUnretainedValue()
    probe.handleEventTap(type: type, event: event)
    return Unmanaged.passUnretained(event)
}
