import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

final class LayoutDiagnosticCapture {
    private struct DisplayInfo {
        let index: Int
        let name: String
        let fullBounds: CGRect
        let visibleBounds: CGRect
    }

    private struct WindowInfo {
        let candidate: CGWindowCandidate
        let frame: CGRect
        let axTitle: String
        let axMinimized: Bool?
    }

    private let windowEnumerator: WindowEnumerator
    private let axWindowController: AXWindowController
    private let permissionManager: AccessibilityPermissionManager

    init(
        windowEnumerator: WindowEnumerator = WindowEnumerator(),
        axWindowController: AXWindowController = AXWindowController(),
        permissionManager: AccessibilityPermissionManager = AccessibilityPermissionManager()
    ) {
        self.windowEnumerator = windowEnumerator
        self.axWindowController = axWindowController
        self.permissionManager = permissionManager
    }

    func capture() -> String {
        var lines: [String] = []
        appendHeader(into: &lines)

        guard permissionManager.isAccessibilityTrusted else {
            lines.append("verdict: FAIL")
            lines.append("reason: accessibility permission missing")
            return lines.joined(separator: "\n")
        }

        let displays = currentDisplays()
        let entries = windowEnumerator.allWindowEntries(options: [.optionOnScreenOnly, .excludeDesktopElements])
        let candidates = windowEnumerator.visibleWindowCandidates(from: entries, logFiltering: false)
        let windows = collectWindowInfo(candidates: candidates)
        let pidCounts = collectPIDCounts(candidates: candidates)

        lines.append("visible_candidates: \(candidates.count)")
        lines.append("matched_windows: \(windows.count)")
        lines.append("")
        appendPIDCounts(pidCounts, into: &lines)
        appendDisplays(displays, windows: windows, into: &lines)
        appendOverlaps(windows, into: &lines)
        appendOverflows(windows, displays: displays, into: &lines)
        appendWindowList(windows, displays: displays, into: &lines)
        appendVerdict(windows: windows, displays: displays, pidCounts: pidCounts, into: &lines)
        return lines.joined(separator: "\n")
    }

    private func appendHeader(into lines: inout [String]) {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        lines.append("===== MissionSwipe Layout Check =====")
        lines.append("captured_at: \(formatter.string(from: Date()))")
        lines.append("app_version: \((Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "unknown") (build \((Bundle.main.infoDictionary?["CFBundleVersion"] as? String) ?? "unknown"))")
        lines.append("")
    }

    private func appendPIDCounts(_ counts: [(pid: pid_t, owner: String, cgVisible: Int, axTotal: Int, axNonMinimized: Int)], into lines: inout [String]) {
        lines.append("----- PID Window Counts -----")
        if counts.isEmpty {
            lines.append("(none)")
        } else {
            for count in counts {
                let hidden = max(0, count.axNonMinimized - count.cgVisible)
                lines.append("pid=\(count.pid) owner=\"\(count.owner)\" cg_visible=\(count.cgVisible) ax_total=\(count.axTotal) ax_non_minimized=\(count.axNonMinimized) hidden_or_unmatched=\(hidden)")
            }
        }
        lines.append("")
    }

    private func appendDisplays(_ displays: [DisplayInfo], windows: [WindowInfo], into lines: inout [String]) {
        lines.append("----- Display Coverage -----")
        for display in displays {
            let displayWindows = windows.filter { display.visibleBounds.intersects($0.frame) }
            let union = unionArea(displayWindows.map { $0.frame.intersection(display.visibleBounds) })
            let area = max(1, display.visibleBounds.width * display.visibleBounds.height)
            let coverage = union / area
            lines.append("[display \(display.index)] \(display.name)")
            lines.append("  visible_bounds=\(rectString(display.visibleBounds))")
            lines.append("  window_count=\(displayWindows.count)")
            lines.append("  coverage=\(String(format: "%.1f", coverage * 100))%")
        }
        lines.append("")
    }

    private func appendOverlaps(_ windows: [WindowInfo], into lines: inout [String]) {
        lines.append("----- Overlaps -----")
        var found = false
        for lhsIndex in windows.indices {
            for rhsIndex in windows.indices where rhsIndex > lhsIndex {
                let lhs = windows[lhsIndex]
                let rhs = windows[rhsIndex]
                let intersection = lhs.frame.intersection(rhs.frame)
                guard !intersection.isNull, !intersection.isEmpty else {
                    continue
                }
                found = true
                let smaller = max(1, min(lhs.frame.width * lhs.frame.height, rhs.frame.width * rhs.frame.height))
                let ratio = intersection.width * intersection.height / smaller
                lines.append("OVERLAP \(String(format: "%.1f", ratio * 100))%: \(windowLabel(lhs)) <-> \(windowLabel(rhs)), intersection=\(rectString(intersection))")
            }
        }
        if !found {
            lines.append("none")
        }
        lines.append("")
    }

