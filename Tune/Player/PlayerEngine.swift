import AVFoundation
import MediaPlayer
import Observation
import SwiftData
import SwiftUI
import UIKit
import WidgetKit

/// 대기열에 들어가는 곡 하나. SwiftData 객체를 직접 들고 있지 않아서 안전하게 저장·복원할 수 있다.
struct QueueItem: Identifiable, Hashable, Codable {
    var uid = UUID()
    var trackID: UUID
    var title: String
    var artist: String
    var album: String
    var albumArtist: String
    var genre: String
    var relativePath: String
    var artworkFile: String?
    var duration: Double
    var isLossless: Bool

    var id: UUID { uid }
    var fileURL: URL { LibraryPaths.url(forRelative: relativePath) }

    init(_ track: Track) {
        trackID = track.id
        title = track.title
        artist = track.artistName
        album = track.albumTitle
        albumArtist = track.albumArtistName
        genre = track.genre
        relativePath = track.relativePath
        artworkFile = track.artworkFile
        duration = track.duration
        isLossless = track.isLossless
    }
}

enum PlaybackContext: Codable, Hashable {
    case none
    case album(UUID)
    case artist(UUID)
    case playlist(UUID)
}

enum RepeatMode: String, Codable, CaseIterable {
    case off, all, one

    var next: RepeatMode {
        switch self {
        case .off: .all
        case .all: .one
        case .one: .off
        }
    }

    var symbol: String { self == .one ? "repeat.1" : "repeat" }
}

@MainActor
@Observable
final class PlayerEngine {
    static let shared = PlayerEngine()

    private(set) var queue: [QueueItem] = []
    private(set) var index: Int = 0
    private(set) var history: [QueueItem] = []
    private(set) var isPlaying = false
    private(set) var elapsed: Double = 0
    private(set) var itemDuration: Double = 0
    private(set) var context: PlaybackContext = .none
    var currentPalette: [Color] = []
    var currentColor: Color = Color(.systemGray3)
    var isCurrentFavorite = false

    var shuffle = false {
        didSet { if oldValue != shuffle, !suppressShuffleReorder { applyShuffle() } }
    }
    var repeatMode: RepeatMode = .off { didSet { saveState() } }

    var current: QueueItem? { queue.indices.contains(index) ? queue[index] : nil }
    var upNext: [QueueItem] { index + 1 < queue.count ? Array(queue[(index + 1)...]) : [] }
    var duration: Double { itemDuration > 0 ? itemDuration : (current?.duration ?? 0) }
    var hasItem: Bool { current != nil }

    // 수면 타이머
    private(set) var sleepTimerEnd: Date?
    private(set) var sleepAtTrackEnd = false
    var isSleepTimerActive: Bool { sleepTimerEnd != nil || sleepAtTrackEnd }

    @ObservationIgnored private let player = AVQueuePlayer()
    @ObservationIgnored private var originalOrder: [QueueItem] = []
    @ObservationIgnored private var timeObserver: Any?
    @ObservationIgnored private var modelContext: ModelContext?
    @ObservationIgnored private var listened: Double = 0
    @ObservationIgnored private var lastTime: Double = 0
    @ObservationIgnored private var wasPlayingBeforeInterruption = false
    @ObservationIgnored private var lastStateSave = Date.distantPast
    @ObservationIgnored private var preloadedItem: AVPlayerItem?
    @ObservationIgnored private var currentItem: AVPlayerItem?
    @ObservationIgnored private var suppressShuffleReorder = false
    @ObservationIgnored private var itemStatusObservation: NSKeyValueObservation?
    @ObservationIgnored private var consecutiveFailures = 0
    /// 재생하지 못하고 건너뛴 곡 안내 (화면 위에 잠깐 보여 준다)
    var playbackNotice: String?

    private init() {
        player.actionAtItemEnd = .advance
        configureAudioSession()
        configureRemoteCommands()
        observeNotifications()
        addTimeObserver()
        // 이 기기가 풀 수 없는 형식(예: 일부 Dolby AC-4가 든 MP4)이면 멈춰 있지 않고 다음 곡으로 넘어간다.
        itemStatusObservation = player.observe(\.currentItem?.status, options: [.new]) { [weak self] player, _ in
            guard let item = player.currentItem, item.status == .failed else { return }
            Task { @MainActor in self?.handleItemFailure(item) }
        }
    }

