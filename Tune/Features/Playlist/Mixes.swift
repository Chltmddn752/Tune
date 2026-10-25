import SwiftData
import SwiftUI

// MARK: - 비슷한 곡 찾기

/// 곡끼리 얼마나 비슷한지 점수를 매긴다.
/// 장르(가장 큼) · 같은 아티스트 · 비슷한 연도 · 커버 색감 · 내가 같이 이어 들은 기록을 섞어서 본다.
struct SimilarityModel {
    struct Features {
        let genres: Set<String>
        let artists: Set<String>
        let year: Int?
        let hue: Double?
        let saturation: Double
    }

    private(set) var features: [UUID: Features] = [:]
    /// 같은 자리(30분 안 이어 듣기)에서 함께 들은 횟수
    private var together: [UUID: [UUID: Double]] = [:]

    init(tracks: [Track], events: [PlayEvent]) {
        for track in tracks {
            let color = track.album?.colorHex.flatMap(Self.hsb)
            features[track.id] = Features(
                genres: Set(NameSplitter.genres(track.genre.isEmpty ? (track.album?.genre ?? "") : track.genre).map { $0.lowercased() }),
                artists: Set((NameSplitter.artists(track.artistName) + NameSplitter.artists(track.albumArtistName)).map { $0.lowercased() }),
                year: track.year ?? track.album?.year,
                hue: color?.hue,
                saturation: color?.saturation ?? 0
            )
        }
        // 재생 기록을 "한 번 듣는 자리"로 나누고, 가까이 이어 들은 곡끼리 묶는다.
        let sorted = events.sorted { $0.date < $1.date }
        var session: [UUID] = []
        var last = Date.distantPast
        func flush() {
            for i in session.indices {
                for j in (i + 1)..<min(i + 4, session.count) where session[i] != session[j] {
                    together[session[i], default: [:]][session[j], default: 0] += 1
                    together[session[j], default: [:]][session[i], default: 0] += 1
                }
            }
            session.removeAll()
        }
        for event in sorted {
            if event.date.timeIntervalSince(last) > 30 * 60 { flush() }
            session.append(event.trackID)
            last = event.date
        }
        flush()
    }

    func score(_ a: UUID, _ b: UUID) -> Double {
        guard a != b, let fa = features[a], let fb = features[b] else { return 0 }
        var score = 0.0
        if !fa.genres.isEmpty, !fb.genres.isEmpty {
            score += 3 * Double(fa.genres.intersection(fb.genres).count) / Double(fa.genres.union(fb.genres).count)
        }
        if !fa.artists.isDisjoint(with: fb.artists) { score += 1.6 }
        if let ya = fa.year, let yb = fb.year { score += max(0, 1 - Double(abs(ya - yb)) / 8) }
        if let ha = fa.hue, let hb = fb.hue, fa.saturation > 0.15, fb.saturation > 0.15 {
            let d = min(abs(ha - hb), 1 - abs(ha - hb))
            score += 0.6 * max(0, 1 - d * 5)
        }
        if let n = together[a]?[b] { score += 2 * min(n / 3, 1) }
        return score
    }

    /// 여러 곡과 평균적으로 가장 비슷한 곡들
    func similar(to seeds: [UUID], from candidates: [Track], limit: Int, excluding: Set<UUID> = []) -> [Track] {
        guard !seeds.isEmpty else { return [] }
        let seedSet = Set(seeds)
        var scored: [(track: Track, score: Double)] = []
        for track in candidates where !seedSet.contains(track.id) && !excluding.contains(track.id) {
            var total = 0.0
            for seed in seeds { total += score(seed, track.id) }
            let average = total / Double(seeds.count)
            if average > 0.6 { scored.append((track, average)) }
        }
        scored.sort { $0.score > $1.score }
        return scored.prefix(limit).map { $0.track }
    }