    private func appendOverflows(_ windows: [WindowInfo], displays: [DisplayInfo], into lines: inout [String]) {
        lines.append("----- Overflow -----")
        var found = false
        for window in windows {
            let display = displayFor(frame: window.frame, displays: displays)
            let overflow = overflowDescription(frame: window.frame, bounds: display.visibleBounds)
            guard !overflow.isEmpty else {
                continue
            }
            found = true
            lines.append("OVERFLOW \(overflow): \(windowLabel(window)), frame=\(rectString(window.frame)), display=\(rectString(display.visibleBounds))")
        }
        if !found {
            lines.append("none")
        }
        lines.append("")
    }

    private func appendWindowList(_ windows: [WindowInfo], displays: [DisplayInfo], into lines: inout [String]) {
        lines.append("----- Windows -----")
        for (index, window) in windows.enumerated() {
            let display = displayFor(frame: window.frame, displays: displays)
            lines.append("[window \(index)] display=\(display.index) owner=\"\(window.candidate.ownerName)\" title=\"\(window.axTitle)\" frame=\(rectString(window.frame)) order=\(window.candidate.orderIndex) minimized=\(window.axMinimized.map(String.init) ?? "nil")")
        }
        lines.append("")
    }

    private func appendVerdict(
        windows: [WindowInfo],
        displays: [DisplayInfo],
        pidCounts: [(pid: pid_t, owner: String, cgVisible: Int, axTotal: Int, axNonMinimized: Int)],
        into lines: inout [String]
    ) {
        let overlapCount = overlapPairs(windows).count
        let overflowCount = windows.filter { !overflowDescription(frame: $0.frame, bounds: displayFor(frame: $0.frame, displays: displays).visibleBounds).isEmpty }.count
        let hiddenCount = pidCounts.reduce(0) { total, count in
            total + max(0, count.axNonMinimized - count.cgVisible)
        }
        let lowCoverageCount = displays.filter { display in
            let displayWindows = windows.filter { display.visibleBounds.intersects($0.frame) }
            guard !displayWindows.isEmpty else { return false }
            let coverage = unionArea(displayWindows.map { $0.frame.intersection(display.visibleBounds) }) / max(1, display.visibleBounds.width * display.visibleBounds.height)
            return coverage < 0.70
        }.count

        lines.append("----- Verdict -----")
        if overflowCount > 0 || overlapCount > 0 {
            lines.append("verdict: FAIL")
        } else if hiddenCount > 0 || lowCoverageCount > 0 {
            lines.append("verdict: WARN")
        } else {
            lines.append("verdict: PASS")
        }
        lines.append("overlap_pairs: \(overlapCount)")
        lines.append("overflow_windows: \(overflowCount)")
        lines.append("hidden_or_unmatched_ax_windows: \(hiddenCount)")
        lines.append("low_coverage_displays: \(lowCoverageCount)")
        lines.append("===== End Layout Check =====")
    }

    private func collectWindowInfo(candidates: [CGWindowCandidate]) -> [WindowInfo] {
        var axCache: [pid_t: [AXWindowSnapshot]] = [:]
        var result: [WindowInfo] = []
        for candidate in candidates {
            let axWindows: [AXWindowSnapshot]
            if let cached = axCache[candidate.ownerPID] {
                axWindows = cached
            } else {
                let fetched = axWindowController.windows(forPID: candidate.ownerPID)
                axCache[candidate.ownerPID] = fetched
                axWindows = fetched
            }
            let match = axWindowController.bestMatch(for: candidate, in: axWindows)
            let snapshot = match?.window
            let frame = snapshot?.frame ?? candidate.bounds
            result.append(
                WindowInfo(
                    candidate: candidate,
                    frame: frame.integral,
                    axTitle: snapshot?.title ?? candidate.title,
                    axMinimized: snapshot.flatMap { boolAttribute($0.element, kAXMinimizedAttribute as CFString) }
                )
            )
        }
        return result
    }

    private func collectPIDCounts(candidates: [CGWindowCandidate]) -> [(pid: pid_t, owner: String, cgVisible: Int, axTotal: Int, axNonMinimized: Int)] {
        let grouped = Dictionary(grouping: candidates, by: \.ownerPID)
        return grouped.keys.sorted().map { pid in
            let axWindows = axWindowController.windows(forPID: pid)
            let nonMinimized = axWindows.filter { boolAttribute($0.element, kAXMinimizedAttribute as CFString) != true }.count
            return (
                pid: pid,
                owner: grouped[pid]?.first?.ownerName ?? "",
                cgVisible: grouped[pid]?.count ?? 0,
                axTotal: axWindows.count,
                axNonMinimized: nonMinimized
            )
        }
    }