    private func handleItemFailure(_ item: AVPlayerItem) {
        guard item === player.currentItem else { return }
        let title = current?.title ?? "이 곡"
        consecutiveFailures += 1
        if consecutiveFailures >= 5 {
            playbackNotice = "재생할 수 없는 곡이 이어져서 멈췄어요"
            pause()
            consecutiveFailures = 0
            return
        }
        playbackNotice = "'\(title)'은(는) 이 기기에서 재생할 수 없는 형식이라 건너뛰었어요"
        next()
    }

    func attach(context: ModelContext) {
        modelContext = context
        restoreState()
    }

    func handle(_ command: PlaybackCommand) {
        switch command {
        case .toggle: togglePlayPause()
        case .next: next()
        case .previous: previous()
        case .shuffleLibrary: playLibrary(favoritesOnly: false)
        case .playFavorites: playLibrary(favoritesOnly: true)
        case .playAlbum(let id):
            if let uuid = UUID(uuidString: id) { playAlbum(uuid) }
        case .toggleFavorite: toggleFavorite()
        case .play: if !isPlaying { togglePlayPause() }
        case .pause: if isPlaying { togglePlayPause() }
        }
    }

    // MARK: - 재생 시작

    func playLibrary(favoritesOnly: Bool) {
        guard let modelContext else { return }
        var descriptor = FetchDescriptor<Track>()
        if favoritesOnly { descriptor.predicate = #Predicate<Track> { $0.isFavorite } }
        let tracks = (try? modelContext.fetch(descriptor)) ?? []
        guard !tracks.isEmpty else { return }
        play(tracks, shuffled: true)
    }

    func playAlbum(_ id: UUID) {
        guard let modelContext else { return }
        var descriptor = FetchDescriptor<Album>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        guard let album = (try? modelContext.fetch(descriptor))?.first else { return }
        play(album.sortedTracks, context: .album(id))
    }

    // MARK: - 수면 타이머

    func setSleepTimer(minutes: Int) {
        sleepAtTrackEnd = false
        sleepTimerEnd = Date().addingTimeInterval(Double(minutes) * 60)
        player.volume = 1
    }

    func setSleepAtTrackEnd() {
        sleepTimerEnd = nil
        sleepAtTrackEnd = true
        player.volume = 1
    }

    func cancelSleepTimer() {
        sleepTimerEnd = nil
        sleepAtTrackEnd = false
        player.volume = 1
    }

    /// 끝나기 5초 전부터 소리를 줄인다.
    private func updateSleepTimer(at seconds: Double) {
        if let end = sleepTimerEnd {
            let remaining = end.timeIntervalSinceNow
            if remaining <= 0 {
                sleepTimerEnd = nil
                pause()
                player.volume = 1
            } else if remaining < 5 {
                player.volume = Float(remaining / 5)
            }
        } else if sleepAtTrackEnd, duration > 0 {
            let remaining = duration - seconds
            player.volume = remaining < 5 ? Float(max(remaining, 0) / 5) : 1
        }
    }

    func play(_ tracks: [Track], startAt start: Int = 0, shuffled: Bool = false, context: PlaybackContext = .none) {
        let items = tracks.map(QueueItem.init)
        play(items: items, startAt: start, shuffled: shuffled, context: context)
    }

    func play(items: [QueueItem], startAt start: Int = 0, shuffled: Bool = false, context: PlaybackContext = .none) {
        guard !items.isEmpty else { return }
        commitListening()
        self.context = context
        originalOrder = items
        let startIndex = min(max(start, 0), items.count - 1)
        if shuffled {
            var rest = items
            let first = start > 0 ? rest.remove(at: startIndex) : rest.remove(at: Int.random(in: rest.indices))
            queue = [first] + rest.shuffled()
            index = 0
            shuffleWithoutDidSet(true)
        } else {
            queue = items
            index = startIndex
            shuffleWithoutDidSet(false)
        }
        loadCurrent(play: true)
    }

    func playNext(_ tracks: [Track]) {
        let items = tracks.map(QueueItem.init)
        guard current != nil else { play(items: items); return }
        queue.insert(contentsOf: items, at: index + 1)
        originalOrder.append(contentsOf: items)
        refreshPreload()
        saveState()
    }

    func playLater(_ tracks: [Track]) {
        let items = tracks.map(QueueItem.init)
        guard current != nil else { play(items: items); return }
        queue.append(contentsOf: items)
        originalOrder.append(contentsOf: items)
        refreshPreload()
        saveState()
    }

    func jump(to item: QueueItem) {
        if let i = queue.firstIndex(of: item) {
            commitListening()
            index = i
            loadCurrent(play: true)
        } else if let historyIndex = history.lastIndex(of: item) {
            commitListening()
            history.remove(at: historyIndex)
            var replay = item
            replay.uid = UUID()
            queue.insert(replay, at: index + 1)
            index += 1
            loadCurrent(play: true)
        }
    }

    func removeFromUpNext(at offsets: IndexSet) {
        let absolute = offsets.map { $0 + index + 1 }.filter { queue.indices.contains($0) }
        for i in absolute.sorted(by: >) { queue.remove(at: i) }
        refreshPreload()
        saveState()
    }

    func moveUpNext(from source: IndexSet, to destination: Int) {
        var upcoming = upNext
        upcoming.move(fromOffsets: source, toOffset: destination)
        queue = Array(queue[...index]) + upcoming
        refreshPreload()
        saveState()
    }

    /// 보관함에서 빠진 곡을 대기열·기록에서 뺀다. 지금 곡이 빠졌으면 다음 곡으로 넘어간다.
    func removeTracks(_ ids: Set<UUID>) {
        history.removeAll { ids.contains($0.trackID) }
        originalOrder.removeAll { ids.contains($0.trackID) }
        guard let current else { return }
        let currentUID = current.uid
        let currentRemoved = ids.contains(current.trackID)
        queue.removeAll { ids.contains($0.trackID) && $0.uid != currentUID }
        index = queue.firstIndex { $0.uid == currentUID } ?? 0

        guard currentRemoved else {
            refreshPreload()
            saveState()
            return
        }
        let wasPlaying = isPlaying
        listened = 0
        queue.remove(at: index)
        if queue.isEmpty {
            player.removeAllItems()
            currentItem = nil
            preloadedItem = nil
            isPlaying = false
            elapsed = 0
            updateNowPlayingInfo()
            publishSharedState(force: true)
            saveState()
            return
        }
        index = min(index, queue.count - 1)
        loadCurrent(play: wasPlaying)
    }

    func clearUpNext() {
        queue = Array(queue.prefix(index + 1))
        refreshPreload()
        saveState()
    }

    // MARK: - 조작

    func togglePlayPause() {
        isPlaying ? pause() : resume()
    }

    func resume() {
        guard current != nil else { return }
        if player.currentItem == nil { loadCurrent(play: true, seekTo: elapsed); return }
        try? AVAudioSession.sharedInstance().setActive(true)
        player.play()
        isPlaying = true
        updateNowPlayingInfo()
        publishSharedState(force: true)
    }

    func pause() {
        player.pause()
        isPlaying = false
        updateNowPlayingInfo()
        publishSharedState(force: true)
        saveState()
    }

    func next() {
        guard !queue.isEmpty else { return }
        commitListening()
        if index + 1 < queue.count {
            moveToHistory(queue[index])
            index += 1
            loadCurrent(play: true)
        } else if repeatMode == .all {
            moveToHistory(queue[index])
            index = 0
            loadCurrent(play: true)
        } else if appendAutoplay() {
            moveToHistory(queue[index])
            index += 1
            loadCurrent(play: true)
        } else {
            pause()
            seek(to: 0)
        }
    }

    func previous() {
        guard current != nil else { return }
        if elapsed > 3 || index == 0 {
            seek(to: 0)
            return
        }
        commitListening()
        index -= 1
        loadCurrent(play: true)
    }

    @ObservationIgnored private var pendingSeek: (time: Double, started: Date, token: UUID)?

    /// MP3만 파일 전체 시간 정보를 미리 읽는다.
    /// MP3(가변 비트레이트)는 이게 없으면 구간 이동한 위치가 실제 소리와 2~3초 어긋난다.
    /// FLAC · M4A · WAV는 원래 정확하고, 큰 파일을 통째로 훑으면 곡 시작·넘김이 느려지므로 그대로 둔다.
    static func makeItem(_ url: URL) -> AVPlayerItem {
        guard url.pathExtension.lowercased() == "mp3" else { return AVPlayerItem(url: url) }
        let asset = AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        return AVPlayerItem(asset: asset)
    }

    func seek(to seconds: Double) {
        let target = CMTime(seconds: max(0, seconds), preferredTimescale: 600)
        // 구간 이동이 끝나기 전까지는 AVPlayer가 이전 위치를 알려주므로, 그동안은 목표 위치를 쓴다.
        // (가사를 누른 직후 원래 줄로 잠깐 되돌아갔다 오는 문제)
        let token = UUID()
        pendingSeek = (max(0, seconds), Date(), token)
        player.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
            Task { @MainActor in
                if self?.pendingSeek?.token == token { self?.pendingSeek = nil }
            }
        }
        elapsed = max(0, seconds)
        lastTime = elapsed
        updateNowPlayingInfo()
        publishSharedState(force: true)
    }

