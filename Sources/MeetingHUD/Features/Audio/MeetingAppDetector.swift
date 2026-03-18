import AppKit

/// Detects running meeting applications and returns their process identifiers
/// for audio tapping.
struct MeetingAppDetector {
    /// A detected meeting application.
    struct DetectedApp: Identifiable {
        let id = UUID()
        let name: String
        let bundleIdentifier: String
        let pid: pid_t
    }

    /// Known meeting app bundle identifiers.
    private static let knownMeetingApps: [String: String] = [
        "com.microsoft.teams2": "Microsoft Teams",
        "com.microsoft.teams": "Microsoft Teams (Classic)",
        "us.zoom.xos": "Zoom",
        "com.cisco.webexmeetingsapp": "Webex",
        "com.google.Chrome": "Google Chrome",        // May host Google Meet
        "com.brave.Browser": "Brave Browser",         // May host Google Meet
        "com.microsoft.edgemac": "Microsoft Edge",     // May host Teams web
        "company.thebrowser.Browser": "Arc",           // May host any web meeting
    ]

    /// Browsers that could be running web-based meetings (Meet, Teams web, etc.).
    private static let browserBundleIDs: Set<String> = [
        "com.google.Chrome",
        "com.brave.Browser",
        "com.microsoft.edgemac",
        "company.thebrowser.Browser",
        "org.mozilla.firefox",
        "com.apple.Safari",
    ]

    /// Scan running applications for known meeting apps.
    /// Returns all detected meeting-capable apps with their PIDs.
    func detectRunningMeetingApps() -> [DetectedApp] {
        let runningApps = NSWorkspace.shared.runningApplications
        var detected: [DetectedApp] = []

        for app in runningApps {
            guard let bundleID = app.bundleIdentifier,
                  app.activationPolicy == .regular else { continue }

            if let appName = Self.knownMeetingApps[bundleID] {
                let isBrowser = Self.browserBundleIDs.contains(bundleID)
                let name = isBrowser ? "\(appName) (possible web meeting)" : appName
                detected.append(DetectedApp(
                    name: name,
                    bundleIdentifier: bundleID,
                    pid: app.processIdentifier
                ))
            }
        }

        return detected
    }

    /// Check if any native (non-browser) meeting app is running.
    func hasNativeMeetingApp() -> Bool {
        detectRunningMeetingApps().contains { app in
            !Self.browserBundleIDs.contains(app.bundleIdentifier)
        }
    }

    /// Find PIDs for a specific meeting app by bundle identifier.
    func pids(for bundleIdentifier: String) -> [pid_t] {
        NSWorkspace.shared.runningApplications
            .filter { $0.bundleIdentifier == bundleIdentifier }
            .map(\.processIdentifier)
    }
}
