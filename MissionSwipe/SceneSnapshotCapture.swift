import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

/// One-shot diagnostic dump for cross-machine debugging.
/// Produces a single multi-section text blob covering system info, every display's
/// physical/logical dimensions, current configuration, and every visible window's
/// CG + AX + bundle metadata. Designed to be copied into a bug report.
final class SceneSnapshotCapture {
    private let windowEnumerator: WindowEnumerator
    private let axWindowController: AXWindowController
    private let permissionManager: AccessibilityPermissionManager
    private let configuration: AppConfiguration

    init(
        windowEnumerator: WindowEnumerator = WindowEnumerator(),
        axWindowController: AXWindowController = AXWindowController(),
        permissionManager: AccessibilityPermissionManager = AccessibilityPermissionManager(),
        configuration: AppConfiguration = AppConfiguration.shared
    ) {
        self.windowEnumerator = windowEnumerator
        self.axWindowController = axWindowController
        self.permissionManager = permissionManager
        self.configuration = configuration
    }

    func capture() -> String {
        var lines: [String] = []
        appendHeader(into: &lines)
        appendSystem(into: &lines)
        appendDisplays(into: &lines)
        appendConfiguration(into: &lines)
        appendWindows(into: &lines)
        appendFooter(into: &lines)
        return lines.joined(separator: "\n")
    }

    // MARK: - Sections

    private func appendHeader(into lines: inout [String]) {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let timestamp = formatter.string(from: Date())
        lines.append("===== MissionSwipe Scene Snapshot =====")
        lines.append("captured_at: \(timestamp)")
        lines.append("")
    }