    private static func hsb(_ hex: String) -> (hue: Double, saturation: Double)? {
        let cleaned = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        guard cleaned.count == 6, let value = Int(cleaned, radix: 16) else { return nil }
        let r = Double((value >> 16) & 0xFF) / 255, g = Double((value >> 8) & 0xFF) / 255, b = Double(value & 0xFF) / 255
        let maxV = max(r, g, b), minV = min(r, g, b), delta = maxV - minV
        guard delta > 0 else { return (0, 0) }
        var hue: Double
        if maxV == r { hue = (g - b) / delta } else if maxV == g { hue = 2 + (b - r) / delta } else { hue = 4 + (r - g) / delta }
        hue /= 6
        if hue < 0 { hue += 1 }
        return (hue, maxV == 0 ? 0 : delta / maxV)
    }
}

// MARK: - 자동 믹스

struct Mix: Identifiable, Hashable {
    let id: String
    let title: String
    let subtitle: String
    let symbol: String
    let trackIDs: [UUID]
}

/// 같은 날에는 같은 순서가 나오도록 날짜로 정한 난수
struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64
    init(seed: String) {
        var hash: UInt64 = 1469598103934665603
        for byte in seed.utf8 { hash = (hash ^ UInt64(byte)) &* 1099511628211 }
        state = hash
    }
    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
}

@MainActor
enum MixMaker {
    static let mixLength = 25

    /// 오늘의 자동 믹스들. refresh를 바꾸면 다른 조합이 나온다.
    // 화면이 다시 그려질 때마다 다시 계산하지 않게 기억해 둔다.
    // (재생 기록은 곡을 들을 때마다 늘어나므로 25개 단위로만 새로 계산)
    private static var cachedModel: (key: String, model: SimilarityModel)?
    private static var cachedMixes: (key: String, mixes: [Mix])?

    static func model(tracks: [Track], events: [PlayEvent]) -> SimilarityModel {
        let key = "\(tracks.count)-\(events.count / 25)"
        if let cachedModel, cachedModel.key == key { return cachedModel.model }
        let model = SimilarityModel(tracks: tracks, events: events)
        cachedModel = (key, model)
        return model
    }

    static func mixes(tracks: [Track], events: [PlayEvent], refresh: Int = 0) -> [Mix] {
        let day = Calendar.current.ordinality(of: .day, in: .era, for: .now) ?? 0
        let key = "\(tracks.count)-\(events.count / 25)-\(day)-\(refresh)"
        if let cachedMixes, cachedMixes.key == key { return cachedMixes.mixes }
        let result = makeMixes(tracks: tracks, events: events, refresh: refresh)
        cachedMixes = (key, result)
        return result
    }

