import SwiftUI

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @AppStorage("defaultSpeed") private var defaultSpeed: Double = 1.0
    @AppStorage("normalizerEnabled") private var normalizerEnabled: Bool = true
    @AppStorage("breezeInstruct") private var breezeInstruct: String =
        "A calm, warm male narrator with a clear, steady pace, like an audiobook reader."

    var body: some View {
        NavigationStack {
            Form {
                Section("Playback") {
                    HStack {
                        Text("Default speed")
                        Spacer()
                        Text(speedLabel)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                    Slider(value: $defaultSpeed, in: 0.5...2.0, step: 0.25)
                        .tint(Color.accentColor)
                }

                Section {
                    Toggle("Text normalizer (S1-mini)", isOn: $normalizerEnabled)
                } footer: {
                    Text("Cleans up punctuation and formatting before generating speech. Disable if it changes the wording of your documents.")
                        .font(.caption)
                }

                Section("Voice (Breeze — Mac only)") {
                    VStack(alignment: .leading, spacing: DS.Space.s) {
                        Text("Voice description")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        TextEditor(text: $breezeInstruct)
                            .font(.body)
                            .frame(minHeight: 72)
                    }
                }

                Section("About") {
                    LabeledContent("Version", value: "1.0")
                    LabeledContent("Engine", value: "Breeze-TTS-2 (Mac) · Apple TTS (iPhone)")
                }
            }
            .navigationTitle("Settings")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            #endif
            #if os(macOS)
            .formStyle(.grouped)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
            #endif
        }
        #if os(iOS)
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        #else
        .frame(minWidth: 400, minHeight: 480)
        #endif
    }

    private var speedLabel: String {
        defaultSpeed == 1.0 ? "1× (normal)" : String(format: "%.2g×", defaultSpeed)
    }
}

#Preview { SettingsView() }
