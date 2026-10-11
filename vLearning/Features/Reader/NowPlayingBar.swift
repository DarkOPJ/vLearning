import SwiftUI

/// Small player shown at the bottom while a document plays and its reader isn't on screen.
/// Tap it to open the reader.
struct NowPlayingBar: View {
    var onOpen: (VLDocument) -> Void

    private var player: AudioPlayer { .shared }

    var body: some View {
        if let doc = player.document, player.readerDocumentId != doc.id {
            HStack(spacing: DS.Space.m) {
                Button { onOpen(doc) } label: {
                    HStack(spacing: DS.Space.m) {
                        Image(systemName: player.isPlaying ? "waveform" : "pause")
                            .symbolEffect(.variableColor.iterative, isActive: player.isPlaying)
                            .foregroundStyle(Color.accentColor)
                            .frame(width: 22)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(doc.title)
                                .font(.subheadline.weight(.semibold))
                                .lineLimit(1)
                            Text(player.currentItem?.text ?? "")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        Spacer(minLength: 0)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Open the reader")

                Group {
                    Button { player.togglePlay() } label: {
                        Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                            .contentTransition(.symbolEffect(.replace))
                    }
                    .help(player.isPlaying ? "Pause" : "Play")
                    Button { player.next() } label: { Image(systemName: "forward.fill") }
                        .help("Next sentence")
                    Button { player.close() } label: { Image(systemName: "xmark") }
                        .help("Stop and close")
                }
                .font(.title3)
                .buttonStyle(.plain)
                .frame(width: 30, height: 30)
            }
            .padding(.horizontal, DS.Space.l)
            .padding(.vertical, DS.Space.s)
            .background(.bar)
            .overlay(alignment: .top) { Divider() }
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }
}