    /// 에어팟 같은 블루투스 이어폰은 소리가 귀에 닿기까지 시간이 걸린다(0.1~0.3초).
    /// 재생 위치는 "보낸 소리" 기준이라, 가사는 이만큼 늦춰서 "들리는 소리"에 맞춘다.
    @ObservationIgnored private(set) var outputLatency: Double = 0

    func refreshOutputLatency() {
        let session = AVAudioSession.sharedInstance()
        let latency = session.outputLatency + session.ioBufferDuration
        outputLatency = latency.isFinite ? min(max(latency, 0), 0.5) : 0
    }

    /// 가사용 시간: 들리는 소리에 맞춘 재생 위치
    func lyricsTime() -> Double {
        guard isPlaying else { return elapsed }
        return max(0, currentTime() - outputLatency)
    }

    /// 가사 화면처럼 매 프레임 정확한 시간이 필요할 때 쓴다.
    func currentTime() -> Double {
        if let pending = pendingSeek, Date().timeIntervalSince(pending.started) < 3 {
            // 이동이 끝날 때까지는 누른 위치에 멈춰 둔다.
            // (예전엔 이동하는 동안에도 시간을 흘려보내서, 파일을 읽느라 이동이 1~2초 걸리면
            //  가사가 그만큼 소리보다 앞서 갔다)
            return pending.time
        }
        let time = player.currentTime().seconds
        return time.isFinite ? time : elapsed
    }

