import Carbon.HIToolbox
import Foundation

final class GlobalHotkeyManager {
    private let hotKeySignature: OSType = 0x4D535750
    private let hotKeyIdentifier: UInt32 = 1
    private var hotKeyRef: EventHotKeyRef?
    private var eventHandlerRef: EventHandlerRef?
    private var handler: (() -> Void)?

    func register(controlOptionWHandler handler: @escaping () -> Void) {
        unregister()
        self.handler = handler

        var eventSpec = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )

        var installedHandler: EventHandlerRef?
        let userData = UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())
        let handlerStatus = InstallEventHandler(
            GetApplicationEventTarget(),
            missionSwipeHotKeyCallback,
            1,
            &eventSpec,
            userData,
            &installedHandler
        )

        guard handlerStatus == noErr else {
            Logger.error("Failed to install Carbon hotkey event handler. OSStatus=\(handlerStatus)")
            return
        }

        eventHandlerRef = installedHandler

        let hotKeyID = EventHotKeyID(signature: hotKeySignature, id: hotKeyIdentifier)
        var registeredHotKey: EventHotKeyRef?
        let registerStatus = RegisterEventHotKey(
            UInt32(kVK_ANSI_W),
            UInt32(controlKey | optionKey),
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &registeredHotKey
        )

        guard registerStatus == noErr else {
            Logger.error("Failed to register Control+Option+W global hotkey. OSStatus=\(registerStatus)")
            if let eventHandlerRef {
                RemoveEventHandler(eventHandlerRef)
                self.eventHandlerRef = nil
            }
            return
        }

        hotKeyRef = registeredHotKey
        Logger.info("Registered global hotkey: Control+Option+W")
    }

    func unregister() {
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
            Logger.info("Unregistered global hotkey")
        }
        hotKeyRef = nil

        if let eventHandlerRef {
            RemoveEventHandler(eventHandlerRef)
        }
        eventHandlerRef = nil
    }

    fileprivate func handleHotKeyEvent(_ event: EventRef?) {
        guard let event else {
            Logger.warning("Hotkey callback received a nil event")
            return
        }

        var receivedHotKeyID = EventHotKeyID()
        var actualSize = 0
        let parameterStatus = GetEventParameter(
            event,
            EventParamName(kEventParamDirectObject),
            EventParamType(typeEventHotKeyID),
            nil,
            MemoryLayout<EventHotKeyID>.size,
            &actualSize,
            &receivedHotKeyID
        )

        guard parameterStatus == noErr else {
            Logger.error("Unable to read hotkey event parameter. OSStatus=\(parameterStatus)")
            return
        }

        guard receivedHotKeyID.signature == hotKeySignature, receivedHotKeyID.id == hotKeyIdentifier else {
            Logger.debug("Ignoring unrelated hotkey event: signature=\(receivedHotKeyID.signature), id=\(receivedHotKeyID.id)")
            return
        }

        Logger.info("Control+Option+W hotkey pressed")
        handler?()
    }
}

private func missionSwipeHotKeyCallback(
    nextHandler: EventHandlerCallRef?,
    event: EventRef?,
    userData: UnsafeMutableRawPointer?
) -> OSStatus {
    guard let userData else {
        Logger.warning("Hotkey callback missing userData")
        return noErr
    }

    let manager = Unmanaged<GlobalHotkeyManager>.fromOpaque(userData).takeUnretainedValue()
    manager.handleHotKeyEvent(event)
    return noErr
}
