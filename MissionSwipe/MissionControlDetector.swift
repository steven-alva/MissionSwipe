import AppKit
import CoreGraphics
import Foundation

struct MissionControlDetection {
    let isLikelyActive: Bool
    let score: Int
    let confidence: MatchingConfidence
    let reasons: [String]
    let entries: [CGWindowListEntry]

    var debugSummary: String {
        "isLikelyActive=\(isLikelyActive), score=\(score), confidence=\(confidence), reasons=\(reasons.joined(separator: " | "))"
    }
}

final class MissionControlDetector {
    private let windowEnumerator: WindowEnumerator

    init(windowEnumerator: WindowEnumerator = WindowEnumerator()) {
        self.windowEnumerator = windowEnumerator
    }

    func detect(mousePoint: CGPoint) -> MissionControlDetection {
        let entries = windowEnumerator.allWindowEntries(options: [.optionOnScreenOnly])
        let detection = detect(mousePoint: mousePoint, entries: entries)
        Logger.info("Mission Control detection: \(detection.debugSummary), cgWindowEntries=\(entries.count)")

        return detection
    }

    func detect(mousePoint: CGPoint, entries: [CGWindowListEntry]) -> MissionControlDetection {
        let displayBounds = DisplayBoundsHelper.displayBounds(containing: mousePoint)
        let displayArea = max(displayBounds.width * displayBounds.height, 1)

        var score = 0
        var reasons: [String] = []
        var explicitMissionControlSignals = 0

        if let frontmostApplication = NSWorkspace.shared.frontmostApplication {
            let frontmostName = frontmostApplication.localizedName ?? ""
            let frontmostBundleIdentifier = frontmostApplication.bundleIdentifier ?? ""

            if frontmostBundleIdentifier == "com.apple.dock" || frontmostName == "Dock" || frontmostName == "程序坞" {
                score += 30
                reasons.append("Dock is the frontmost application")
            }
        }

        let systemOverlayEntries = entries.filter { entry in
            guard let layer = entry.layer, layer > 0 else {
                return false
            }
            return isMissionControlRelatedSystemOwner(entry.ownerName)
        }

        let dockOverlayEntries = systemOverlayEntries.filter { $0.ownerName == "Dock" || $0.ownerName == "程序坞" }
        let largeSystemOverlayEntries = systemOverlayEntries.filter { entry in
            guard let bounds = entry.bounds else {
                return false
            }
            return (bounds.width * bounds.height) >= displayArea * 0.20
        }
        let dockFullDisplayOverlayEntries = dockOverlayEntries.filter { entry in
            guard let bounds = entry.bounds else {
                return false
            }
            return isFullDisplayOverlay(bounds, displayBounds: displayBounds)
        }
        let normalAppWindows = windowEnumerator.visibleWindowCandidates(from: entries)
        let missionControlThumbnailCandidates = normalAppWindows.filter { candidate in
            isLikelyMissionControlThumbnail(candidate.bounds, displayBounds: displayBounds)
        }

        for entry in entries.prefix(8) {
            let title = entry.title.lowercased()
            let owner = entry.ownerName.lowercased()

            if owner == "dock",
               title.contains("mission") || title.contains("expose") || title.contains("spaces") {
                score += 80
                explicitMissionControlSignals += 1
                reasons.append("Dock owns an explicit Mission Control/Spaces related window near the top of the list: \(entry.fullDebugSummary)")
            }

            if isMissionControlRelatedSystemOwner(entry.ownerName),
               let layer = entry.layer,
               layer > 0,
               let bounds = entry.bounds,
               bounds.contains(mousePoint) {
                score += 20
                reasons.append("Mouse is over a non-normal system overlay from \(entry.ownerName) at layer \(layer)")
            }
        }

        if !dockOverlayEntries.isEmpty {
            let bonus = min(35, dockOverlayEntries.count * 12)
            score += bonus
            reasons.append("Dock has \(dockOverlayEntries.count) visible non-zero-layer overlay window(s)")
        }

        if !largeSystemOverlayEntries.isEmpty {
            let bonus = min(40, largeSystemOverlayEntries.count * 20)
            score += bonus
            reasons.append("\(largeSystemOverlayEntries.count) large system overlay window(s) are visible")
        }

        if !dockFullDisplayOverlayEntries.isEmpty {
            let bonus = min(45, dockFullDisplayOverlayEntries.count * 18)
            score += bonus
            reasons.append("Dock has \(dockFullDisplayOverlayEntries.count) full-display overlay window(s)")
        }

        if missionControlThumbnailCandidates.count >= 2 {
            score += 30
            reasons.append("\(missionControlThumbnailCandidates.count) app window(s) look like Mission Control thumbnails")
        }

        let topSystemOverlayCount = entries.prefix(5).filter { entry in
            guard let layer = entry.layer, layer > 0 else {
                return false
            }
            return isMissionControlRelatedSystemOwner(entry.ownerName)
        }.count

        if topSystemOverlayCount >= 2 {
            score += 20
            reasons.append("Multiple top z-order entries are system overlays")
        }

        let normalAppWindowCount = normalAppWindows.count
        if normalAppWindowCount == 0, !systemOverlayEntries.isEmpty {
            score += 15
            reasons.append("No normal app windows survived filtering while system overlays are visible")
        }

        let likelyActiveThreshold = 50
        let hasMissionControlLayoutEvidence =
            explicitMissionControlSignals > 0 ||
            dockFullDisplayOverlayEntries.count >= 2 ||
            (dockOverlayEntries.count >= 3 && missionControlThumbnailCandidates.count >= 2)

        if score >= likelyActiveThreshold, !hasMissionControlLayoutEvidence {
            score = min(score, likelyActiveThreshold - 1)
            reasons.append("System overlays look Stage Manager-like; no Mission Control layout evidence found")
        }

        let confidence: MatchingConfidence
        if score >= 85 {
            confidence = .high
        } else if score >= 50 {
            confidence = .medium
        } else if score > 0 {
            confidence = .low
        } else {
            confidence = .none
        }

        return MissionControlDetection(
            isLikelyActive: score >= likelyActiveThreshold,
            score: score,
            confidence: confidence,
            reasons: reasons.isEmpty ? ["No Mission Control heuristics matched"] : reasons,
            entries: entries
        )
    }