    func toggleFavorite() {
        guard let current, let track = fetchTrack(current.trackID) else { return }
        track.isFavorite.toggle()
        isCurrentFavorite = track.isFavorite
        try? modelContext?.save()
        MPRemoteCommandCenter.shared().likeCommand.isActive = track.isFavorite
        publishSharedState(force: true)
    }

    // MARK: - 내부: 곡 불러오기

    private func loadCurrent(play: Bool, seekTo: Double = 0, cloudChecked: Bool = false) {
        guard let item = current else { return }
        // 클라우드에만 있는 곡이면 받아진 다음에 튼다(그동안 곡 정보는 먼저 보여 준다).
        if !cloudChecked, CloudFiles.isExternal(item.fileURL), !CloudFiles.isDownloaded(item.fileURL) {
            player.removeAllItems()
            preloadedItem = nil
            elapsed = seekTo
            lastTime = seekTo
            listened = 0
            itemDuration = item.duration
            isPlaying = play
            trackDidChange()
            let uid = item.uid
            Task { [weak self] in
                await CloudFiles.ensureDownloaded(item.fileURL)
                guard let self, self.current?.uid == uid else { return }
                self.loadCurrent(play: self.isPlaying, seekTo: seekTo, cloudChecked: true)
            }
            return
        }
        player.removeAllItems()
        let playerItem = Self.makeItem(item.fileURL)
        currentItem = playerItem
        player.insert(playerItem, after: nil)
        preloadedItem = nil
        refreshPreload()

        elapsed = seekTo
        lastTime = seekTo
        listened = 0
        itemDuration = item.duration
        if seekTo > 0 {
            player.seek(to: CMTime(seconds: seekTo, preferredTimescale: 600))
        }
        if play {
            try? AVAudioSession.sharedInstance().setActive(true)
            refreshOutputLatency()
            player.play()
            isPlaying = true
        } else {
            isPlaying = false
        }
        trackDidChange()
    }