    private static func makeMixes(tracks: [Track], events: [PlayEvent], refresh: Int) -> [Mix] {
        guard tracks.count >= 8 else { return [] }
        let model = Self.model(tracks: tracks, events: events)
        let byID = Dictionary(tracks.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let day = Calendar.current.ordinality(of: .day, in: .era, for: .now) ?? 0
        var result: [Mix] = []

        func finish(_ id: String, _ title: String, _ subtitle: String, _ symbol: String, _ picked: [Track]) {
            var generator = SeededGenerator(seed: "\(id)-\(day)-\(refresh)")
            let ids = Array(picked.prefix(mixLength * 2)).shuffled(using: &generator).prefix(mixLength).map(\.id)
            if ids.count >= 6 { result.append(Mix(id: id, title: title, subtitle: subtitle, symbol: symbol, trackIDs: Array(ids))) }
        }

        // 1. 요즘 듣는 느낌: 최근에 들은 곡과 비슷하지만 최근엔 안 들은 곡
        let recentIDs = Array(NSOrderedSet(array: events.sorted { $0.date > $1.date }.map(\.trackID)).array as? [UUID] ?? [])
            .filter { byID[$0] != nil }
        let recentSeeds = Array(recentIDs.prefix(15))
        if recentSeeds.count >= 3 {
            let picked = model.similar(to: recentSeeds, from: tracks, limit: mixLength * 2, excluding: Set(recentIDs.prefix(40)))
            finish("recent", "요즘 듣는 느낌", "최근에 들은 곡과 비슷한 곡", "waveform", picked + recentSeeds.prefix(5).compactMap { byID[$0] })
        }

        // 2. 장르별 믹스: 많이 듣는(없으면 많이 가진) 장르마다
        var genreWeight: [String: (name: String, weight: Double)] = [:]
        for track in tracks {
            for name in NameSplitter.genres(track.genre) {
                genreWeight[name.lowercased(), default: (name: name, weight: 0)].weight += 1 + Double(track.playCount) * 2
            }
        }
        let topGenres = genreWeight.values.sorted { $0.weight > $1.weight }.prefix(4)
        for (index, genre) in topGenres.enumerated() {
            let inGenre = tracks.filter { NameSplitter.contains($0.genre, genre: genre.name) }
            guard inGenre.count >= 4 else { continue }
            let core = inGenre.sorted { ($0.playCount, $0.isFavorite ? 1 : 0) > ($1.playCount, $1.isFavorite ? 1 : 0) }.prefix(20)
            let neighbors = model.similar(to: core.prefix(8).map(\.id), from: tracks, limit: 12,
                                          excluding: Set(inGenre.map(\.id)))
            let artists = Array(NSOrderedSet(array: core.map { NameSplitter.primaryArtist($0.artistName) }).array as? [String] ?? [])
            finish("genre-\(genre.name.lowercased())", "\(genre.name) 믹스", artists.prefix(3).joined(separator: ", "),
                   ["guitars", "music.quarternote.3", "pianokeys", "headphones"][index % 4], Array(core) + neighbors)
        }

        // 3. 아티스트 믹스: 많이 들은 아티스트 + 그 느낌의 다른 아티스트
        var artistPlays: [String: (name: String, count: Int)] = [:]
        for event in events {
            for name in NameSplitter.artists(event.artistName) { artistPlays[name.lowercased(), default: (name: name, count: 0)].count += 1 }
        }
        for artist in artistPlays.values.sorted(by: { $0.count > $1.count }).prefix(3) where artist.count >= 3 {
            let own = tracks.filter { NameSplitter.contains($0.artistName, artist: artist.name) }
            guard !own.isEmpty else { continue }
            let others = model.similar(to: own.prefix(10).map(\.id), from: tracks, limit: 16, excluding: Set(own.map(\.id)))
            finish("artist-\(artist.name.lowercased())", "\(artist.name) 믹스", "\(artist.name)와(과) 비슷한 느낌", "music.mic",
                   Array(own.shuffled().prefix(10)) + others)
        }

        // 4. 좋아요한 곡과 비슷한 곡
        let favorites = tracks.filter(\.isFavorite)
        if favorites.count >= 3 {
            let picked = model.similar(to: favorites.prefix(20).map(\.id), from: tracks, limit: mixLength * 2,
                                       excluding: Set(favorites.map(\.id)))
            finish("favorites", "좋아요와 비슷한 곡", "좋아요 표시한 곡의 느낌으로", "star", picked)
        }

        // 5. 다시 발견: 오래 안 들었지만 내 취향에 가까운 곡
        let cutoff = Date().addingTimeInterval(-45 * 86_400)
        let forgotten = tracks.filter { ($0.lastPlayedAt ?? .distantPast) < cutoff }
        let tasteSeeds = tracks.sorted { $0.playCount > $1.playCount }.prefix(15).filter { $0.playCount > 0 }.map(\.id)
        if forgotten.count >= 6 {
            let picked = tasteSeeds.isEmpty ? forgotten : model.similar(to: tasteSeeds, from: forgotten, limit: mixLength * 2)
            finish("rediscover", "다시 발견", "한동안 안 들은 취향 저격 곡", "sparkles", picked.count >= 6 ? picked : forgotten)
        }

        return result
    }

    /// 곡 하나로 시작하는 믹스
    static func mix(startingWith seed: Track, tracks: [Track], events: [PlayEvent], refresh: Int = 0) -> Mix {
        let model = Self.model(tracks: tracks, events: events)
        var generator = SeededGenerator(seed: "track-\(seed.id)-\(refresh)")
        let similar = model.similar(to: [seed.id], from: tracks, limit: mixLength * 2)
        let ids = [seed.id] + similar.prefix(mixLength + 8).shuffled(using: &generator).prefix(mixLength - 1).map(\.id)
        return Mix(id: "track:\(seed.id.uuidString)", title: "\(seed.title) 믹스", subtitle: "이 곡과 비슷한 느낌",
                   symbol: "dot.radiowaves.left.and.right", trackIDs: ids)
    }
}

// MARK: - 화면

/// 플레이리스트 목록 위에 들어가는 "자동 플레이리스트" 줄
struct AutoMixShelf: View {
    @Query private var tracks: [Track]
    @Query private var events: [PlayEvent]
    @Environment(\.horizontalSizeClass) private var sizeClass

