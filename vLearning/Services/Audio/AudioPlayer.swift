import Foundation
import AVFoundation
import MediaPlayer

/// Plays a document's sentence clips in order, one at a time, and keeps the reading position.
///
/// Sentences without audio (generation stopped partway, or edited since) are skipped. Playback keeps
/// going in the background and can be controlled from the lock screen, Control Center and media keys.
@MainActor
@Observable
final class AudioPlayer {

    static let shared = AudioPlayer()
    static let speedKey = "defaultSpeed"

    /// One sentence in reading order.
    struct Item: Equatable {
        let page: Int        // DocumentPage.pageIndex
        let index: Int       // sentence index on that page
        let text: String
        let path: String?    // relative .m4a path, nil if it has no audio
        let duration: Double
    }

    enum SleepTimer: Equatable {
        case minutes(Int)
        case endOfPage

        var label: String {
            switch self {
            case .minutes(let m): "\(m) min"
            case .endOfPage:      "End of page"
            }
        }
    }

    // MARK: - State

    private(set) var document: VLDocument?
    private(set) var items: [Item] = []
    private(set) var position = 0
    private(set) var isPlaying = false
    /// Seconds into the current sentence.
    private(set) var sentenceTime: Double = 0
    private(set) var sleepTimer: SleepTimer?
    private(set) var sleepDeadline: Date?
    /// A short message, e.g. that sentences without audio were skipped.
    var notice: String?

    /// The document whose reader is on screen (the mini player hides for it).
    var readerDocumentId: UUID?
    /// Set by the mini player to ask that document's page view to open its reader.
    var openReaderRequest: UUID?

    var speed: Double {
        didSet {
            player.defaultRate = Float(speed)
            if isPlaying { player.rate = Float(speed) }
            UserDefaults.standard.set(speed, forKey: Self.speedKey)
            updateNowPlaying()
        }
    }

    var currentItem: Item? { items.indices.contains(position) ? items[position] : nil }

    var totalDuration: Double { offsets.last.map { $0 + (items.last?.duration ?? 0) } ?? 0 }
    var elapsed: Double { (offsets.indices.contains(position) ? offsets[position] : 0) + sentenceTime }

    private let player = AVPlayer()
    private var offsets: [Double] = []   // start time of each item
    private var finished = false
    private var sleepTask: Task<Void, Never>?

    private init() {
        let saved = UserDefaults.standard.double(forKey: Self.speedKey)
        speed = saved > 0 ? saved : 1
        player.defaultRate = Float(speed)
        player.automaticallyWaitsToMinimizeStalling = false
        observe()
        Self.registerRemoteCommands()
    }

    // MARK: - Opening

    /// Builds the playlist for a document, keeping the current sentence. Doesn't start playing.
    func load(_ doc: VLDocument) {
        let isSame = document?.id == doc.id
        let key = isSame ? currentItem.map { ($0.page, $0.index) } : (doc.currentPageIndex, doc.currentSentenceIndex)
        if !isSame {
            stopPlayback()
            document = doc
            notice = nil
            finished = false
        }
        items = doc.readPages.flatMap { page in
            page.sentences.enumerated().map { i, text in
                Item(page: page.pageIndex, index: i, text: text,
                     path: page.sentenceAudio[text], duration: page.sentenceDurations[text] ?? 0)
            }
        }
        var t = 0.0
        offsets = items.map { item in defer { t += item.duration }; return t }
        position = key.flatMap { index(page: $0.0, sentence: $0.1) } ?? 0
    }

    /// Index of a sentence, or the first sentence on or after that page.
    func index(page: Int, sentence: Int) -> Int? {
        items.firstIndex { $0.page == page && $0.index == sentence }
            ?? items.firstIndex { $0.page >= page }
    }

    // MARK: - Controls

    /// Plays a document from a sentence (or from where it was left off).
    func play(_ doc: VLDocument, page: Int? = nil, sentence: Int? = nil) {
        if document?.id != doc.id || !isPlaying { load(doc) }
        var start = position
        if let page { start = index(page: page, sentence: sentence ?? 0) ?? position }
        else if finished { start = 0 }
        startItem(at: start, autoplay: true)
    }

    func togglePlay() { isPlaying ? pause() : resume() }

