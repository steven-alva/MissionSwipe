import AppKit
import ApplicationServices

final class AccessibilityPermissionManager {
    var isAccessibilityTrusted: Bool {
        AXIsProcessTrusted()
    }

    func logPermissionDiagnostics(reason: String) {
        let bundle = Bundle.main
        Logger.warning("Accessibility permission diagnostics: \(reason)")
        Logger.warning("Trusted=\(isAccessibilityTrusted)")
        Logger.warning("Process pid=\(ProcessInfo.processInfo.processIdentifier)")
        Logger.warning("Bundle identifier=\(bundle.bundleIdentifier ?? "nil")")
        Logger.warning("Bundle path=\(bundle.bundleURL.path)")
        Logger.warning("Executable path=\(bundle.executableURL?.path ?? "nil")")
    }

    func requestSystemAccessibilityPrompt() {
        let promptKey = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        let options = [promptKey: true] as CFDictionary
        let trusted = AXIsProcessTrustedWithOptions(options)
        Logger.info("Requested system Accessibility prompt. Trusted after request: \(trusted)")
    }

    func showMissingPermissionAlert() {
        Logger.warning("Accessibility permission is missing; showing guidance alert")
        NSApp.activate(ignoringOtherApps: true)

        let alert = NSAlert()
        alert.messageText = "MissionSwipe needs Accessibility permission"
        alert.informativeText = "Grant Accessibility access so MissionSwipe can identify and close the specific window under your mouse cursor. After granting permission, run the hotkey again."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Open Accessibility Settings")
        alert.addButton(withTitle: "Later")

        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            Self.openAccessibilitySettings()
        }
    }

    static func openAccessibilitySettings() {
        Logger.info("Opening System Settings > Privacy & Security > Accessibility")

        let candidateURLs = [
            "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility",
            "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_Accessibility"
        ]

        for rawURL in candidateURLs {
            guard let url = URL(string: rawURL) else {
                continue
            }

            if NSWorkspace.shared.open(url) {
                Logger.info("Opened Accessibility settings with URL: \(rawURL)")
                return
            }
        }

        Logger.error("Unable to open Accessibility settings URL")
    }
}