    private func currentDisplays() -> [DisplayInfo] {
        NSScreen.screens.enumerated().compactMap { index, screen in
            guard let screenNumber = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
                return nil
            }
            let displayID = CGDirectDisplayID(screenNumber.uint32Value)
            let fullBounds = CGDisplayBounds(displayID).integral
            let visibleBounds = cgWindowRect(
                forVisibleFrame: screen.visibleFrame,
                screenFrame: screen.frame,
                cgFullBounds: fullBounds
            ).intersection(fullBounds).integral
            return DisplayInfo(
                index: index,
                name: screen.localizedName,
                fullBounds: fullBounds,
                visibleBounds: visibleBounds.isNull || visibleBounds.isEmpty ? fullBounds : visibleBounds
            )
        }
    }

    private func displayFor(frame: CGRect, displays: [DisplayInfo]) -> DisplayInfo {
        guard let best = displays.max(by: { intersectionArea(frame, $0.visibleBounds) < intersectionArea(frame, $1.visibleBounds) }) else {
            return DisplayInfo(index: 0, name: "unknown", fullBounds: frame, visibleBounds: frame)
        }
        return best
    }

    private func overlapPairs(_ windows: [WindowInfo]) -> [(WindowInfo, WindowInfo)] {
        var pairs: [(WindowInfo, WindowInfo)] = []
        for lhsIndex in windows.indices {
            for rhsIndex in windows.indices where rhsIndex > lhsIndex {
                let intersection = windows[lhsIndex].frame.intersection(windows[rhsIndex].frame)
                if !intersection.isNull, !intersection.isEmpty {
                    pairs.append((windows[lhsIndex], windows[rhsIndex]))
                }
            }
        }
        return pairs
    }

    private func overflowDescription(frame: CGRect, bounds: CGRect) -> String {
        let tolerance: CGFloat = 4
        var parts: [String] = []
        if frame.minX < bounds.minX - tolerance {
            parts.append("left=\(Int(bounds.minX - frame.minX))")
        }
        if frame.minY < bounds.minY - tolerance {
            parts.append("top=\(Int(bounds.minY - frame.minY))")
        }
        if frame.maxX > bounds.maxX + tolerance {
            parts.append("right=\(Int(frame.maxX - bounds.maxX))")
        }
        if frame.maxY > bounds.maxY + tolerance {
            parts.append("bottom=\(Int(frame.maxY - bounds.maxY))")
        }
        return parts.joined(separator: ",")
    }

    private func unionArea(_ rects: [CGRect]) -> CGFloat {
        let validRects = rects.filter { !$0.isNull && !$0.isEmpty }
        guard !validRects.isEmpty else {
            return 0
        }

        let xs = Array(Set(validRects.flatMap { [$0.minX, $0.maxX] })).sorted()
        guard xs.count > 1 else {
            return 0
        }

        var area: CGFloat = 0
        for index in 0..<(xs.count - 1) {
            let x0 = xs[index]
            let x1 = xs[index + 1]
            guard x1 > x0 else {
                continue
            }

            let intervals = validRects.compactMap { rect -> ClosedRange<CGFloat>? in
                guard rect.minX < x1, rect.maxX > x0 else {
                    return nil
                }
                return rect.minY...rect.maxY
            }.sorted { $0.lowerBound < $1.lowerBound }

            var coveredHeight: CGFloat = 0
            var current: ClosedRange<CGFloat>?
            for interval in intervals {
                guard let existing = current else {
                    current = interval
                    continue
                }
                if interval.lowerBound <= existing.upperBound {
                    current = existing.lowerBound...max(existing.upperBound, interval.upperBound)
                } else {
                    coveredHeight += existing.upperBound - existing.lowerBound
                    current = interval
                }
            }
            if let current {
                coveredHeight += current.upperBound - current.lowerBound
            }
            area += (x1 - x0) * coveredHeight
        }
        return area
    }

    private func windowLabel(_ window: WindowInfo) -> String {
        "\(window.candidate.ownerName) \"\(window.axTitle)\""
    }

    private func rectString(_ rect: CGRect) -> String {
        "x=\(Int(rect.minX)), y=\(Int(rect.minY)), w=\(Int(rect.width)), h=\(Int(rect.height))"
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

    private func intersectionArea(_ lhs: CGRect, _ rhs: CGRect) -> CGFloat {
        let intersection = lhs.intersection(rhs)
        guard !intersection.isNull, !intersection.isEmpty else {
            return 0
        }
        return intersection.width * intersection.height
    }

    private func boolAttribute(_ element: AXUIElement, _ attribute: CFString) -> Bool? {
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, attribute, &value)
        guard result == .success, let cfBool = value, CFGetTypeID(cfBool) == CFBooleanGetTypeID() else {
            return nil
        }
        return CFBooleanGetValue((cfBool as! CFBoolean))
    }
}
