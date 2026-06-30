import Foundation
import AppKit
import CoreGraphics
import Combine

/// Detects whether a Google Meet call is currently open in a browser window.
///
/// It scans on-screen window titles (via the CoreGraphics window list) for a
/// Meet tab owned by a known browser. This powers the "a Meet call is in
/// progress" hint and optional auto-start. It is a heuristic — Meet is web-only,
/// so there is no app to detect directly.
@MainActor
final class MeetDetector: ObservableObject {
    /// True when a Google Meet window is detected on screen.
    @Published private(set) var isMeetActive = false
    /// The browser app hosting Meet, if found (useful for app-scoped capture).
    @Published private(set) var hostBrowserBundleID: String?

    private var timer: Timer?

    private let browserBundleIDs: Set<String> = [
        "com.google.Chrome",
        "com.google.Chrome.beta",
        "com.brave.Browser",
        "com.microsoft.edgemac",
        "com.apple.Safari",
        "org.mozilla.firefox",
        "company.thebrowser.Browser", // Arc
    ]

    func startMonitoring(interval: TimeInterval = 4) {
        stopMonitoring()
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    func stopMonitoring() {
        timer?.invalidate()
        timer = nil
    }

    /// One-shot scan of on-screen windows for a Meet tab.
    func refresh() {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let windows = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
            isMeetActive = false
            hostBrowserBundleID = nil
            return
        }

        let runningByPID = Dictionary(
            uniqueKeysWithValues: NSWorkspace.shared.runningApplications.map { ($0.processIdentifier, $0) }
        )

        for window in windows {
            guard let name = window[kCGWindowName as String] as? String,
                  let pid = window[kCGWindowOwnerPID as String] as? pid_t,
                  let app = runningByPID[pid],
                  let bundleID = app.bundleIdentifier,
                  browserBundleIDs.contains(bundleID)
            else { continue }

            // Meet tab titles look like "Meet - abc-defg-hij" or include "Google Meet".
            if name.localizedCaseInsensitiveContains("meet") {
                isMeetActive = true
                hostBrowserBundleID = bundleID
                return
            }
        }

        isMeetActive = false
        hostBrowserBundleID = nil
    }
}
