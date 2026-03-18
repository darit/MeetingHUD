import AppKit
import EventKit

/// Monitors for active meetings and triggers recording automatically.
/// Uses three detection strategies:
/// 1. Window monitoring — detects call windows in Teams/Zoom/Meet
/// 2. Audio activity — detects when meeting apps start producing audio
/// 3. Calendar awareness — checks EventKit for meetings happening now
@Observable @MainActor
final class MeetingAutoDetector {

    // MARK: - State

    var isMonitoring = false
    var detectedMeeting: DetectedMeeting?
    var onMeetingStarted: ((DetectedMeeting) -> Void)?
    var onMeetingEnded: (() -> Void)?

    // MARK: - Private

    private var pollingTask: Task<Void, Never>?
    private let meetingAppDetector = MeetingAppDetector()
    private let eventStore = EKEventStore()
    private var calendarAccessGranted = false
    private var lastKnownState: MeetingState = .idle

    private enum MeetingState: Equatable {
        case idle
        case inMeeting(app: String, pid: pid_t)
    }

    /// Known window title patterns that indicate an active call (not just the app open).
    private static let callWindowPatterns: [String: [String]] = [
        "com.microsoft.teams2": [
            "Meeting with", "Call with", " | Meeting",
            " | Call", "meeting-v2"
        ],
        "com.microsoft.teams": [
            "Meeting with", "Call with", " | Meeting"
        ],
        "us.zoom.xos": [
            "Zoom Meeting", "zoom meeting"
        ],
        "com.cisco.webexmeetingsapp": [
            "Meeting", "Webex"
        ],
    ]

    /// Browser URL fragments that indicate a web meeting.
    private static let meetingURLPatterns: [String] = [
        "meet.google.com",
        "teams.microsoft.com/l/meetup",
        "teams.live.com",
        "zoom.us/j/",
        "zoom.us/wc/",
    ]

    // MARK: - Public API

    /// Start monitoring for meetings. Polls every 3 seconds.
    func startMonitoring() {
        guard !isMonitoring else { return }
        isMonitoring = true

        Task { await requestCalendarAccess() }

        pollingTask = Task { [weak self] in
            while !Task.isCancelled {
                self?.checkForActiveMeeting()
                try? await Task.sleep(for: .seconds(3))
            }
        }
    }

    /// Stop monitoring.
    func stopMonitoring() {
        isMonitoring = false
        pollingTask?.cancel()
        pollingTask = nil
    }

    // MARK: - Detection Logic

    private func checkForActiveMeeting() {
        // Strategy 1: Check native meeting app windows
        if let meeting = detectNativeAppCall() {
            transitionTo(.inMeeting(app: meeting.appName, pid: meeting.pid), meeting: meeting)
            return
        }

        // Strategy 2: Check browser windows for meeting URLs
        if let meeting = detectBrowserMeeting() {
            transitionTo(.inMeeting(app: meeting.appName, pid: meeting.pid), meeting: meeting)
            return
        }

        // Strategy 3: Check calendar for meeting happening now
        // (only used to enrich detection, not as sole trigger —
        //  we don't want to record when user has a calendar event but isn't in a call)

        // No meeting detected
        transitionTo(.idle, meeting: nil)
    }

    private func transitionTo(_ newState: MeetingState, meeting: DetectedMeeting?) {
        guard newState != lastKnownState else { return }
        let previousState = lastKnownState
        lastKnownState = newState

        switch (previousState, newState) {
        case (.idle, .inMeeting):
            // Enrich with calendar data if available
            var enrichedMeeting = meeting!
            if let calendarEvent = findCurrentCalendarEvent() {
                enrichedMeeting.title = calendarEvent.title
                enrichedMeeting.scheduledParticipants = calendarEvent.attendees?
                    .compactMap { $0.name } ?? []
            }
            detectedMeeting = enrichedMeeting
            onMeetingStarted?(enrichedMeeting)

        case (.inMeeting, .idle):
            detectedMeeting = nil
            onMeetingEnded?()

        default:
            break
        }
    }

    // MARK: - Native App Detection

    /// Check if a native meeting app has an active call window.
    private func detectNativeAppCall() -> DetectedMeeting? {
        let runningApps = NSWorkspace.shared.runningApplications

        for app in runningApps {
            guard let bundleID = app.bundleIdentifier,
                  let patterns = Self.callWindowPatterns[bundleID],
                  app.isActive || app.activationPolicy == .regular else { continue }

            // Use Accessibility API to check window titles
            let appElement = AXUIElementCreateApplication(app.processIdentifier)
            var windowsRef: CFTypeRef?
            let result = AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &windowsRef)

            guard result == .success,
                  let windows = windowsRef as? [AXUIElement] else { continue }

            for window in windows {
                var titleRef: CFTypeRef?
                AXUIElementCopyAttributeValue(window, kAXTitleAttribute as CFString, &titleRef)

                if let title = titleRef as? String {
                    let isCallWindow = patterns.contains { pattern in
                        title.localizedCaseInsensitiveContains(pattern)
                    }

                    if isCallWindow {
                        return DetectedMeeting(
                            appName: app.localizedName ?? bundleID,
                            bundleIdentifier: bundleID,
                            pid: app.processIdentifier,
                            title: title,
                            detectionMethod: .windowTitle
                        )
                    }
                }
            }
        }