    /// 다음 곡을 미리 넣어 두면 곡 사이가 거의 끊기지 않는다.
    private func refreshPreload() {
        if let preloadedItem, player.items().contains(preloadedItem) {
            player.remove(preloadedItem)
        }
        preloadedItem = nil
        guard repeatMode != .one, let nextItem = nextQueueItem() else { return }
        // 다음 곡이 아직 클라우드에만 있으면 미리 받기 시작하고, 받아진 뒤에 다시 넣는다.
        if CloudFiles.isExternal(nextItem.fileURL), !CloudFiles.isDownloaded(nextItem.fileURL) {
            let uid = nextItem.uid
            Task { [weak self] in
                await CloudFiles.ensureDownloaded(nextItem.fileURL)
                guard let self, self.nextQueueItem()?.uid == uid else { return }
                self.refreshPreload()
            }
            return
        }
        let item = Self.makeItem(nextItem.fileURL)
        if player.canInsert(item, after: player.items().last) {
            player.insert(item, after: player.items().last)
            preloadedItem = item
        }
        // 다음 곡이 바뀌었으면 위젯에도 알려 준다.
        publishSharedState(force: false)
    }

    private func nextQueueItem() -> QueueItem? {
        if index + 1 < queue.count { return queue[index + 1] }
        if repeatMode == .all, let first = queue.first { return first }
        return nil
    }

    private func itemDidFinish(_ finished: AVPlayerItem) {
        guard finished === currentItem else { return }
        if sleepAtTrackEnd {
            // "이 곡이 끝나면" 타이머: 다음 곡으로 넘기되 멈춘 상태로 둔다.
            sleepAtTrackEnd = false
            commitListening()
            if index + 1 < queue.count {
                moveToHistory(queue[index])
                index += 1
            }
            player.volume = 1
            loadCurrent(play: false)
            publishSharedState(force: true)
            return
        }
        commitListening()
        if repeatMode == .one {
            player.removeAllItems()
            loadCurrent(play: true)
            return
        }
        if index + 1 < queue.count {
            moveToHistory(queue[index])
            index += 1
        } else if repeatMode == .all {
            moveToHistory(queue[index])
            index = 0
        } else if appendAutoplay() {
            moveToHistory(queue[index])
            index += 1
            loadCurrent(play: true)
            return
        } else {
            isPlaying = false
            elapsed = 0
            player.removeAllItems()
            currentItem = nil
            updateNowPlayingInfo()
            publishSharedState(force: true)
            saveState()
            return
        }

        // 미리 넣어 둔 곡이 이어서 재생되고 있으면 그대로 쓴다.
        if let preloadedItem, player.currentItem === preloadedItem {
            currentItem = preloadedItem
            self.preloadedItem = nil
            elapsed = 0
            lastTime = 0
            listened = 0
            itemDuration = current?.duration ?? 0
            refreshPreload()
            trackDidChange()
        } else {
            loadCurrent(play: true)
        }
    }

    private func moveToHistory(_ item: QueueItem) {
        history.append(item)
        if history.count > 100 { history.removeFirst(history.count - 100) }
    }