    func resume() {
        guard let document else { return }
        if player.currentItem != nil && !finished {
            activateSession()
            player.play()
            isPlaying = true
            updateNowPlaying()
        } else {
            play(document)
        }
    }

    func pause() {
        player.pause()
        isPlaying = false
        updateNowPlaying()
    }

    /// Next sentence.
    func next() {
        guard position + 1 < items.count else { return }
        startItem(at: position + 1, autoplay: isPlaying)
    }

    /// Restarts the sentence, or goes to the previous one if it just started.
    func previous() {
        let target = sentenceTime > 2 ? position : max(position - 1, 0)
        startItem(at: target, autoplay: isPlaying, direction: -1)
    }

    func nextPage() {
        guard let page = currentItem?.page,
              let target = items.firstIndex(where: { $0.page > page }) else { return }
        startItem(at: target, autoplay: isPlaying)
    }

    /// Start of this page, or the previous page if already near its start.
    func previousPage() {
        guard let page = currentItem?.page,
              let pageStart = items.firstIndex(where: { $0.page == page }) else { return }
        var target = pageStart
        if position == pageStart || (position == pageStart + 1 && sentenceTime < 2),
           let prevPage = items[..<pageStart].last?.page {
            target = items.firstIndex { $0.page == prevPage } ?? pageStart
        }
        startItem(at: target, autoplay: isPlaying)
    }

    /// Stops and closes the player.
    func close() {
        stopPlayback()
        setSleepTimer(nil)
        document = nil
        items = []
        offsets = []
        position = 0
        notice = nil
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        #if os(macOS)
        MPNowPlayingInfoCenter.default().playbackState = .stopped
        #endif
    }

    // MARK: - Sleep timer