    private func isMissionControlRelatedSystemOwner(_ ownerName: String) -> Bool {
        ownerName == "Dock" ||
        ownerName == "程序坞" ||
        ownerName == "SystemUIServer" ||
        ownerName == "Control Center" ||
        ownerName == "控制中心" ||
        ownerName == "WindowServer" ||
        ownerName == "Window Server"
    }

    private func isFullDisplayOverlay(_ bounds: CGRect, displayBounds: CGRect) -> Bool {
        let intersection = bounds.intersection(displayBounds)
        guard !intersection.isNull, !intersection.isEmpty else {
            return false
        }

        let displayArea = max(displayBounds.width * displayBounds.height, 1)
        return (intersection.width * intersection.height) >= displayArea * 0.75
    }

    private func isLikelyMissionControlThumbnail(_ bounds: CGRect, displayBounds: CGRect) -> Bool {
        let intersection = bounds.intersection(displayBounds)
        guard !intersection.isNull, !intersection.isEmpty else {
            return false
        }

        let displayArea = max(displayBounds.width * displayBounds.height, 1)
        let areaRatio = (intersection.width * intersection.height) / displayArea
        let widthRatio = intersection.width / max(displayBounds.width, 1)
        let heightRatio = intersection.height / max(displayBounds.height, 1)

        return areaRatio >= 0.04 &&
            areaRatio <= 0.65 &&
            widthRatio <= 0.90 &&
            heightRatio <= 0.90
    }
}

enum DisplayBoundsHelper {
    static func displayBounds(containing point: CGPoint) -> CGRect {
        var displayCount: UInt32 = 0
        var displayIDs = [CGDirectDisplayID](repeating: 0, count: 16)

        let result = CGGetActiveDisplayList(UInt32(displayIDs.count), &displayIDs, &displayCount)
        if result == .success {
            for displayID in displayIDs.prefix(Int(displayCount)) {
                let bounds = CGDisplayBounds(displayID)
                if bounds.contains(point) {
                    return bounds
                }
            }
        }

        return CGDisplayBounds(CGMainDisplayID())
    }
}
