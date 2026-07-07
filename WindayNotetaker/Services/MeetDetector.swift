import Foundation
import AppKit
import CoreGraphics
import CoreAudio
import Combine

/// Detects whether a Google Meet call is happening, so the floating recorder
/// popup can appear on its own. Two signals:
///   1. A browser window whose title looks like a Meet tab (also gives us the
///      window id to scope audio capture to that app).
///   2. The default microphone being "in use" by some process (CoreAudio),
///      which fires when Meet grabs the mic.
@MainActor
final class MeetDetector: ObservableObject {
    /// True when a Google Meet window is detected on screen.
    @Published private(set) var isMeetActive = false
    /// True when the default input device is running (mic open somewhere).
    @Published private(set) var micInUse = false
    /// Window id of the detected Meet tab (for app-scoped audio capture).
    @Published private(set) var meetWindowID: CGWindowID?
    /// The browser app hosting Meet, if found.
    @Published private(set) var hostBrowserBundleID: String?

    /// True when we think a meeting is starting — used to show the popup.
    var meetingLikely: Bool { isMeetActive || micInUse }

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

    func startMonitoring(interval: TimeInterval = 3) {
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

    /// One-shot scan of on-screen windows + mic state.
    func refresh() {
        micInUse = Self.isDefaultInputRunning()
        scanForMeetWindow()
    }

    private func scanForMeetWindow() {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let windows = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
            isMeetActive = false; meetWindowID = nil; hostBrowserBundleID = nil
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

            if name.localizedCaseInsensitiveContains("meet") {
                isMeetActive = true
                hostBrowserBundleID = bundleID
                meetWindowID = (window[kCGWindowNumber as String] as? NSNumber)?.uint32Value
                return
            }
        }

        isMeetActive = false
        meetWindowID = nil
        hostBrowserBundleID = nil
    }

    /// True while the tracked browser window `id` still exists. Used during
    /// recording to detect the meeting ending.
    ///
    /// We deliberately check only window *existence*, NOT its title: a browser
    /// window shows a single title (the active tab's), so switching tabs would
    /// change the title even though the Meet call is still running in the
    /// background tab — and the window's audio is still captured. Ending only on
    /// the window actually closing avoids stopping the recording on a tab switch.
    /// Includes off-screen windows so minimizing the browser doesn't count as
    /// ended.
    func isMeetWindow(_ id: CGWindowID) -> Bool {
        guard let windows = CGWindowListCopyWindowInfo(CGWindowListOption(rawValue: 0), kCGNullWindowID)
                as? [[String: Any]] else {
            return true   // can't tell — assume still active, don't end early
        }
        for window in windows {
            if let num = (window[kCGWindowNumber as String] as? NSNumber)?.uint32Value, num == id {
                return true   // browser window still open (tab switches don't close it)
            }
        }
        return false   // window no longer exists → closed
    }

    // MARK: - CoreAudio: is the default input device running somewhere?

    private static func isDefaultInputRunning() -> Bool {
        var deviceID = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var defaultAddr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject),
                                         &defaultAddr, 0, nil, &size, &deviceID) == noErr,
              deviceID != 0 else { return false }

        var running: UInt32 = 0
        var runSize = UInt32(MemoryLayout<UInt32>.size)
        var runAddr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceIsRunningSomewhere,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyData(deviceID, &runAddr, 0, nil, &runSize, &running) == noErr else {
            return false
        }
        return running != 0
    }
}
