import SwiftUI

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @AppStorage("defaultSpeed") private var defaultSpeed: Double = 1.0
    @AppStorage("normalizerEnabled") private var normalizerEnabled: Bool = true
    @AppStorage("normalizerStyling") private var normalizerStyling: String = "formal"
    #if os(macOS)
    @AppStorage(EngineController.pythonPathKey) private var pythonPath: String = EngineController.defaultPythonPath
    #endif

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
                    Toggle("Clean up with S1-mini", isOn: $normalizerEnabled)
                    if normalizerEnabled {
                        Picker("Style", selection: $normalizerStyling) {
                            Text("Formal").tag("formal")
                            Text("Semi-formal").tag("semi-formal")
                        }
                    }
                } header: {
                    Text("Text cleanup")
                } footer: {
                    Text("Adds punctuation and fixes broken lines before speech. Runs on the Mac. Turn off if it changes the wording of your documents.")
                        .font(.caption)
                }

                #if os(macOS)
                Section {
                    TextField("Python", text: $pythonPath)
                        .font(.system(.callout, design: .monospaced))
                        .textFieldStyle(.roundedBorder)
                    Button("Reset to Default") { pythonPath = EngineController.defaultPythonPath }
                        .disabled(pythonPath == EngineController.defaultPythonPath)
                } header: {
                    Text("Engine")
                } footer: {
                    Text("The Python environment with mlx-audio and mlx-lm. The engine starts only while preparing or generating, and stops afterwards.")
                        .font(.caption)
                }
                #endif

                SyncSettingsSection()

                VoiceSettingsSection()

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
