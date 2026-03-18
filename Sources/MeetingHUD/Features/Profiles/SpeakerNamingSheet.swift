import SwiftUI

/// Post-meeting sheet for naming detected speakers.
/// Shows each speaker label with a text field for the user to enter a name.
struct SpeakerNamingSheet: View {
    let speakerLabels: [String]
    let onComplete: ([String: String]) -> Void
    let onSkip: () -> Void

    @State private var names: [String: String] = [:]

    var body: some View {
        VStack(spacing: 16) {
            Text("Name Speakers")
                .font(.headline)

            Text("Who was in this meeting?")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            VStack(spacing: 10) {
                ForEach(speakerLabels, id: \.self) { label in
                    HStack {
                        Text(label)
                            .frame(width: 90, alignment: .trailing)
                            .foregroundStyle(.secondary)
                            .font(.callout)

                        TextField("Name", text: binding(for: label))
                            .textFieldStyle(.roundedBorder)
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
        .frame(width: 360)
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
