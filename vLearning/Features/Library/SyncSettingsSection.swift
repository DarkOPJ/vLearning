import SwiftUI

/// Settings for Wi-Fi sync. On the Mac: turn it on and show the pairing code.
/// On the iPhone: find the Mac, pair with its code, and see how syncing is going.
struct SyncSettingsSection: View {
    var body: some View {
        #if os(macOS)
        MacSyncSettings()
        #else
        PhoneSyncSettings()
        #endif
    }
}

#if os(macOS)
private struct MacSyncSettings: View {
    @State private var server = SyncServer.shared

    var body: some View {
        Section {
            Toggle("Sync with my iPhone over Wi-Fi", isOn: Binding(
                get: { server.isEnabled }, set: { server.isEnabled = $0 }
            ))

            if server.isEnabled {
                LabeledContent("Pairing code") {
                    HStack(spacing: DS.Space.m) {
                        Text(server.pairCode.chunked)
                            .font(.system(.title3, design: .monospaced, weight: .semibold))
                            .textSelection(.enabled)
                        Button("New Code") { server.newPairCode() }
                            .buttonStyle(.borderless)
                    }
                }

                if let error = server.listenerError {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.callout)
                        .foregroundStyle(.orange)
                }

                ForEach(server.pairedDevices) { device in
                    HStack {
                        Image(systemName: "iphone")
                            .foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(device.name)
                            Text(detail(device))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Remove", role: .destructive) { server.unpair(device) }
                            .buttonStyle(.borderless)
                    }
                }
            }
        } header: {
            Text("iPhone Sync")
        } footer: {
            Text("On your iPhone, open vLearning › Settings › Mac Sync on the same Wi-Fi and enter this code. Documents, your edits, audio and where you stopped listening sync both ways while both apps are open. The iPhone can also ask this Mac to generate audio.")
                .font(.caption)
        }
    }

    private func detail(_ device: SyncServer.PairedDevice) -> String {
        if server.connectedDevices.contains(device.name) { return "Connected" }
        if let last = device.lastSyncAt { return "Last synced \(last.formatted(.relative(presentation: .named)))" }
        return "Paired \(device.pairedAt.formatted(date: .abbreviated, time: .omitted))"
    }
}
#endif

#if os(iOS)
private struct PhoneSyncSettings: View {
    @State private var client = SyncClient.shared
    @State private var pairingWith: SyncClient.Peer?
    @State private var code = ""
    @State private var isPairing = false
    @State private var pairError: String?
    @State private var confirmUnpair = false

    var body: some View {
        Section {
            if client.isPaired {
                paired
            } else {
                unpaired
            }
        } header: {
            Text("Mac Sync")
        } footer: {
            Text("Syncs documents, your edits, audio and where you stopped listening with vLearning on your Mac, over your Wi-Fi, while both apps are open. Breeze audio is generated on the Mac.")
                .font(.caption)
        }
        .alert("Pair with \(pairingWith?.name ?? "Mac")", isPresented: Binding(
            get: { pairingWith != nil }, set: { if !$0 { pairingWith = nil } }
        ), presenting: pairingWith) { peer in
            TextField("6-digit code", text: $code)
                .keyboardType(.numberPad)
            Button("Pair") { pair(peer) }
            Button("Cancel", role: .cancel) { code = "" }
        } message: { _ in
            Text("Enter the code shown on your Mac in vLearning › Settings › iPhone Sync.")
        }
        .alert("Couldn't Pair", isPresented: Binding(
            get: { pairError != nil }, set: { if !$0 { pairError = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(pairError ?? "")
        }
        .confirmationDialog("Stop syncing with \(client.pairedMacName ?? "your Mac")?",
                            isPresented: $confirmUnpair, titleVisibility: .visible) {
            Button("Unpair", role: .destructive) { client.unpair() }
        } message: {
            Text("Documents already on this iPhone stay.")
        }
    }

    @ViewBuilder
    private var paired: some View {
        LabeledContent("Mac", value: client.pairedMacName ?? "Mac")
        HStack(spacing: DS.Space.s) {
            switch client.status {
            case .syncing, .connecting:
                ProgressView().controlSize(.small)
            case .connected:
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            case .failed:
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            default:
                Image(systemName: "wifi").foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(client.status.label)
                if let last = client.lastSync {
                    Text("Last synced \(last.formatted(.relative(presentation: .named)))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        Button("Sync Now") { client.syncNow() }
        Button("Unpair", role: .destructive) { confirmUnpair = true }
    }

    @ViewBuilder
    private var unpaired: some View {
        if client.discovered.isEmpty {
            HStack(spacing: DS.Space.s) {
                ProgressView().controlSize(.small)
                Text("Looking for vLearning on your Mac…")
                    .foregroundStyle(.secondary)
            }
            Text("Open vLearning on your Mac, on the same Wi-Fi, with iPhone Sync turned on in its Settings.")
                .font(.caption)
                .foregroundStyle(.secondary)
        } else {
            ForEach(client.discovered) { peer in
                HStack {
                    Image(systemName: "laptopcomputer")
                        .foregroundStyle(.secondary)
                    Text(peer.name)
                    Spacer()
                    if isPairing {
                        ProgressView().controlSize(.small)
                    } else {
                        Button("Pair…") {
                            code = ""
                            pairingWith = peer
                        }
                    }
                }
            }
        }
    }

    private func pair(_ peer: SyncClient.Peer) {
        let entered = code
        code = ""
        isPairing = true
        Task {
            do {
                try await client.pair(with: peer, code: entered)
            } catch {
                pairError = error.localizedDescription
            }
            isPairing = false
        }
    }
}
#endif

private extension String {
    /// "123456" → "123 456"
    var chunked: String {
        guard count == 6 else { return self }
        return prefix(3) + " " + suffix(3)
    }
}
