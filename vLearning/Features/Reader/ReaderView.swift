import SwiftUI

/// Listen to a document: sentences page by page, with the one being read highlighted.
/// Tap a sentence to play from there. PDFs can switch to the original page.
struct ReaderView: View {
    @Bindable var document: VLDocument

    @State private var mode: Mode = .text
    @State private var originalPage = 0

    enum Mode: String, CaseIterable, Identifiable {
        case text = "Text", original = "Original"
        var id: Self { self }
    }

    private var player: AudioPlayer { .shared }
    private var isActive: Bool { player.document?.id == document.id }
    private var pageNoun: String { document.kind == .pptx ? "Slide" : "Page" }

    /// The highlighted sentence: what's playing, or where the document was left off.
    private var current: (page: Int, index: Int) {
        if isActive, let item = player.currentItem { return (item.page, item.index) }
        return (document.currentPageIndex, document.currentSentenceIndex)
    }

    var body: some View {
        Group {
            if mode == .original {
                OriginalPageView(document: document, page: $originalPage, current: current)
            } else {
                sentences
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        #if os(macOS)
        .background(Color.macMain)
        .environment(\.colorScheme, .dark)
        #else
        .background(Color.systemBackground)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .navigationTitle(document.title)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            PlayerControls(document: document)
        }
        .toolbar {
            if document.kind == .pdf {
                ToolbarItem(placement: .principal) {
                    Picker("View", selection: $mode) {
                        ForEach(Mode.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 180)
                }
            }
        }
        .onAppear {
            player.readerDocumentId = document.id
            if !isActive || !player.isPlaying { player.load(document) }
            originalPage = current.page
        }
        .onDisappear {
            if player.readerDocumentId == document.id { player.readerDocumentId = nil }
        }
        .onChange(of: current.page) { _, page in originalPage = page }
    }

    // MARK: - Text

    private var sentences: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: DS.Space.xs) {
                    if document.audioReadyCount == 0 {
                        noAudioBanner
                    }
                    ForEach(document.readPages) { page in
                        Text("\(pageNoun) \(page.pageIndex + 1)")
                            .sectionHeaderStyle()
                            .padding(.top, DS.Space.xl)
                            .padding(.bottom, DS.Space.xs)
                            .padding(.horizontal, DS.Space.m)
                        ForEach(Array(page.sentences.enumerated()), id: \.offset) { i, text in
                            SentenceRow(
                                text: text,
                                isCurrent: page.pageIndex == current.page && i == current.index,
                                hasAudio: page.sentenceAudio[text] != nil
                            ) {
                                player.play(document, page: page.pageIndex, sentence: i)
                            }
                            .id(rowID(page.pageIndex, i))
                        }
                    }
                }
                .padding(.horizontal, DS.Space.l)
                .padding(.bottom, DS.Space.xxl)
                .frame(maxWidth: 760)
                .frame(maxWidth: .infinity)
            }
            .onAppear {
                proxy.scrollTo(rowID(current.page, current.index), anchor: .center)
            }
            .onChange(of: rowID(current.page, current.index)) { _, id in
                withAnimation(.easeInOut(duration: 0.35)) { proxy.scrollTo(id, anchor: .center) }
            }
        }
    }

    private func rowID(_ page: Int, _ index: Int) -> String { "\(page)-\(index)" }

    private var noAudioBanner: some View {
        HStack(spacing: DS.Space.m) {
            Image(systemName: "waveform.slash")
                .font(.title3)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text("No audio yet").font(.headline)
                Text(GenerationQueue.isAvailable
                     ? "Use Generate Audio on the document page first."
                     : "Audio is generated on your Mac. Syncing it to this iPhone comes in a later step.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(DS.Space.l)
        .cardStyle()
        .padding(.top, DS.Space.l)
    }
}

// MARK: - Sentence row

private struct SentenceRow: View {
    let text: String
    let isCurrent: Bool
    let hasAudio: Bool
    let onTap: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: DS.Space.s) {
            Text(text)
                .font(.system(.title3, design: .serif))
                .lineSpacing(3)
                .foregroundStyle(isCurrent ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
                .frame(maxWidth: .infinity, alignment: .leading)
            if !hasAudio {
                Image(systemName: "waveform.slash")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .help("No audio for this sentence")
            }
        }
        .padding(.horizontal, DS.Space.m)
        .padding(.vertical, DS.Space.s)
        .background {
            RoundedRectangle(cornerRadius: DS.Radius.s, style: .continuous)
                .fill(Color.accentColor.opacity(isCurrent ? 0.18 : 0))
        }
        .overlay(alignment: .leading) {
            if isCurrent {
                Capsule()
                    .fill(Color.accentColor)
                    .frame(width: 3)
                    .padding(.vertical, DS.Space.s)
            }
        }
        .opacity(hasAudio ? 1 : 0.55)
        .contentShape(Rectangle())
        .onTapGesture(perform: onTap)
        .animation(.easeInOut(duration: 0.25), value: isCurrent)
    }
}

