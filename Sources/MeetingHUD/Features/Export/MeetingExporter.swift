import AppKit
import Foundation

/// Exports meeting data as markdown or plain text.
enum MeetingExporter {

    /// Generate a markdown summary of the current meeting.
    static func exportMarkdown(
        title: String,
        date: Date,
        segments: [TranscriptSegment],
        speakers: [SpeakerInfo],
        topics: [TopicInfo],
        actionItems: [SignalDetector.DetectedAction],
        summary: String?
    ) -> String {
        var lines: [String] = []

        // Header
        lines.append("# \(title)")
        lines.append("")
        lines.append("**Date:** \(formatDate(date))")
        lines.append("")

        // Summary
        if let summary, !summary.isEmpty {
            lines.append("## Summary")
            lines.append("")
            lines.append(summary)
            lines.append("")
        }

        // Speakers
        if !speakers.isEmpty {
            lines.append("## Participants")
            lines.append("")
            let totalTime = speakers.reduce(0) { $0 + $1.talkTime }
            for speaker in speakers.sorted(by: { $0.talkTime > $1.talkTime }) {
                let pct = totalTime > 0 ? Int((speaker.talkTime / totalTime) * 100) : 0
                let mins = Int(speaker.talkTime) / 60
                let secs = Int(speaker.talkTime) % 60
                lines.append("- **\(speaker.name)** — \(mins)m \(secs)s (\(pct)%)")
            }
            lines.append("")
        }

        // Topics
        if !topics.isEmpty {
            lines.append("## Topics")
            lines.append("")
            for topic in topics {
                lines.append("### \(topic.name)")
                lines.append("")
                lines.append(topic.summary)
                lines.append("")
            }
        }

        // Action Items
        if !actionItems.isEmpty {
            lines.append("## Action Items")
            lines.append("")
            for action in actionItems {
                let owner = action.ownerLabel.isEmpty ? "" : " (@\(action.ownerLabel))"
                lines.append("- [ ] \(action.description)\(owner)")
            }
            lines.append("")
        }

        // Transcript
        if !segments.isEmpty {
            lines.append("## Transcript")
            lines.append("")
            for segment in segments {
                let time = formatTime(segment.startTime)
                lines.append("**[\(time)] \(segment.speakerLabel):** \(segment.text)")
                lines.append("")
            }
        }

        lines.append("---")
        lines.append("*Exported from MeetingHUD*")

        return lines.joined(separator: "\n")
    }

    /// Present a save panel and write the markdown to disk.
    @MainActor
    static func saveToFile(
        markdown: String,
        suggestedName: String
    ) async -> Bool {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.plainText]
        panel.nameFieldStringValue = "\(suggestedName).md"
        panel.canCreateDirectories = true

        let response = await panel.begin()
        guard response == .OK, let url = panel.url else { return false }

        do {
            try markdown.write(to: url, atomically: true, encoding: .utf8)
            return true
        } catch {
            print("[MeetingExporter] Failed to save: \(error)")
            return false
        }
    }

    /// Copy markdown to clipboard.
    static func copyToClipboard(_ markdown: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(markdown, forType: .string)
    }

    // MARK: - Formatting

    private static func formatDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .long
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }

    private static func formatTime(_ interval: TimeInterval) -> String {
        let minutes = Int(interval) / 60
        let seconds = Int(interval) % 60
        return String(format: "%d:%02d", minutes, seconds)
    }
}