    private func applyShuffle() {
        guard let current else { saveState(); return }
        if shuffle {
            let rest = queue.enumerated().filter { $0.offset != index }.map(\.element).shuffled()
            queue = [current] + rest
            index = 0
        } else {
            let order = originalOrder.isEmpty ? queue : originalOrder
            if let i = order.firstIndex(where: { $0.uid == current.uid }) {
                queue = order
                index = i
            }
        }
        refreshPreload()
        saveState()
    }

    /// 대기열은 그대로 두고 셔플 표시만 바꾼다.
    private func shuffleWithoutDidSet(_ value: Bool) {
        suppressShuffleReorder = true
        shuffle = value
        suppressShuffleReorder = false
    }

    /// 대기열이 끝나면 같은 아티스트나 장르의 곡을 골라 이어서 튼다.
    private func appendAutoplay() -> Bool {
        guard UserDefaults.standard.object(forKey: SettingsKey.autoplay) as? Bool ?? true,
              let modelContext, let current else { return false }
        let all = (try? modelContext.fetch(FetchDescriptor<Track>())) ?? []
        let recent = Set((history.suffix(50) + queue).map(\.trackID))
        // 방금 들은 곡들과 느낌이 비슷한 곡을 고른다(장르 · 아티스트 · 연도 · 커버 색 · 같이 들은 기록).
        let events = (try? modelContext.fetch(FetchDescriptor<PlayEvent>())) ?? []
        let model = MixMaker.model(tracks: all, events: events)
        let seeds = [current.trackID] + history.suffix(5).map(\.trackID)
        var candidates = model.similar(to: seeds, from: all, limit: 40, excluding: recent)
        if candidates.count < 5 { candidates = all.filter { !recent.contains($0.id) } }
        let picked = Array(candidates.prefix(40)).shuffled().prefix(20).map(QueueItem.init)
        guard !picked.isEmpty else { return false }
        queue.append(contentsOf: picked)
        originalOrder.append(contentsOf: picked)
        return true
    }

    private func trackDidChange() {
        guard let current else { return }
        let track = fetchTrack(current.trackID)
        isCurrentFavorite = track?.isFavorite ?? false
        MPRemoteCommandCenter.shared().likeCommand.isActive = isCurrentFavorite
        if let album = track?.album {
            currentPalette = PaletteCodec.decode(album.paletteHex)
            currentColor = Color(hex: album.colorHex)
        } else {
            currentPalette = []
            currentColor = Color(.systemGray3)
        }
        updateNowPlayingInfo()
        publishSharedState(force: true)
        saveState()
    }

    // MARK: - 재생 기록