        return nil
    }

    // MARK: - Browser Meeting Detection

    /// Check browser windows for meeting URLs (Google Meet, Teams web, Zoom web).
    private func detectBrowserMeeting() -> DetectedMeeting? {
        let runningApps = NSWorkspace.shared.runningApplications
        let browserBundleIDs: Set<String> = [
            "com.google.Chrome", "com.brave.Browser",
            "company.thebrowser.Browser", "com.microsoft.edgemac",
            "org.mozilla.firefox", "com.apple.Safari"
        ]

        for app in runningApps {
            guard let bundleID = app.bundleIdentifier,
                  browserBundleIDs.contains(bundleID) else { continue }

            // Check browser tab titles via Accessibility API
            let appElement = AXUIElementCreateApplication(app.processIdentifier)
            var windowsRef: CFTypeRef?
            let result = AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &windowsRef)

            guard result == .success,
                  let windows = windowsRef as? [AXUIElement] else { continue }

            for window in windows {
                var titleRef: CFTypeRef?
                AXUIElementCopyAttributeValue(window, kAXTitleAttribute as CFString, &titleRef)

                if let title = titleRef as? String {
                    // Check for Google Meet pattern: "Meet - xxx-xxxx-xxx"
                    // or "Meeting title - Google Meet"
                    // Arc shows clean titles like "Meet - abc-defg-hij"
                    let hasMeetCode = (try? title.wholeMatch(of: Regex(#"^Meet\s*[-–—]\s*[a-z]{3,4}-[a-z]{4}-[a-z]{3,4}$"#))) != nil
                    let isMeetingTab = title.contains("Google Meet") ||
                        title.contains("Microsoft Teams") ||
                        hasMeetCode ||
                        Self.meetingURLPatterns.contains { title.contains($0) }

                    // Also check for active meeting indicators
                    // Chrome/Arc show a red dot or "sharing" in title during calls
                    let hasCallIndicator = title.contains("🔴") ||
                        title.localizedCaseInsensitiveContains("sharing")

                    if isMeetingTab || hasCallIndicator {
                        let meetingApp = (title.contains("Google Meet") || hasMeetCode) ? "Google Meet" :
                            title.contains("Microsoft Teams") ? "Teams (Web)" : "Web Meeting"

                        return DetectedMeeting(
                            appName: meetingApp,
                            bundleIdentifier: bundleID,
                            pid: app.processIdentifier,
                            title: cleanBrowserTitle(title),
                            detectionMethod: .browserTab
                        )
                    }
                }
            }
        }

        return nil
    }

    private func cleanBrowserTitle(_ title: String) -> String {
        // Remove common browser suffixes
        title
            .replacingOccurrences(of: " - Google Chrome", with: "")
            .replacingOccurrences(of: " - Brave", with: "")
            .replacingOccurrences(of: " - Arc", with: "")
            .replacingOccurrences(of: " — Mozilla Firefox", with: "")
            .trimmingCharacters(in: .whitespaces)
    }

    // MARK: - Calendar Integration

    private func requestCalendarAccess() async {
        do {
            calendarAccessGranted = try await eventStore.requestFullAccessToEvents()
        } catch {
            calendarAccessGranted = false
        }
    }

    private func findCurrentCalendarEvent() -> EKEvent? {
        guard calendarAccessGranted else { return nil }

        let now = Date()
        let predicate = eventStore.predicateForEvents(
            withStart: now.addingTimeInterval(-300), // started up to 5min ago
            end: now.addingTimeInterval(300),         // or starts within 5min
            calendars: nil
        )

        let events = eventStore.events(matching: predicate)

        // Find the most likely current meeting
        // Prefer events that have already started and have attendees
        return events
            .filter { $0.hasAttendees && !$0.isAllDay }
            .sorted { e1, e2 in
                // Prefer already-started events
                let e1Started = e1.startDate <= now
                let e2Started = e2.startDate <= now
                if e1Started != e2Started { return e1Started }
                // Then prefer more attendees (more likely a real meeting)
                return (e1.attendees?.count ?? 0) > (e2.attendees?.count ?? 0)
            }
            .first
    }
}

// MARK: - Types

struct DetectedMeeting {
    let appName: String
    let bundleIdentifier: String
    let pid: pid_t
    var title: String
    let detectionMethod: DetectionMethod
    var scheduledParticipants: [String] = []

    enum DetectionMethod {
        case windowTitle      // Native app call window detected
        case browserTab       // Browser tab with meeting URL
        case audioActivity    // App started producing audio (future)
    }
}
