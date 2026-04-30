import AppKit
import CoreGraphics
import Foundation

struct CGWindowListEntry {
    let orderIndex: Int
    let windowID: CGWindowID?
    let ownerPID: pid_t?
    let ownerName: String
    let title: String
    let bounds: CGRect?
    let layer: Int?
    let alpha: CGFloat?
    let sharingState: Int?
    let memoryUsage: Int?
    let isOnscreen: Bool?

    init(orderIndex: Int, dictionary: [String: Any]) {
        self.orderIndex = orderIndex

        if let windowIDNumber = dictionary[kCGWindowNumber as String] as? NSNumber {
            windowID = CGWindowID(windowIDNumber.uint32Value)
        } else {
            windowID = nil
        }

        if let ownerPIDNumber = dictionary[kCGWindowOwnerPID as String] as? NSNumber {
            ownerPID = pid_t(ownerPIDNumber.int32Value)
        } else {
            ownerPID = nil
        }

        ownerName = (dictionary[kCGWindowOwnerName as String] as? String) ?? ""
        title = (dictionary[kCGWindowName as String] as? String) ?? ""

        if let boundsDictionary = dictionary[kCGWindowBounds as String] as? NSDictionary {
            bounds = CGRect(dictionaryRepresentation: boundsDictionary)
        } else {
            bounds = nil
        }

        layer = (dictionary[kCGWindowLayer as String] as? NSNumber)?.intValue
        alpha = CGFloat((dictionary[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1.0)
        sharingState = (dictionary[kCGWindowSharingState as String] as? NSNumber)?.intValue
        memoryUsage = (dictionary[kCGWindowMemoryUsage as String] as? NSNumber)?.intValue
        isOnscreen = (dictionary[kCGWindowIsOnscreen as String] as? NSNumber)?.boolValue
    }

    var fullDebugSummary: String {
        let windowIDText = windowID.map(String.init) ?? "nil"
        let ownerPIDText = ownerPID.map(String.init) ?? "nil"
        let boundsText = bounds.map { "\($0.integral)" } ?? "nil"
        let layerText = layer.map(String.init) ?? "nil"
        let alphaText = alpha.map { String(format: "%.2f", $0) } ?? "nil"
        let sharingText = sharingState.map(String.init) ?? "nil"
        let memoryText = memoryUsage.map(String.init) ?? "nil"
        let onscreenText = isOnscreen.map(String.init) ?? "nil"

        return "order=\(orderIndex), id=\(windowIDText), owner=\"\(ownerName)\", pid=\(ownerPIDText), title=\"\(title)\", bounds=\(boundsText), layer=\(layerText), alpha=\(alphaText), sharing=\(sharingText), memory=\(memoryText), onscreen=\(onscreenText)"
    }
}

struct CGWindowCandidate {
    let orderIndex: Int
    let windowID: CGWindowID
    let ownerPID: pid_t
    let ownerName: String
    let title: String
    let bounds: CGRect
    let layer: Int
    let alpha: CGFloat

    var debugSummary: String {
        "order=\(orderIndex), id=\(windowID), pid=\(ownerPID), owner=\(ownerName), title=\"\(title)\", layer=\(layer), alpha=\(String(format: "%.2f", alpha)), bounds=\(bounds.integral)"
    }
}

final class WindowEnumerator {
    static let ignoredSystemOwnerNames: Set<String> = [
        "Control Center",
        "控制中心",
        "Dock",
        "程序坞",
        "Login Window",
        "Notification Center",
        "Spotlight",
        "SystemUIServer",
        "Window Server",
        "WindowServer"
    ]

    func currentMouseLocationInCGWindowCoordinates() -> CGPoint {
        let appKitPoint = NSEvent.mouseLocation
        let cgPoint = CoordinateConverter.appKitPointToCGWindowPoint(appKitPoint)
        Logger.info("Mouse location AppKit=\(appKitPoint), converted CGWindow=\(cgPoint)")
        return cgPoint
    }

    func topmostWindow(containing mousePoint: CGPoint) -> CGWindowCandidate? {
        let candidates = visibleWindowCandidates()
        Logger.info("Testing \(candidates.count) filtered windows against mouse point \(mousePoint)")

        for candidate in candidates {
            let containsMouse = candidate.bounds.contains(mousePoint)
            Logger.debug("Hit test \(containsMouse ? "MATCH" : "miss"): \(candidate.debugSummary)")
            if containsMouse {
                Logger.info("Topmost window under cursor: \(candidate.debugSummary)")
                return candidate
            }
        }

        Logger.warning("No eligible onscreen window contains the mouse point")
        return nil
    }

    func allWindowEntries(
        options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements],
        logResult: Bool = false
    ) -> [CGWindowListEntry] {
        guard let windowInfoList = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
            Logger.error("CGWindowListCopyWindowInfo returned no window list")
            return []
        }

        if logResult {
            Logger.info("CGWindowList returned \(windowInfoList.count) entries for options rawValue=\(options.rawValue)")
        }

        return windowInfoList.enumerated().map { index, info in
            CGWindowListEntry(orderIndex: index, dictionary: info)
        }
    }

