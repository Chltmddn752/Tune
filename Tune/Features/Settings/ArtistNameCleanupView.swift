import SwiftData
import SwiftUI

/// YouTube 채널 이름이 아티스트로 들어온 것을 사용자가 확인하고 바꾸는 화면.
/// 자동으로 데이터를 고치지 않고, 제안을 보여 준 뒤 사용자가 승인할 때만 태그를 바꾼다.
struct ArtistNameCleanupView: View {
    @Environment(\.modelContext) private var modelContext
    @Query private var artists: [Artist]
    @State private var applied: Set<UUID> = []

    private var candidates: [ArtistNameCleaner.Candidate] {
        ArtistNameCleaner.candidates(artists: artists, context: modelContext)
            .filter { !applied.contains($0.artistID) }
    }

    var body: some View {
        List {
            if candidates.isEmpty {
                Text("정리할 아티스트 이름이 없어요.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                Section {
                    ForEach(candidates) { candidate in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(candidate.currentName)
                                .font(.body)
                                .strikethrough()
                                .foregroundStyle(.secondary)
                            HStack(spacing: 6) {
                                Image(systemName: "arrow.right")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Text(candidate.suggestedName)
                                    .font(.body.weight(.semibold))
                            }
                            if let sample = candidate.sampleTitle {
                                Text("곡 제목: \(sample)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                            HStack {
                                Text("\(candidate.trackCount)곡")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Spacer()
                                Button("이 이름으로 바꾸기") {
                                    ArtistNameCleaner.apply(candidate, context: modelContext)
                                    applied.insert(candidate.artistID)
                                }
                                .font(.footnote.weight(.semibold))
                                .buttonStyle(.bordered)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                } footer: {
                    Text("채널 이름이 아티스트 칸에 들어온 것으로 보이는 항목이에요. 바꾸면 그 아티스트의 곡 태그가 새 이름으로 정리돼요. 마음에 들지 않으면 파일 태그는 그대로 두고 넘어가도 돼요.")
                }
            }
        }
        .navigationTitle("아티스트 이름 정리")
        .navigationBarTitleDisplayMode(.inline)
    }
}

@MainActor
enum ArtistNameCleaner {
    struct Candidate: Identifiable, Hashable {
        let artistID: UUID
        let currentName: String
        let suggestedName: String
        let sampleTitle: String?
        let trackCount: Int
        var id: UUID { artistID }
    }

    static func candidates(artists: [Artist], context: ModelContext) -> [Candidate] {
        artists.compactMap { artist in
            guard LibraryText.looksLikeChannel(artist.name) else { return nil }
            let tracks = artist.tracks
            var counts: [String: (name: String, count: Int, sample: String)] = [:]
            for track in tracks {
                if let suggested = LibraryText.suggestedArtist(fromTitle: track.title, fallback: artist.name),
                   !LibraryText.looksLikeChannel(suggested) {
                    counts[suggested.libraryKey, default: (suggested, 0, track.title)].count += 1
                }
            }
            let best = counts.values.max { $0.count < $1.count }
            let cleaned = cleanName(artist.name)
            let suggested = best?.name ?? (cleaned != artist.name ? cleaned : nil)
            guard let suggested, !suggested.isEmpty, suggested.libraryKey != artist.name.libraryKey else { return nil }
            return Candidate(
                artistID: artist.id,
                currentName: artist.name,
                suggestedName: suggested.nfc,
                sampleTitle: best?.sample,
                trackCount: tracks.count
            )
        }
        .sorted { $0.currentName.localizedStandardCompare($1.currentName) == .orderedAscending }
    }

    private static func cleanName(_ raw: String) -> String {
        var value = raw.nfc
        let suffixes = [" - Topic", " Official Channel", " OFFICIAL", " official", " Official", " (Official Channel)"]
        for suffix in suffixes where value.hasSuffix(suffix) {
            value = String(value.dropLast(suffix.count))
        }
        value = value.replacingOccurrences(of: #"【[^】]*】"#, with: " ", options: .regularExpression)
        value = value.replacingOccurrences(of: #"\s*\(CV:?[^)]*\)"#, with: " ", options: [.regularExpression, .caseInsensitive])
        value = value.replacingOccurrences(of: #"\s*-\s*Viral Songs\s*$"#, with: "", options: [.regularExpression, .caseInsensitive])
        value = value.split(whereSeparator: \.isWhitespace).joined(separator: " ")
            .trimmingCharacters(in: CharacterSet(charactersIn: " -–—|"))
        return value
    }

    /// 승인된 이름으로 아티스트와 곡 태그를 바꾼다. 같은 이름의 아티스트가 이미 있으면 합친다.
    static func apply(_ candidate: Candidate, context: ModelContext) {
        let artistID = candidate.artistID
        var descriptor = FetchDescriptor<Artist>(predicate: #Predicate { $0.id == artistID })
        descriptor.fetchLimit = 1
        guard let artist = (try? context.fetch(descriptor))?.first else { return }
        let newName = candidate.suggestedName.nfc
        let newKey = newName.libraryKey
        let oldName = artist.name

        var existingDescriptor = FetchDescriptor<Artist>(predicate: #Predicate { $0.key == newKey })
        existingDescriptor.fetchLimit = 1
        let existing = (try? context.fetch(existingDescriptor))?.first

        if let existing, existing.id != artist.id {
            for track in artist.tracks { track.artist = existing }
            for album in artist.albums { album.artist = existing }
            if existing.imageFile == nil { existing.imageFile = artist.imageFile }
            if existing.deezerArtistID == nil { existing.deezerArtistID = artist.deezerArtistID }
            existing.isPinned = existing.isPinned || artist.isPinned
            context.delete(artist)
        } else {
            artist.name = newName
            artist.key = newKey
        }

        let tracks = (try? context.fetch(FetchDescriptor<Track>())) ?? []
        for track in tracks {
            if track.artistName.libraryKey == oldName.libraryKey {
                track.artistName = newName
            } else if NameSplitter.contains(track.artistName, artist: oldName) {
                track.artistName = NameSplitter.artists(track.artistName)
                    .map { $0.libraryKey == oldName.libraryKey ? newName : $0 }
                    .joined(separator: ", ")
            }
            if track.albumArtistName.libraryKey == oldName.libraryKey {
                track.albumArtistName = newName
            }
        }
        for album in (try? context.fetch(FetchDescriptor<Album>())) ?? [] {
            if album.artistName.libraryKey == oldName.libraryKey { album.artistName = newName }
        }
        try? context.save()
    }
}
