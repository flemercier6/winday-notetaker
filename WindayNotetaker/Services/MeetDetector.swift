import Foundation
import AppKit
import CoreGraphics
import CoreAudio
import Combine

/// Detects whether a Google Meet call is happening, so the floating recorder
/// popup can appear on its own — and, while recording, whether the meeting tab
/// is still open so the recording can stop when the call's tab is closed.
///
/// Primary signal: the browser's TABS, enumerated via AppleScript (Automation
/// permission). A tab whose URL carries a meeting code (meet.google.com/xxx-
/// yyyy-zzz) means a real call page — the Meet landing page never matches, and
/// a backgrounded tab still counts, so switching tabs neither hides the popup
/// nor stops the recording; only closing the meeting tab does.
///
/// Fallbacks (AppleScript denied/unsupported, e.g. Firefox):
///   • window titles, but only "in-call"-looking ones (a meeting code, or a
///     title starting with "Meet") — the landing page ("Google Meet") is ignored;
///   • while recording, window existence (never ends on a tab switch).
/// Plus: the default microphone being in use (CoreAudio) still surfaces the
/// popup for browsers/apps we can't inspect.
@MainActor
final class MeetDetector: ObservableObject {
    /// True when a Google Meet call page is detected.
    @Published private(set) var isMeetActive = false
    /// True when the default input device is running (mic open somewhere).
    @Published private(set) var micInUse = false
    /// Window id of a window of the hosting browser (for app-scoped capture).
    @Published private(set) var meetWindowID: CGWindowID?
    /// The browser app hosting Meet, if found.
    @Published private(set) var hostBrowserBundleID: String?
    /// The detected meeting code (e.g. "abc-defg-hij"), when tabs are readable.
    @Published private(set) var meetCode: String?

    /// True when we think a meeting is starting — used to show the popup.
    var meetingLikely: Bool { isMeetActive || micInUse }

    private var timer: Timer?

    /// Browsers we watch. Value = supports AppleScript tab enumeration.
    private let browsers: [String: Bool] = [
        "com.google.Chrome": true,
        "com.google.Chrome.beta": true,
        "com.brave.Browser": true,
        "com.microsoft.edgemac": true,
        "company.thebrowser.Browser": true,  // Arc
        "com.apple.Safari": true,
        "org.mozilla.firefox": false,        // no scriptable tabs → fallbacks
    ]

    /// Bundles whose Automation permission was denied — don't keep re-asking.
    private var scriptDenied: Set<String> = []
    /// Last tab scan: bundle → meeting codes found (only bundles scanned OK).
    private var lastTabCodes: [String: Set<String>] = [:]

