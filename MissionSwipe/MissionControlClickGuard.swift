import CoreGraphics
import Foundation

final class MissionControlClickGuard {
    private enum Constants {
        static let protectionDuration: TimeInterval = 6.0
        static let protectedBoundsPadding: CGFloat = 24
    }

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var protectedBounds: CGRect?
    private var expiresAt: Date?
    private var isSuppressingClickSequence = false
    private var expirationWorkItem: DispatchWorkItem?

    func protectAgainstStaleThumbnailClick(in bounds: CGRect) {
        let paddedBounds = bounds.insetBy(
            dx: -Constants.protectedBoundsPadding,
            dy: -Constants.protectedBoundsPadding
        )

        protectedBounds = paddedBounds
        expiresAt = Date().addingTimeInterval(Constants.protectionDuration)
        isSuppressingClickSequence = false

        guard installEventTapIfNeeded() else {
            Logger.warning("Unable to arm Mission Control stale-click guard; stale thumbnail clicks may still restore minimized windows")
            return
        }

        scheduleExpiration()
        Logger.info("Armed Mission Control stale-click guard for bounds=\(paddedBounds.integral), duration=\(String(format: "%.1f", Constants.protectionDuration))s")
    }

    fileprivate func handleEventTap(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            handleTapDisabled(type)
            return Unmanaged.passUnretained(event)
        }

        guard let protectedBounds, let expiresAt else {
            return Unmanaged.passUnretained(event)
        }

        guard Date() <= expiresAt else {
            deactivate(reason: "protection expired")
            return Unmanaged.passUnretained(event)
        }

        let eventPoint = event.location

        switch type {
        case .mouseMoved:
            if !protectedBounds.contains(eventPoint) {
                deactivate(reason: "pointer left protected minimized thumbnail bounds")
            }
            return Unmanaged.passUnretained(event)

        case .leftMouseDown:
            if protectedBounds.contains(eventPoint) {
                isSuppressingClickSequence = true
                Logger.info("Suppressed stale Mission Control thumbnail mouse-down after minimize at \(eventPoint)")
                return nil
            }

            deactivate(reason: "click outside protected minimized thumbnail bounds")
            return Unmanaged.passUnretained(event)

        case .leftMouseUp:
            if isSuppressingClickSequence {
                isSuppressingClickSequence = false
                Logger.info("Suppressed stale Mission Control thumbnail mouse-up after minimize at \(eventPoint)")
                deactivate(reason: "suppressed stale click sequence")
                return nil
            }

            return Unmanaged.passUnretained(event)

        default:
            return Unmanaged.passUnretained(event)
        }
    }

    private func installEventTapIfNeeded() -> Bool {
        if let eventTap {
            CGEvent.tapEnable(tap: eventTap, enable: true)
            return true
        }

        let eventMask =
            CGEventMask(1 << CGEventType.leftMouseDown.rawValue) |
            CGEventMask(1 << CGEventType.leftMouseUp.rawValue) |
            CGEventMask(1 << CGEventType.mouseMoved.rawValue)
        let userInfo = UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: eventMask,
            callback: missionSwipeClickGuardEventTapCallback,
            userInfo: userInfo
        ) else {
            return false
        }

        guard let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0) else {
            CGEvent.tapEnable(tap: tap, enable: false)
            return false
        }

        eventTap = tap
        runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        Logger.info("Installed temporary Mission Control stale-click guard event tap")
        return true
    }

    private func handleTapDisabled(_ type: CGEventType) {
        guard protectedBounds != nil else {
            deactivate(reason: "event tap disabled with no active protection")
            return
        }

        Logger.warning("Mission Control stale-click guard event tap was disabled by \(type); attempting to re-enable")
        if let eventTap {
            CGEvent.tapEnable(tap: eventTap, enable: true)
        }
    }

    private func scheduleExpiration() {
        expirationWorkItem?.cancel()

        let workItem = DispatchWorkItem { [weak self] in
            self?.deactivate(reason: "protection expired")
        }
        expirationWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + Constants.protectionDuration, execute: workItem)
    }

    private func deactivate(reason: String) {
        guard protectedBounds != nil || eventTap != nil || runLoopSource != nil else {
            return
        }

        Logger.debug("Deactivating Mission Control stale-click guard: \(reason)")
        protectedBounds = nil
        expiresAt = nil
        isSuppressingClickSequence = false
        expirationWorkItem?.cancel()
        expirationWorkItem = nil

        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        }
        runLoopSource = nil

        if let eventTap {
            CGEvent.tapEnable(tap: eventTap, enable: false)
        }
        eventTap = nil
    }
}

private func missionSwipeClickGuardEventTapCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    userInfo: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard let userInfo else {
        return Unmanaged.passUnretained(event)
    }

    let clickGuard = Unmanaged<MissionControlClickGuard>.fromOpaque(userInfo).takeUnretainedValue()
    return clickGuard.handleEventTap(type: type, event: event)
}