    func setSleepTimer(_ timer: SleepTimer?) {
        sleepTask?.cancel()
        sleepTask = nil
        sleepTimer = timer
        sleepDeadline = nil
        if case .minutes(let m) = timer {
            let deadline = Date.now.addingTimeInterval(Double(m) * 60)
            sleepDeadline = deadline
            sleepTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(deadline.timeIntervalSinceNow))
                guard !Task.isCancelled, let self else { return }
                self.pause()
                self.sleepTimer = nil
                self.sleepDeadline = nil
            }
        }
    }

    // MARK: - Playback

    /// Plays (or, when paused, just moves to) the first sentence with audio from `index`,
    /// searching forwards (or backwards when going back).
    private func startItem(at index: Int, autoplay: Bool, direction: Int = 1) {
        guard let document, !items.isEmpty else { return }
        var i = index
        var skipped = 0
        while items.indices.contains(i), !hasAudio(items[i]) {
            i += direction
            skipped += 1
        }
        if !items.indices.contains(i) {
            if direction < 0 { return startItem(at: index, autoplay: autoplay) }
            reachedEnd()
            return
        }
        if skipped > 0 {
            notice = "Skipped \(skipped) sentence\(skipped == 1 ? "" : "s") without audio."
        }

        finished = false
        position = i
        sentenceTime = 0
        document.currentPageIndex = items[i].page
        document.currentSentenceIndex = items[i].index
        document.lastOpenedAt = .now

        let item = AVPlayerItem(url: DocumentStorage.url(for: document.id, relativePath: items[i].path!))
        item.audioTimePitchAlgorithm = .timeDomain   // keeps the voice's pitch at other speeds
        player.replaceCurrentItem(with: item)
        if autoplay {
            activateSession()
            player.play()
            isPlaying = true
        }
        updateNowPlaying()
    }

    private func hasAudio(_ item: Item) -> Bool {
        guard let document, let path = item.path else { return false }
        return FileManager.default.fileExists(atPath: DocumentStorage.url(for: document.id, relativePath: path).path)
    }

    private func itemDidFinish() {
        guard isPlaying else { return }
        let next = position + 1
        if sleepTimer == .endOfPage, items.indices.contains(next), items[next].page != items[position].page {
            startItem(at: next, autoplay: false)
            pause()
            setSleepTimer(nil)
            return
        }
        startItem(at: next, autoplay: true)
    }

    private func reachedEnd() {
        player.pause()
        player.replaceCurrentItem(with: nil)
        isPlaying = false
        finished = true
        sentenceTime = 0
        if sleepTimer == .endOfPage { setSleepTimer(nil) }
        // Next time, start from the beginning.
        if let first = items.first {
            document?.currentPageIndex = first.page
            document?.currentSentenceIndex = first.index
        }
        updateNowPlaying()
    }

    private func stopPlayback() {
        player.pause()
        player.replaceCurrentItem(with: nil)
        isPlaying = false
        sentenceTime = 0
    }

    // MARK: - System integration

    private func activateSession() {
        #if os(iOS)
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .spokenAudio)
        try? session.setActive(true)
        #endif
    }

    private func observe() {
        let center = NotificationCenter.default
        // A clip that can't be played is skipped like a finished one.
        for name in [AVPlayerItem.didPlayToEndTimeNotification, AVPlayerItem.failedToPlayToEndTimeNotification] {
            center.addObserver(forName: name, object: nil, queue: .main) { note in
                let finished = (note.object as AnyObject?).map(ObjectIdentifier.init)
                MainActor.assumeIsolated {
                    let player = AudioPlayer.shared
                    guard let current = player.player.currentItem, finished == ObjectIdentifier(current) else { return }
                    player.itemDidFinish()
                }
            }
        }
        player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.25, preferredTimescale: 600), queue: .main) { time in
            MainActor.assumeIsolated {
                let seconds = time.seconds
                AudioPlayer.shared.sentenceTime = seconds.isFinite ? seconds : 0
            }
        }

        #if os(iOS)
        // Phone calls, Siri, other apps: pause, and resume afterwards when the system says so.
        center.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { note in
            let rawType = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
            let rawOptions = note.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt
            MainActor.assumeIsolated {
                guard let rawType, let type = AVAudioSession.InterruptionType(rawValue: rawType) else { return }
                let player = AudioPlayer.shared
                switch type {
                case .began:
                    player.isPlaying = false
                    player.updateNowPlaying()
                case .ended:
                    let options = rawOptions.map(AVAudioSession.InterruptionOptions.init) ?? []
                    if options.contains(.shouldResume), player.document != nil { player.resume() }
                @unknown default:
                    break
                }
            }
        }
        // Headphones unplugged: pause instead of playing out loud.
        center.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) { note in
            let raw = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt
            guard let raw, AVAudioSession.RouteChangeReason(rawValue: raw) == .oldDeviceUnavailable else { return }
            MainActor.assumeIsolated { AudioPlayer.shared.pause() }
        }
        #endif
    }

    /// Lock screen, Control Center, headphone buttons and media keys.
    /// Nonisolated so the handlers don't assume they're called on the main actor.
    private nonisolated static func registerRemoteCommands() {
        let center = MPRemoteCommandCenter.shared()
        func on(_ command: MPRemoteCommand, _ action: @escaping @MainActor (AudioPlayer) -> Void) {
            command.isEnabled = true
            command.addTarget { _ in
                Task { @MainActor in action(AudioPlayer.shared) }
                return .success
            }
        }
        on(center.playCommand) { $0.resume() }
        on(center.pauseCommand) { $0.pause() }
        on(center.togglePlayPauseCommand) { $0.togglePlay() }
        on(center.nextTrackCommand) { $0.next() }
        on(center.previousTrackCommand) { $0.previous() }
    }

    private func updateNowPlaying() {
        guard let document, let item = currentItem else { return }
        let noun = document.kind == .pptx ? "Slide" : "Page"
        MPNowPlayingInfoCenter.default().nowPlayingInfo = [
            MPMediaItemPropertyTitle: document.title,
            MPMediaItemPropertyArtist: "\(noun) \(item.page + 1)",
            MPMediaItemPropertyAlbumTitle: "vLearning",
            MPMediaItemPropertyPlaybackDuration: totalDuration,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: elapsed,
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? speed : 0,
            MPNowPlayingInfoPropertyDefaultPlaybackRate: 1.0,
        ]
        #if os(macOS)
        MPNowPlayingInfoCenter.default().playbackState = isPlaying ? .playing : .paused
        #endif
    }
}

extension TimeInterval {
    /// 75 → "1:15", 3725 → "1:02:05".
    var clockString: String {
        let s = Int(self.rounded(.down))
        return s >= 3600
            ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60)
            : String(format: "%d:%02d", s / 60, s % 60)
    }
}
