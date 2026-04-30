import AppKit
import ApplicationServices
import Foundation

final class DebugWindowDumper {
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

    func dumpWindowList() {
        let entries = windowEnumerator.allWindowEntries(options: [.optionOnScreenOnly])
        dumpWindowList(entries: entries, header: "Dump Window List")
    }

    func dumpWindowList(entries: [CGWindowListEntry], header: String) {
        Logger.info("===== \(header): \(entries.count) CGWindowList entr\(entries.count == 1 ? "y" : "ies") =====")
        entries.forEach { entry in
            Logger.info("CGWindow: \(entry.fullDebugSummary)")
        }
        Logger.info("===== End \(header) =====")
    }

    func dumpAXWindows() {
        guard permissionManager.isAccessibilityTrusted else {
            Logger.error("Cannot dump AX windows because Accessibility permission is missing")
            return
        }

        let entries = windowEnumerator.allWindowEntries(options: [.optionOnScreenOnly, .excludeDesktopElements])
        let visibleAppEntries = entries.filter { entry in
            guard let pid = entry.ownerPID,
                  pid != pid_t(ProcessInfo.processInfo.processIdentifier),
                  entry.layer == 0,
                  let bounds = entry.bounds,
                  bounds.width >= 40,
                  bounds.height >= 40 else {
                return false
            }

            return !WindowEnumerator.ignoredSystemOwnerNames.contains(entry.ownerName)
        }

        let groupedEntries = Dictionary(grouping: visibleAppEntries) { entry in
            entry.ownerPID ?? 0
        }

        Logger.info("===== Dump AX Windows: \(groupedEntries.count) visible app PID(s) =====")

        for pid in groupedEntries.keys.sorted() where pid != 0 {
            let ownerName = groupedEntries[pid]?.first?.ownerName ?? ""
            let runningAppName = NSRunningApplication(processIdentifier: pid)?.localizedName
            let appName = runningAppName ?? ownerName

            Logger.info("AX app: name=\"\(appName)\", owner=\"\(ownerName)\", pid=\(pid)")
            let axWindows = axWindowController.windows(forPID: pid)

            if axWindows.isEmpty {
                Logger.info("AX app pid=\(pid) has no readable AX windows")
                continue
            }

            for (index, window) in axWindows.enumerated() {
                let closeDiagnostics = axWindowController.closeButtonDiagnostics(for: window)
                Logger.info("AX window \(index): app=\"\(appName)\", pid=\(pid), \(window.debugSummary), closeButtonExists=\(closeDiagnostics.exists), closeButtonSupportsAXPress=\(closeDiagnostics.supportsPress), closeButtonActions=\(closeDiagnostics.actions)")
            }
        }

        Logger.info("===== End Dump AX Windows =====")
    }
}
