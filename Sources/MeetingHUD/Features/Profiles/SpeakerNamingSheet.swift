import SwiftUI
import SwiftData

/// Post-meeting sheet for naming detected speakers.
/// Shows each speaker label with sample quotes so the user can identify who is who.
struct SpeakerNamingSheet: View {
    let speakerLabels: [String]
    let segments: [TranscriptSegment]
    let onComplete: ([String: String]) -> Void
    let onSkip: () -> Void

    @Query(sort: \Interlocutor.lastSeen, order: .reverse) private var interlocutors: [Interlocutor]
    @State private var names: [String: String] = [:]

    /// Get 2-3 sample quotes for a speaker to help identify them.
    private func sampleQuotes(for label: String) -> [String] {
        let speakerSegs = segments.filter { $0.speakerLabel == label }
        // Pick the longest segments (most distinctive)
        let sorted = speakerSegs.sorted { $0.text.count > $1.text.count }
        return sorted.prefix(3).map { seg in
            let text = seg.text.prefix(80)
            return "\"\(text)\(seg.text.count > 80 ? "..." : "")\""
        }
    }

    /// Known names for autocomplete suggestions.
    private var knownNames: [String] {
        interlocutors.map(\.name)
    }

    var body: some View {
        VStack(spacing: 16) {
            Text("Name Speakers")
                .font(.headline)

            Text("Match each speaker to their voice using the sample quotes below")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            ScrollView {
                VStack(spacing: 14) {
                    ForEach(speakerLabels, id: \.self) { label in
                        VStack(alignment: .leading, spacing: 6) {
                            HStack(alignment: .top) {
                                // Speaker label + color dot
                                HStack(spacing: 6) {
                                    Circle()
                                        .fill(Theme.Colors.speakerColor(for: label))
                                        .frame(width: 8, height: 8)
                                    Text(label)
                                        .font(.callout.weight(.medium))
                                        .foregroundStyle(.secondary)
                                }
                                .frame(width: 100, alignment: .trailing)

                                // Name input
                                TextField("Name", text: binding(for: label))
                                    .textFieldStyle(.roundedBorder)
                            }

                            // Sample quotes — so the user can tell who this speaker is
                            let quotes = sampleQuotes(for: label)
                            if !quotes.isEmpty {
                                VStack(alignment: .leading, spacing: 2) {
                                    ForEach(Array(quotes.enumerated()), id: \.offset) { _, quote in
                                        Text(quote)
                                            .font(.system(size: 11))
                                            .foregroundStyle(.tertiary)
                                            .lineLimit(2)
                                            .italic()
                                    }
                                }
                                .padding(.leading, 106)
                            }

                            // Segment count
                            let count = segments.filter { $0.speakerLabel == label }.count
                            Text("\(count) segments")
                                .font(.system(size: 10))
                                .foregroundStyle(.quaternary)
                                .padding(.leading, 106)
                        }
                    }
                }
            }
            .frame(maxHeight: 400)

            // Known name suggestions
            if !knownNames.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Known profiles:")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                    FlowLayout(spacing: 4) {
                        ForEach(knownNames, id: \.self) { name in
                            Button {
                                // Fill in the first empty field
                                if let emptyLabel = speakerLabels.first(where: { names[$0]?.isEmpty ?? true }) {
                                    names[emptyLabel] = name
                                }
                            } label: {
                                Text(name)
                                    .font(.system(size: 11))
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 3)
                                    .background(.secondary.opacity(0.1), in: Capsule())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }

            HStack(spacing: 12) {
                Button("Skip") {
                    onSkip()
                }
                .keyboardShortcut(.cancelAction)

                Button("Save") {
                    onComplete(names)
                }
                .keyboardShortcut(.defaultAction)
                .disabled(names.values.allSatisfy { $0.isEmpty })
            }
            .padding(.top, 4)
        }
        .padding(24)
        .frame(width: 440)
        .onAppear {
            for label in speakerLabels {
                names[label] = ""
            }
        }
    }

    private func binding(for label: String) -> Binding<String> {
        Binding(
            get: { names[label] ?? "" },
            set: { names[label] = $0 }
        )
    }
}

/// Simple flow layout for tag-like elements.
private struct FlowLayout: Layout {
    var spacing: CGFloat = 4

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let result = arrange(proposal: proposal, subviews: subviews)
        return result.size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let result = arrange(proposal: proposal, subviews: subviews)
        for (index, position) in result.positions.enumerated() {
            subviews[index].place(at: CGPoint(x: bounds.minX + position.x, y: bounds.minY + position.y), proposal: .unspecified)
        }
    }

    private func arrange(proposal: ProposedViewSize, subviews: Subviews) -> (size: CGSize, positions: [CGPoint]) {
        let maxWidth = proposal.width ?? .infinity
        var positions: [CGPoint] = []
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        var maxX: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > maxWidth && x > 0 {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            positions.append(CGPoint(x: x, y: y))
            rowHeight = max(rowHeight, size.height)
            x += size.width + spacing
            maxX = max(maxX, x)
        }

        return (CGSize(width: maxX, height: y + rowHeight), positions)
    }
}