    private func appendSystem(into lines: inout [String]) {
        lines.append("----- System -----")
        let processInfo = ProcessInfo.processInfo
        let osVersion = processInfo.operatingSystemVersionString
        let osStruct = processInfo.operatingSystemVersion
        let cpu = currentArchitecture()
        let physicalMemoryGB = Double(processInfo.physicalMemory) / (1024.0 * 1024.0 * 1024.0)
        lines.append("os_version: \(osVersion)")
        lines.append("os_semver: \(osStruct.majorVersion).\(osStruct.minorVersion).\(osStruct.patchVersion)")
        lines.append("hardware_model: \(hardwareModel() ?? "unknown")")
        lines.append("cpu_arch: \(cpu)")
        lines.append("physical_memory_gb: \(String(format: "%.1f", physicalMemoryGB))")
        lines.append("hostname: \(processInfo.hostName)")
        lines.append("locale: \(Locale.current.identifier)")
        lines.append("user_preferred_languages: \(Locale.preferredLanguages.joined(separator: ","))")

        let bundle = Bundle.main
        let shortVersion = (bundle.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "unknown"
        let buildNumber = (bundle.infoDictionary?["CFBundleVersion"] as? String) ?? "unknown"
        let bundleID = bundle.bundleIdentifier ?? "unknown"
        lines.append("app_version: \(shortVersion) (build \(buildNumber))")
        lines.append("app_bundle_id: \(bundleID)")
        lines.append("app_dev_build: \(AppConfiguration.isDevBuild)")
        lines.append("app_executable_path: \(bundle.executablePath ?? "unknown")")
        lines.append("accessibility_trusted: \(permissionManager.isAccessibilityTrusted)")
        lines.append("")
    }

    private func appendDisplays(into lines: inout [String]) {
        lines.append("----- Displays -----")
        let screens = NSScreen.screens
        lines.append("screen_count: \(screens.count)")
        let mainScreenID = NSScreen.main?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
        for (index, screen) in screens.enumerated() {
            lines.append("[screen \(index)]")
            let screenNumber = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
            let displayID = screenNumber.map { CGDirectDisplayID($0.uint32Value) }
            lines.append("  display_id: \(displayID.map(String.init) ?? "nil")")
            lines.append("  is_main: \(screenNumber == mainScreenID)")
            lines.append("  localized_name: \(screen.localizedName)")
            lines.append("  frame: \(rectString(screen.frame))")
            lines.append("  visible_frame: \(rectString(screen.visibleFrame))")
            lines.append("  backing_scale_factor: \(screen.backingScaleFactor)")
            if let displayID {
                let mm = CGDisplayScreenSize(displayID)
                let widthInches = mm.width / 25.4
                let heightInches = mm.height / 25.4
                let diagonalInches = sqrt(widthInches * widthInches + heightInches * heightInches)
                lines.append("  physical_mm: width=\(String(format: "%.1f", mm.width)), height=\(String(format: "%.1f", mm.height))")
                lines.append("  physical_inches: width=\(String(format: "%.2f", widthInches)), height=\(String(format: "%.2f", heightInches)), diagonal=\(String(format: "%.2f", diagonalInches))")
                if widthInches > 0 {
                    let ppi = screen.frame.width / widthInches
                    lines.append("  ppi_logical: \(String(format: "%.1f", ppi))")
                    let nativePPI = (screen.frame.width * screen.backingScaleFactor) / widthInches
                    lines.append("  ppi_native: \(String(format: "%.1f", nativePPI))")
                }
                let pixelW = Int(screen.frame.width * screen.backingScaleFactor)
                let pixelH = Int(screen.frame.height * screen.backingScaleFactor)
                lines.append("  native_pixels: \(pixelW) x \(pixelH)")
                if CGDisplayIsBuiltin(displayID) != 0 {
                    lines.append("  builtin: true")
                } else {
                    lines.append("  builtin: false")
                }
                lines.append("  rotation_degrees: \(Int(CGDisplayRotation(displayID)))")
            }
        }
        lines.append("")
    }

    private func appendConfiguration(into lines: inout [String]) {
        lines.append("----- Configuration -----")
        lines.append("language: \(configuration.language.rawValue)")
        lines.append("debug_logging: \(configuration.enableDebugLogging)")
        lines.append("recent_log_line_count: \(configuration.recentLogLineCount.rawValue)")
        lines.append("hide_status_bar_icon: \(configuration.hideStatusBarIcon)")
        lines.append("")
        lines.append("[gestures]")
        lines.append("  mission_control_mode: \(configuration.enableMissionControlMode)")
        lines.append("  swipe_up_to_close: \(configuration.enableSwipeUpToClose)")
        lines.append("  swipe_down_to_minimize: \(configuration.enableSwipeDownToMinimize)")
        lines.append("  blank_area_swipe_up_arrange: \(configuration.enableBlankAreaSwipeUpToArrange)")
        lines.append("  preview_layout_gestures: \(configuration.enablePreviewLayoutGestures)")
        lines.append("  second_mc_swipe_up_arrange: \(configuration.enableSecondMissionControlSwipeUpToArrange)")
        lines.append("")
        lines.append("[smart_fit]")
        lines.append("  enabled: \(configuration.enableSmartFitArrange)")
        lines.append("  overflow_strategy: \(configuration.smartFitOverflowStrategy.rawValue)")
        lines.append("  overlap_tolerance: \(String(format: "%.2f", configuration.smartFitOverlapTolerance))")
        lines.append("  three_window_layout: \(configuration.threeWindowLayout.rawValue)")
        lines.append("  four_window_layout: \(configuration.fourWindowLayout.rawValue)")
        lines.append("  five_window_layout: \(configuration.fiveWindowLayout.rawValue)")
        let profile = configuration.smartFitCapacityProfile
        lines.append("  capacity_compact: \(profile.compact)")
        lines.append("  capacity_laptop: \(profile.laptop)")
        lines.append("  capacity_desktop: \(profile.desktop)")
        lines.append("  capacity_large: \(profile.large)")
        lines.append("  capacity_huge: \(profile.huge)")
        lines.append("")
        lines.append("[probes]")
        lines.append("  mission_control_gesture_probe: \(configuration.enableMissionControlGestureProbe)")
        lines.append("  input_event_probe: \(configuration.enableInputEventProbe)")
        lines.append("")
    }

    private func appendWindows(into lines: inout [String]) {
        lines.append("----- Windows -----")
        let entries = windowEnumerator.allWindowEntries(
            options: [.optionOnScreenOnly, .excludeDesktopElements]
        )
        lines.append("cg_entries_total: \(entries.count)")

        let frontmostPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let candidates = windowEnumerator.visibleWindowCandidates(from: entries, logFiltering: false)
        lines.append("visible_candidates: \(candidates.count)")
        lines.append("frontmost_pid: \(frontmostPID.map(String.init) ?? "nil")")
        lines.append("")

        guard !candidates.isEmpty else {
            lines.append("(no eligible visible windows)")
            lines.append("")
            return
        }

        let groupedByPID = Dictionary(grouping: candidates) { $0.ownerPID }
        let axCache: [pid_t: [AXWindowSnapshot]]
        if permissionManager.isAccessibilityTrusted {
            var cache: [pid_t: [AXWindowSnapshot]] = [:]
            for pid in groupedByPID.keys {
                cache[pid] = axWindowController.windows(forPID: pid)
            }
            axCache = cache
        } else {
            lines.append("(accessibility permission missing — AX details will be empty)")
            lines.append("")
            axCache = [:]
        }

        for (index, candidate) in candidates.enumerated() {
            lines.append("[window \(index)]")
            lines.append("  cg_window_id: \(candidate.windowID)")
            lines.append("  cg_owner_name: \"\(candidate.ownerName)\"")
            lines.append("  cg_title: \"\(candidate.title)\"")
            lines.append("  cg_bounds: \(rectString(candidate.bounds))")
            lines.append("  cg_layer: \(candidate.layer)")
            lines.append("  cg_alpha: \(String(format: "%.2f", candidate.alpha))")
            lines.append("  cg_order_index: \(candidate.orderIndex)")
            lines.append("  pid: \(candidate.ownerPID)")
            lines.append("  is_frontmost: \(candidate.ownerPID == frontmostPID)")

            if let app = NSRunningApplication(processIdentifier: candidate.ownerPID) {
                lines.append("  app_bundle_id: \(app.bundleIdentifier ?? "nil")")
                lines.append("  app_localized_name: \(app.localizedName ?? "nil")")
                lines.append("  app_bundle_url: \(app.bundleURL?.path ?? "nil")")
                lines.append("  app_executable_url: \(app.executableURL?.path ?? "nil")")
                lines.append("  app_activation_policy: \(activationPolicyName(app.activationPolicy))")
                lines.append("  app_launch_date: \(app.launchDate.map { ISO8601DateFormatter().string(from: $0) } ?? "nil")")
            } else {
                lines.append("  app_bundle_id: (NSRunningApplication unavailable for pid)")
            }

            let axWindowsForPID = axCache[candidate.ownerPID] ?? []
            appendAXMatch(for: candidate, in: axWindowsForPID, into: &lines)
            lines.append("")
        }

        lines.append("----- AX Window Counts Per PID -----")
        for pid in groupedByPID.keys.sorted() {
            let cgCount = groupedByPID[pid]?.count ?? 0
            let axCount = axCache[pid]?.count ?? 0
            let owner = groupedByPID[pid]?.first?.ownerName ?? ""
            lines.append("  pid=\(pid) owner=\"\(owner)\" cg_visible=\(cgCount) ax_total=\(axCount)")
        }
        lines.append("")
    }

    private func appendAXMatch(
        for candidate: CGWindowCandidate,
        in axWindows: [AXWindowSnapshot],
        into lines: inout [String]
    ) {
        guard !axWindows.isEmpty else {
            lines.append("  ax_match: (no AX windows for pid)")
            return
        }
        guard let match = axWindowController.bestMatch(for: candidate, in: axWindows) else {
            lines.append("  ax_match: (no match found among \(axWindows.count) AX windows)")
            return
        }
        let window = match.window
        lines.append("  ax_confidence: \(match.confidence)")
        lines.append("  ax_score: \(match.score)")
        lines.append("  ax_title: \"\(window.title)\"")
        lines.append("  ax_role: \(window.role)")
        lines.append("  ax_subrole: \(window.subrole)")
        if let pos = window.position {
            lines.append("  ax_position: (\(Int(pos.x)), \(Int(pos.y)))")
        }
        if let size = window.size {
            lines.append("  ax_size: \(Int(size.width)) x \(Int(size.height))")
        }
        let attrs = axAttributeNames(for: window.element)
        if !attrs.isEmpty {
            lines.append("  ax_attribute_names: [\(attrs.joined(separator: ", "))]")
        }
        if let minimized = axBool(window.element, kAXMinimizedAttribute as CFString) {
            lines.append("  ax_minimized: \(minimized)")
        }
        if let fullscreen = axBool(window.element, "AXFullScreen" as CFString) {
            lines.append("  ax_fullscreen: \(fullscreen)")
        }
        if let main = axBool(window.element, kAXMainAttribute as CFString) {
            lines.append("  ax_main: \(main)")
        }
        if let focused = axBool(window.element, kAXFocusedAttribute as CFString) {
            lines.append("  ax_focused: \(focused)")
        }
    }

    private func appendFooter(into lines: inout [String]) {
        lines.append("===== End Scene Snapshot =====")
    }

    // MARK: - Helpers

    private func rectString(_ rect: CGRect) -> String {
        "x=\(Int(rect.origin.x)), y=\(Int(rect.origin.y)), w=\(Int(rect.width)), h=\(Int(rect.height))"
    }

    private func currentArchitecture() -> String {
        var sysinfo = utsname()
        guard uname(&sysinfo) == 0 else { return "unknown" }
        let scalars = Mirror(reflecting: sysinfo.machine).children.compactMap { child -> UnicodeScalar? in
            guard let byte = child.value as? Int8, byte != 0 else { return nil }
            return UnicodeScalar(UInt8(bitPattern: byte))
        }
        return String(String.UnicodeScalarView(scalars))
    }

    private func hardwareModel() -> String? {
        var size: Int = 0
        sysctlbyname("hw.model", nil, &size, nil, 0)
        guard size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        let result = sysctlbyname("hw.model", &buffer, &size, nil, 0)
        guard result == 0 else { return nil }
        return String(cString: buffer)
    }

    private func activationPolicyName(_ policy: NSApplication.ActivationPolicy) -> String {
        switch policy {
        case .regular: return "regular"
        case .accessory: return "accessory"
        case .prohibited: return "prohibited"
        @unknown default: return "unknown"
        }
    }

    private func axAttributeNames(for element: AXUIElement) -> [String] {
        var names: CFArray?
        let result = AXUIElementCopyAttributeNames(element, &names)
        guard result == .success, let names = names as? [String] else {
            return []
        }
        return names
    }

    private func axBool(_ element: AXUIElement, _ attribute: CFString) -> Bool? {
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, attribute, &value)
        guard result == .success, let cfBool = value, CFGetTypeID(cfBool) == CFBooleanGetTypeID() else {
            return nil
        }
        return CFBooleanGetValue((cfBool as! CFBoolean))
    }
}