    private func commitListening() {
        guard let current, listened >= 30, let modelContext else { listened = 0; return }
        let now = Date()
        let event = PlayEvent(
            trackID: current.trackID, date: now, seconds: listened, trackTitle: current.title,
            artistName: current.artist, albumTitle: current.album, albumArtistName: current.albumArtist,
            genre: current.genre, artworkFile: current.artworkFile
        )
        modelContext.insert(event)
        if let track = fetchTrack(current.trackID) {
            track.playCount += 1
            track.lastPlayedAt = now
            track.album?.lastPlayedAt = now
            track.artist?.lastPlayedAt = now
        }
        if case .playlist(let id) = context {
            var descriptor = FetchDescriptor<Playlist>(predicate: #Predicate { $0.id == id })
            descriptor.fetchLimit = 1
            if let playlist = (try? modelContext.fetch(descriptor))?.first {
                playlist.lastPlayedAt = now
            }
        }
        try? modelContext.save()
        listened = 0
    }

    private func fetchTrack(_ id: UUID) -> Track? {
        var descriptor = FetchDescriptor<Track>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        return try? modelContext?.fetch(descriptor).first
    }

    // MARK: - 시간

    private func addTimeObserver() {
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.25, preferredTimescale: 600), queue: .main) { [weak self] time in
            MainActor.assumeIsolated {
                self?.tick(time.seconds)
            }
        }
    }

    private func tick(_ seconds: Double) {
        guard seconds.isFinite else { return }
        let delta = seconds - lastTime
        if isPlaying, delta > 0, delta < 1.5 {
            listened += delta
            consecutiveFailures = 0
        }
        lastTime = seconds
        elapsed = seconds
        if let item = player.currentItem, item.duration.seconds.isFinite, item.duration.seconds > 0 {
            itemDuration = item.duration.seconds
        }
        if isPlaying { updateSleepTimer(at: seconds) }
        if Date().timeIntervalSince(lastStateSave) > 10 { saveState() }
    }

    // MARK: - 오디오 세션 · 알림

    private func configureAudioSession() {
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .default, policy: .longFormAudio)
    }

    private func observeNotifications() {
        let center = NotificationCenter.default
        center.addObserver(forName: AVPlayerItem.didPlayToEndTimeNotification, object: nil, queue: .main) { [weak self] note in
            guard let item = note.object as? AVPlayerItem else { return }
            MainActor.assumeIsolated { self?.itemDidFinish(item) }
        }
        center.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] note in
            let info = note.userInfo
            MainActor.assumeIsolated { self?.handleInterruption(info) }
        }
        center.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) { [weak self] note in
            let reason = (note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt).flatMap(AVAudioSession.RouteChangeReason.init)
            MainActor.assumeIsolated {
                if reason == .oldDeviceUnavailable { self?.pause() }
                self?.refreshOutputLatency()
            }
        }
        center.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.saveState() }
        }
    }

    private func handleInterruption(_ info: [AnyHashable: Any]?) {
        guard let raw = info?[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
        switch type {
        case .began:
            wasPlayingBeforeInterruption = isPlaying
            isPlaying = false
            updateNowPlayingInfo()
        case .ended:
            let options = (info?[AVAudioSessionInterruptionOptionKey] as? UInt).map(AVAudioSession.InterruptionOptions.init) ?? []
            if wasPlayingBeforeInterruption, options.contains(.shouldResume) { resume() }
        @unknown default:
            break
        }
    }

    // MARK: - 잠금화면 · 제어 센터

    private func configureRemoteCommands() {
        let center = MPRemoteCommandCenter.shared()
        center.playCommand.addTarget { [weak self] _ in
            MainActor.assumeIsolated { self?.resume() }
            return .success
        }
        center.pauseCommand.addTarget { [weak self] _ in
            MainActor.assumeIsolated { self?.pause() }
            return .success
        }
        center.togglePlayPauseCommand.addTarget { [weak self] _ in
            MainActor.assumeIsolated { self?.togglePlayPause() }
            return .success
        }
        center.nextTrackCommand.addTarget { [weak self] _ in
            MainActor.assumeIsolated { self?.next() }
            return .success
        }
        center.previousTrackCommand.addTarget { [weak self] _ in
            MainActor.assumeIsolated { self?.previous() }
            return .success
        }
        center.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let event = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            let position = event.positionTime
            MainActor.assumeIsolated { self?.seek(to: position) }
            return .success
        }
        center.likeCommand.localizedTitle = "좋아요"
        center.likeCommand.addTarget { [weak self] _ in
            MainActor.assumeIsolated { self?.toggleFavorite() }
            return .success
        }
    }

    private func updateNowPlayingInfo() {
        guard let current else {
            MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
            return
        }
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: current.title,
            MPMediaItemPropertyArtist: current.artist,
            MPMediaItemPropertyAlbumTitle: current.album,
            MPMediaItemPropertyPlaybackDuration: duration,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: elapsed,
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? 1.0 : 0.0,
            MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.audio.rawValue
        ]
        if let image = ArtworkStore.image(current.artworkFile) {
            info[MPMediaItemPropertyArtwork] = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
        }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
        MPNowPlayingInfoCenter.default().playbackState = isPlaying ? .playing : .paused
    }

    // MARK: - 위젯 공유

    @ObservationIgnored private var lastPublished: SharedPlaybackState?

    private func publishSharedState(force: Bool) {
        let state: SharedPlaybackState
        if let current {
            state = SharedPlaybackState(
                title: current.title, artist: current.artist, album: current.album,
                artworkFile: current.artworkFile, isPlaying: isPlaying, elapsed: elapsed,
                duration: duration, updatedAt: .now, recent: recentAlbums(),
                isFavorite: isCurrentFavorite,
                palette: sharedPalette(),
                upNext: upNextForWidget()
            )
        } else {
            state = .empty
        }
        guard force || state.title != lastPublished?.title || state.isPlaying != lastPublished?.isPlaying
                || state.isFavorite != lastPublished?.isFavorite
                || state.upNext?.first?.id != lastPublished?.upNext?.first?.id else { return }
        state.save()
        let playingChanged = state.isPlaying != lastPublished?.isPlaying
        lastPublished = state
        WidgetCenter.shared.reloadAllTimelines()
        if playingChanged { ControlCenter.shared.reloadControls(ofKind: "com.chltmddn752.tune.playpause") }
    }

    /// 위젯 배경에 쓸 앨범 색
    private func sharedPalette() -> [String] {
        guard let current, let album = fetchTrack(current.trackID)?.album else { return [] }
        var colors: [String] = []
        if let main = album.colorHex { colors.append(main) }
        if let palette = album.paletteHex {
            colors += palette.split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) }
        }
        return Array(colors.prefix(4))
    }

    /// 다음 곡 몇 개 (반복 재생이면 같은 곡)
    private func upNextForWidget() -> [SharedPlaybackState.UpNextItem] {
        let items: [QueueItem]
        if repeatMode == .one, let current {
            items = [current, current, current]
        } else {
            var list = upNext
            if repeatMode == .all, list.count < 3 { list += queue.prefix(3 - list.count) }
            items = Array(list.prefix(3))
        }
        return items.map {
            .init(id: $0.uid.uuidString, title: $0.title, artist: $0.artist, artworkFile: $0.artworkFile, duration: $0.duration)
        }
    }

    private func recentAlbums() -> [SharedPlaybackState.RecentAlbum] {
        guard let modelContext else { return [] }
        var descriptor = FetchDescriptor<Album>(
            predicate: #Predicate { $0.lastPlayedAt != nil },
            sortBy: [SortDescriptor(\Album.lastPlayedAt, order: .reverse)]
        )
        descriptor.fetchLimit = 4
        let albums = (try? modelContext.fetch(descriptor)) ?? []
        return albums.map { .init(id: $0.id.uuidString, title: $0.title, artist: $0.artistName, artworkFile: $0.artworkFile) }
    }

    // MARK: - 상태 저장 · 복원

    private struct SavedState: Codable {
        var queue: [QueueItem]
        var originalOrder: [QueueItem]
        var index: Int
        var elapsed: Double
        var shuffle: Bool
        var repeatMode: RepeatMode
        var context: PlaybackContext
    }

    private var stateURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("player-state.json")
    }

    private func saveState() {
        lastStateSave = .now
        let saved = SavedState(queue: queue, originalOrder: originalOrder, index: index, elapsed: elapsed,
                               shuffle: shuffle, repeatMode: repeatMode, context: context)
        if let data = try? JSONEncoder().encode(saved) {
            try? data.write(to: stateURL, options: .atomic)
        }
    }

    private func restoreState() {
        guard queue.isEmpty,
              let data = try? Data(contentsOf: stateURL),
              let saved = try? JSONDecoder().decode(SavedState.self, from: data) else { return }
        // 지워진 파일은 대기열에서 뺀다(클라우드에만 있는 곡은 남긴다).
        let valid = saved.queue.filter { CloudFiles.exists($0.fileURL) }
        guard !valid.isEmpty else { return }
        let currentUID = saved.queue.indices.contains(saved.index) ? saved.queue[saved.index].uid : nil
        queue = valid
        originalOrder = saved.originalOrder.filter { CloudFiles.exists($0.fileURL) }
        index = valid.firstIndex { $0.uid == currentUID } ?? 0
        shuffleWithoutDidSet(saved.shuffle)
        repeatMode = saved.repeatMode
        context = saved.context
        elapsed = currentUID != nil && valid[index].uid == currentUID ? saved.elapsed : 0
        itemDuration = current?.duration ?? 0
        trackDidChange()
    }
}