    func visibleWindowCandidates() -> [CGWindowCandidate] {
        let entries = allWindowEntries(options: [.optionOnScreenOnly, .excludeDesktopElements], logResult: true)
        return visibleWindowCandidates(from: entries, logFiltering: true)
    }

    func visibleWindowCandidates(from entries: [CGWindowListEntry], logFiltering: Bool = false) -> [CGWindowCandidate] {
        let currentPID = pid_t(ProcessInfo.processInfo.processIdentifier)
        var candidates: [CGWindowCandidate] = []

        for entry in entries {
            guard let ownerPID = entry.ownerPID else {
                if logFiltering {
                    Logger.debug("Skipping window at order \(entry.orderIndex): missing owner PID")
                }
                continue
            }

            if ownerPID == currentPID {
                if logFiltering {
                    Logger.debug("Skipping window at order \(entry.orderIndex): owned by MissionSwipe pid=\(ownerPID)")
                }
                continue
            }

            if Self.ignoredSystemOwnerNames.contains(entry.ownerName) {
                if logFiltering {
                    Logger.debug("Skipping window at order \(entry.orderIndex): ignored owner \(entry.ownerName)")
                }
                continue
            }

            guard let layer = entry.layer else {
                if logFiltering {
                    Logger.debug("Skipping window at order \(entry.orderIndex): missing layer")
                }
                continue
            }

            guard layer == 0 else {
                if logFiltering {
                    Logger.debug("Skipping window at order \(entry.orderIndex): layer \(layer) is not a normal app window layer")
                }
                continue
            }

            guard let bounds = entry.bounds else {
                if logFiltering {
                    Logger.debug("Skipping window at order \(entry.orderIndex): missing or invalid bounds")
                }
                continue
            }

            guard bounds.width >= 40, bounds.height >= 40 else {
                if logFiltering {
                    Logger.debug("Skipping window at order \(entry.orderIndex): tiny bounds \(bounds.integral)")
                }
                continue
            }

            if entry.isOnscreen == false {
                if logFiltering {
                    Logger.debug("Skipping window at order \(entry.orderIndex): not onscreen")
                }
                continue
            }

            let alpha = entry.alpha ?? 1.0
            guard alpha > 0.01 else {
                if logFiltering {
                    Logger.debug("Skipping window at order \(entry.orderIndex): alpha \(alpha)")
                }
                continue
            }

            guard let windowID = entry.windowID else {
                if logFiltering {
                    Logger.debug("Skipping window at order \(entry.orderIndex): missing window number")
                }
                continue
            }

            let candidate = CGWindowCandidate(
                orderIndex: entry.orderIndex,
                windowID: windowID,
                ownerPID: ownerPID,
                ownerName: entry.ownerName,
                title: entry.title,
                bounds: bounds,
                layer: layer,
                alpha: alpha
            )
            if logFiltering {
                Logger.debug("Keeping candidate: \(candidate.debugSummary)")
            }
            candidates.append(candidate)
        }

        if logFiltering {
            Logger.info("Filtered to \(candidates.count) eligible normal windows")
        }

        return candidates
    }
}

private enum CoordinateConverter {
    static func appKitPointToCGWindowPoint(_ point: CGPoint) -> CGPoint {
        let mainScreenHeight = NSScreen.screens.first?.frame.height ?? CGDisplayBounds(CGMainDisplayID()).height

        /*
         NSEvent.mouseLocation uses AppKit's global desktop coordinates, where the main
         display's origin is at the lower-left and y increases upward. CGWindow bounds
         use Quartz display coordinates, where the main display's origin is at the
         upper-left and y increases downward. Flipping y around the main screen height
         puts the mouse point into the same coordinate space used by CGWindowList.
         */
        return CGPoint(x: point.x, y: mainScreenHeight - point.y)
    }
}