// MARK: - Original page

/// The rendered PDF page. Follows the page being read; arrows look at other pages.
private struct OriginalPageView: View {
    let document: VLDocument
    @Binding var page: Int
    let current: (page: Int, index: Int)

    private var pages: [DocumentPage] { document.pages.sorted { $0.pageIndex < $1.pageIndex } }
    private var shown: DocumentPage? { pages.first { $0.pageIndex == page } ?? pages.first }

    private var currentSentence: String? {
        guard let p = pages.first(where: { $0.pageIndex == current.page }),
              p.sentences.indices.contains(current.index) else { return nil }
        return p.sentences[current.index]
    }

    var body: some View {
        VStack(spacing: DS.Space.m) {
            HStack {
                Button { step(-1) } label: { Image(systemName: "chevron.left") }
                    .disabled(page <= (pages.first?.pageIndex ?? 0))
                Spacer()
                Text("Page \(page + 1) of \(pages.count)")
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(.secondary)
                if page != current.page {
                    Button("Back to Reading") { page = current.page }
                        .buttonStyle(.borderless)
                        .font(.subheadline)
                }
                Spacer()
                Button { step(1) } label: { Image(systemName: "chevron.right") }
                    .disabled(page >= (pages.last?.pageIndex ?? 0))
            }
            .buttonStyle(.bordered)
            .padding(.horizontal, DS.Space.l)

            if let path = shown?.previewImagePath {
                StoredImage(url: DocumentStorage.url(for: document.id, relativePath: path), maxPixelSize: 2000)
                    .clipShape(RoundedRectangle(cornerRadius: DS.Radius.s, style: .continuous))
                    .shadow(color: .black.opacity(0.25), radius: 8, y: 2)
                    .padding(.horizontal, DS.Space.l)
                    .frame(maxHeight: .infinity)
                    .id(path)
            } else {
                ContentUnavailableView("No Page Image", systemImage: "doc")
                    .frame(maxHeight: .infinity)
            }

            if page == current.page, let currentSentence {
                Text(currentSentence)
                    .font(.system(.body, design: .serif))
                    .multilineTextAlignment(.center)
                    .lineLimit(3)
                    .padding(.horizontal, DS.Space.l)
                    .padding(.vertical, DS.Space.s)
                    .frame(maxWidth: 700)
                    .background(Color.accentColor.opacity(0.18), in: RoundedRectangle(cornerRadius: DS.Radius.s))
                    .padding(.horizontal, DS.Space.l)
                    .animation(.easeInOut(duration: 0.25), value: currentSentence)
            }
        }
        .padding(.vertical, DS.Space.m)
    }

    private func step(_ delta: Int) {
        guard let i = pages.firstIndex(where: { $0.pageIndex == page }),
              pages.indices.contains(i + delta) else { return }
        page = pages[i + delta].pageIndex
    }
}

// MARK: - Controls

/// Progress, transport buttons, speed and sleep timer.
struct PlayerControls: View {
    let document: VLDocument

    private var player: AudioPlayer { .shared }
    private var isActive: Bool { player.document?.id == document.id }
    private var canPlay: Bool { document.audioReadyCount > 0 }

    static let speeds: [Double] = [0.5, 0.75, 1, 1.25, 1.5, 1.75, 2]

