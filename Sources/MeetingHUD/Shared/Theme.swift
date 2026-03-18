import SwiftUI

/// Design tokens for the MeetingHUD interface.
enum Theme {
    // MARK: - Colors

    enum Colors {
        static let hudBackground = Color(.windowBackgroundColor).opacity(0.85)
        static let accent = Color.blue
        static let recordingActive = Color.red
        static let positive = Color.green
        static let negative = Color.orange
        static let neutral = Color.gray

        /// Rotating palette for speaker identification in the overlay.
        static let speakerPalette: [Color] = [
            .blue, .purple, .orange, .teal, .pink, .indigo, .mint, .cyan
        ]

        /// Deterministic color for a speaker label.
        static func speakerColor(for label: String) -> Color {
            let hash = abs(label.hashValue)
            return speakerPalette[hash % speakerPalette.count]
        }

        /// Sentiment-based color interpolation.
        static func sentimentColor(_ score: Double) -> Color {
            switch score {
            case 0.3...: positive
            case ..<(-0.3): negative
            default: neutral
            }
        }
    }

    // MARK: - Typography

    enum Typography {
        static let columnHeader = Font.system(.caption, design: .rounded, weight: .semibold)
        static let speakerName = Font.system(.callout, design: .default, weight: .medium)
        static let speakerLabel = Font.system(.caption, design: .monospaced, weight: .semibold)
        static let transcript = Font.system(.callout, design: .default)
        static let body = Font.system(.caption, design: .default)
        static let caption = Font.system(.caption2, design: .default)
        static let timestamp = Font.system(.caption2, design: .monospaced)
    }

    // MARK: - Layout

    enum Layout {
        static let hudCornerRadius: CGFloat = 16
        static let cardCornerRadius: CGFloat = 8
        static let overlayPadding: CGFloat = 10
        static let columnSpacing: CGFloat = 0
        static let itemSpacing: CGFloat = 6
    }

    // MARK: - Materials

    enum Materials {
        /// Primary HUD background material.
        static let hudBackground: some ShapeStyle = .ultraThinMaterial
        /// Card background within the HUD.
        static let cardBackground: some ShapeStyle = .thinMaterial
    }
}