    /// Meeting-code patterns. URLs: meet.google.com/abc-defg-hij (or /lookup/…).
    private static let urlCodeRegex = try! NSRegularExpression(
        pattern: #"meet\.google\.com/((?:[a-z]{3}-[a-z]{4}-[a-z]{3})|(?:lookup/[A-Za-z0-9-]+))"#)
    private static let titleCodeRegex = try! NSRegularExpression(
        pattern: #"\b[a-z]{3}-[a-z]{4}-[a-z]{3}\b"#)

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

    /// One-shot scan of browser tabs (+ fallbacks) and mic state.
    func refresh() {
        micInUse = Self.isDefaultInputRunning()
        scanTabs()

        // 1) Tab-based detection (authoritative where available).
        for (bundle, codes) in lastTabCodes where !codes.isEmpty {
            meetCode = codes.first
            hostBrowserBundleID = bundle
            meetWindowID = anyWindowID(forBundle: bundle)
            isMeetActive = true
            return
        }

        // 2) Title fallback, only for running browsers we could NOT scan.
        if let hit = titleScanFallback() {
            meetCode = nil
            hostBrowserBundleID = hit.bundleID
            meetWindowID = hit.windowID
            isMeetActive = true
            return
        }

        isMeetActive = false
        meetCode = nil
        meetWindowID = nil
        hostBrowserBundleID = nil
    }

    // MARK: - While recording: is the meeting still open?

    /// True while the recorded meeting should keep going. Tab-accurate when the
    /// host browser is scriptable (ends when the meeting tab is closed, even in
    /// the background); otherwise falls back to the window still existing.
    func isMeetStillOpen(code: String?, bundleID: String?, fallbackWindowID: CGWindowID?) -> Bool {
        if let code, let bundleID, let codes = lastTabCodes[bundleID] {
            return codes.contains(code)
        }
        if let code {
            // Host unknown — accept the code appearing in any scanned browser.
            for (_, codes) in lastTabCodes where codes.contains(code) { return true }
            if !lastTabCodes.isEmpty { return false }
        }
        if let id = fallbackWindowID { return windowExists(id) }
        return true   // can't tell — don't end early
    }

    // MARK: - Tab scan (AppleScript)

    private func scanTabs() {
        var result: [String: Set<String>] = [:]
        let running = Set(NSWorkspace.shared.runningApplications.compactMap { $0.bundleIdentifier })

        for (bundle, scriptable) in browsers {
            guard scriptable, running.contains(bundle), !scriptDenied.contains(bundle) else { continue }
            guard let urls = tabURLs(bundleID: bundle) else { continue }
            var codes: Set<String> = []
            for url in urls {
                if let code = Self.meetingCode(inURL: url) { codes.insert(code) }
            }
            result[bundle] = codes
        }
        lastTabCodes = result
    }

    /// Enumerates the URLs of every tab of every window of the given browser.
    /// Returns nil when the browser can't be scripted (permission denied, error).
    private func tabURLs(bundleID: String) -> [String]? {
        let source = """
        tell application id "\(bundleID)"
            set _out to ""
            repeat with w in windows
                repeat with t in tabs of w
                    try
                        set _out to _out & (URL of t) & linefeed
                    end try
                end repeat
            end repeat
            return _out
        end tell
        """
        var error: NSDictionary?
        guard let script = NSAppleScript(source: source) else { return nil }
        let output = script.executeAndReturnError(&error)
        if let error {
            // -1743 = user denied Automation permission: stop asking this session.
            if (error[NSAppleScript.errorNumber] as? Int) == -1743 {
                scriptDenied.insert(bundleID)
            }
            return nil
        }
        guard let text = output.stringValue else { return [] }
        return text.split(separator: "\n").map(String.init)
    }

    private static func meetingCode(inURL url: String) -> String? {
        let range = NSRange(url.startIndex..., in: url)
        guard let m = urlCodeRegex.firstMatch(in: url, range: range),
              let r = Range(m.range(at: 1), in: url) else { return nil }
        return String(url[r])
    }

    // MARK: - Window fallbacks (CGWindowList)

    /// Title-based detection for browsers whose tabs we can't read. Only counts
    /// "in-call" titles: a meeting code, or a title starting with "Meet" (the
    /// call tab is "Meet – xxx-yyyy-zzz"); the landing page ("Google Meet") and
    /// unrelated titles containing "meeting…" never match.
    private func titleScanFallback() -> (bundleID: String, windowID: CGWindowID)? {
        let scanned = Set(lastTabCodes.keys)
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let windows = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
            return nil
        }
        let runningByPID = Dictionary(
            uniqueKeysWithValues: NSWorkspace.shared.runningApplications.map { ($0.processIdentifier, $0) }
        )
        for window in windows {
            guard let name = window[kCGWindowName as String] as? String,
                  let pid = window[kCGWindowOwnerPID as String] as? pid_t,
                  let app = runningByPID[pid],
                  let bundleID = app.bundleIdentifier,
                  browsers.keys.contains(bundleID),
                  !scanned.contains(bundleID)   // tab scan already covered these
            else { continue }

            if Self.isInCallTitle(name),
               let num = (window[kCGWindowNumber as String] as? NSNumber)?.uint32Value {
                return (bundleID, num)
            }
        }
        return nil
    }

    private static func isInCallTitle(_ title: String) -> Bool {
        let range = NSRange(title.startIndex..., in: title)
        if titleCodeRegex.firstMatch(in: title, range: range) != nil { return true }
        // In-call tab title starts with "Meet" ("Meet – …"); the landing page is
        // "Google Meet" and never matches.
        return title.hasPrefix("Meet ") || title.hasPrefix("Meet –") || title.hasPrefix("Meet -")
    }

    /// Any current window id belonging to the given browser (for capture scoping).
    private func anyWindowID(forBundle bundleID: String) -> CGWindowID? {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let windows = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
            return nil
        }
        let pids = Set(NSWorkspace.shared.runningApplications
            .filter { $0.bundleIdentifier == bundleID }
            .map { $0.processIdentifier })
        for window in windows {
            guard let pid = window[kCGWindowOwnerPID as String] as? pid_t, pids.contains(pid),
                  let layer = window[kCGWindowLayer as String] as? Int, layer == 0,
                  let num = (window[kCGWindowNumber as String] as? NSNumber)?.uint32Value
            else { continue }
            return num
        }
        return nil
    }

    private func windowExists(_ id: CGWindowID) -> Bool {
        guard let windows = CGWindowListCopyWindowInfo(CGWindowListOption(rawValue: 0), kCGNullWindowID)
                as? [[String: Any]] else {
            return true   // can't tell — assume still open
        }
        for window in windows {
            if let num = (window[kCGWindowNumber as String] as? NSNumber)?.uint32Value, num == id {
                return true
            }
        }
        return false
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