    var body: some View {
        VStack(spacing: DS.Space.s) {
            if isActive, let notice = player.notice {
                HStack(spacing: DS.Space.xs) {
                    Image(systemName: "info.circle")
                    Text(notice)
                    Button { player.notice = nil } label: { Image(systemName: "xmark") }
                        .buttonStyle(.borderless)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            progress

            HStack(spacing: DS.Space.s) {
                speedMenu
                Spacer()
                transport
                Spacer()
                sleepMenu
            }
        }
        .padding(.horizontal, DS.Space.l)
        .padding(.top, DS.Space.m)
        .padding(.bottom, DS.Space.s)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
    }

    private var progress: some View {
        let total = isActive ? player.totalDuration : 0
        let elapsed = isActive ? player.elapsed : 0
        return VStack(spacing: 2) {
            ProgressView(value: total > 0 ? min(elapsed / total, 1) : 0)
                .tint(Color.accentColor)
            HStack {
                Text(elapsed.clockString)
                Spacer()
                if isActive, let item = player.currentItem {
                    Text("\(document.kind == .pptx ? "Slide" : "Page") \(item.page + 1)")
                }
                Spacer()
                Text("-" + (max(total - elapsed, 0) / player.speed).clockString)
            }
            .font(.caption2.monospacedDigit())
            .foregroundStyle(.secondary)
        }
        .opacity(isActive ? 1 : 0.4)
    }

    private var transport: some View {
        HStack(spacing: DS.Space.l) {
            Button { player.previousPage() } label: { Image(systemName: "backward.end.fill") }
                .help("Previous page")
            Button { player.previous() } label: { Image(systemName: "backward.fill") }
                .help("Previous sentence")
                .keyboardShortcut(.leftArrow, modifiers: [])
            Button {
                isActive ? player.togglePlay() : player.play(document)
            } label: {
                Image(systemName: isActive && player.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                    .font(.system(size: 44))
                    .foregroundStyle(Color.accentColor)
                    .contentTransition(.symbolEffect(.replace))
            }
            .help(isActive && player.isPlaying ? "Pause" : "Play")
            .keyboardShortcut(.space, modifiers: [])
            .disabled(!canPlay)
            Button { player.next() } label: { Image(systemName: "forward.fill") }
                .help("Next sentence")
                .keyboardShortcut(.rightArrow, modifiers: [])
            Button { player.nextPage() } label: { Image(systemName: "forward.end.fill") }
                .help("Next page")
        }
        .font(.title3)
        .buttonStyle(.plain)
        .foregroundStyle(.primary)
        .disabled(!isActive && !canPlay)
    }

    private var speedMenu: some View {
        Menu {
            Picker("Speed", selection: Binding(get: { player.speed }, set: { player.speed = $0 })) {
                ForEach(Self.speeds, id: \.self) { Text(Self.speedLabel($0)).tag($0) }
            }
            .pickerStyle(.inline)
        } label: {
            Text(Self.speedLabel(player.speed))
                .font(.subheadline.monospacedDigit().weight(.semibold))
                .frame(minWidth: 48)
        }
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Speed")
    }

    private var sleepMenu: some View {
        Menu {
            Button("Off") { player.setSleepTimer(nil) }
            ForEach([15, 30, 45, 60], id: \.self) { m in
                Button("\(m) minutes") { player.setSleepTimer(.minutes(m)) }
            }
            Button("End of \(document.kind == .pptx ? "slide" : "page")") { player.setSleepTimer(.endOfPage) }
        } label: {
            if let deadline = player.sleepDeadline {
                Label { Text(timerInterval: Date.now...deadline, countsDown: true).monospacedDigit() }
                    icon: { Image(systemName: "moon.zzz.fill") }
                    .font(.subheadline)
            } else if player.sleepTimer == .endOfPage {
                Label("End of page", systemImage: "moon.zzz.fill").font(.subheadline)
            } else {
                Image(systemName: "moon.zzz").font(.title3)
            }
        }
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Sleep timer")
    }

    static func speedLabel(_ s: Double) -> String {
        s == 1 ? "1×" : String(format: "%g×", s)
    }
}