    var body: some View {
        let mixes = MixMaker.mixes(tracks: tracks, events: events)
        if !mixes.isEmpty {
            VStack(alignment: .leading, spacing: Spacing.s) {
                HStack(alignment: .firstTextBaseline) {
                    Text("나를 위한 믹스").font(.tuneSection)
                    Spacer()
                    Text("매일 새로 섞여요").font(.caption).foregroundStyle(.secondary)
                }
                ScrollView(.horizontal) {
                    LazyHStack(alignment: .top, spacing: Spacing.m) {
                        ForEach(mixes) { mix in
                            NavigationLink(value: Route.mix(mix.id)) {
                                MixCard(mix: mix, width: sizeClass == .regular ? 170 : 150)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.vertical, 2)
                }
                .scrollIndicators(.hidden)
                .scrollClipDisabled()
            }
        }
    }
}

struct MixCard: View {
    let mix: Mix
    let width: CGFloat

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            MixCover(mix: mix)
                .frame(width: width, height: width)
            Text(mix.title).font(.subheadline.weight(.semibold)).lineLimit(1)
            Text(mix.subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
        }
        .frame(width: width, alignment: .leading)
    }
}

/// 믹스 커버: 들어 있는 곡 커버 4장 + 앨범 색 그라데이션 + 이름
struct MixCover: View {
    let mix: Mix
    @Query private var tracks: [Track]

    init(mix: Mix) {
        self.mix = mix
        let ids = Array(mix.trackIDs.prefix(12))
        _tracks = Query(filter: #Predicate<Track> { ids.contains($0.id) })
    }

    var body: some View {
        let files = Array(NSOrderedSet(array: tracks.compactMap(\.artworkFile)).array as? [String] ?? []).prefix(4)
        let tint = Color(hex: tracks.first?.album?.colorHex, fallback: Color.tuneAccent)
        ZStack(alignment: .bottomLeading) {
            if files.count >= 4 {
                Grid(horizontalSpacing: 0, verticalSpacing: 0) {
                    GridRow { ArtworkView(file: files[0], cornerRadius: 0); ArtworkView(file: files[1], cornerRadius: 0) }
                    GridRow { ArtworkView(file: files[2], cornerRadius: 0); ArtworkView(file: files[3], cornerRadius: 0) }
                }
            } else if let first = files.first {
                ArtworkView(file: first, cornerRadius: 0)
            } else {
                tint
            }
            LinearGradient(colors: [tint.opacity(0.1), tint.opacity(0.85)], startPoint: .top, endPoint: .bottom)
            VStack(alignment: .leading, spacing: 4) {
                Image(systemName: mix.symbol).font(.headline)
                Text(mix.title).font(.headline.weight(.bold)).lineLimit(2)
            }
            .foregroundStyle(.white)
            .shadow(color: .black.opacity(0.3), radius: 6)
            .padding(10)
        }
        .aspectRatio(1, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
    }
}

/// 믹스 하나 보기: 재생 · 셔플 · 다시 섞기 · 플레이리스트로 저장
struct MixScreen: View {
    let mixID: String
    @Query private var tracks: [Track]
    @Query private var events: [PlayEvent]
    @Environment(PlayerEngine.self) private var player
    @Environment(Router.self) private var router
    @Environment(\.modelContext) private var modelContext
    @Environment(\.horizontalSizeClass) private var sizeClass
    @State private var refresh = 0
    @State private var savedName: String?

    var body: some View {
        let mix = currentMix
        let byID = Dictionary(tracks.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let list = mix?.trackIDs.compactMap { byID[$0] } ?? []

        Group {
            if let mix, !list.isEmpty {
                List {
                    VStack(spacing: Spacing.l) {
                        MixCover(mix: mix)
                            .frame(maxWidth: sizeClass == .regular ? 260 : 220)
                            .shadow(color: .black.opacity(0.2), radius: 16, y: 8)
                        VStack(spacing: 4) {
                            Text(mix.title).font(.title2.weight(.bold)).multilineTextAlignment(.center)
                            Text("\(mix.subtitle) · \(list.count)곡").font(.subheadline).foregroundStyle(.secondary)
                        }
                        PlayShuffleButtons {
                            player.play(list)
                        } onShuffle: {
                            player.play(list, shuffled: true)
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .listRowSeparator(.hidden)
                    .padding(.vertical, Spacing.m)

                    ForEach(list) { TrackRow(track: $0, queue: list) }
                }
                .listStyle(.plain)
                .toolbar {
                    ToolbarItemGroup(placement: .topBarTrailing) {
                        Button {
                            withAnimation(.smooth) { refresh += 1 }
                        } label: { Image(systemName: "arrow.triangle.2.circlepath") }
                        .accessibilityLabel("다시 섞기")
                        Button {
                            save(mix, tracks: list)
                        } label: { Image(systemName: "plus.rectangle.on.rectangle") }
                        .accessibilityLabel("플레이리스트로 저장")
                    }
                }
                .navigationTitle(mix.title)
                .navigationBarTitleDisplayMode(.inline)
            } else {
                ContentUnavailableView("믹스를 만들 곡이 부족해요", systemImage: "music.note.list",
                                       description: Text("곡이 더 쌓이거나 더 들으면 믹스가 생겨요."))
            }
        }
        .alert("플레이리스트로 저장했어요", isPresented: Binding(get: { savedName != nil }, set: { if !$0 { savedName = nil } })) {
            Button("확인", role: .cancel) {}
        } message: {
            Text(savedName ?? "")
        }
    }

    private var currentMix: Mix? {
        if mixID.hasPrefix("track:"), let uuid = UUID(uuidString: String(mixID.dropFirst(6))),
           let seed = tracks.first(where: { $0.id == uuid }) {
            return MixMaker.mix(startingWith: seed, tracks: tracks, events: events, refresh: refresh)
        }
        return MixMaker.mixes(tracks: tracks, events: events, refresh: refresh).first { $0.id == mixID }
    }

    private func save(_ mix: Mix, tracks: [Track]) {
        let formatter = DateFormatter()
        formatter.dateFormat = "M월 d일"
        let playlist = Playlist(name: "\(mix.title) (\(formatter.string(from: .now)))", detail: mix.subtitle)
        modelContext.insert(playlist)
        for (order, track) in tracks.enumerated() {
            let entry = PlaylistEntry(order: order, trackID: track.id)
            modelContext.insert(entry)
            entry.playlist = playlist
        }
        try? modelContext.save()
        savedName = playlist.name
    }
}
