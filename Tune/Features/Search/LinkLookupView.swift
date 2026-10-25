import SwiftData
import SwiftUI

/// 링크로 찾기: Spotify · Apple Music · YouTube 링크를 붙여 넣으면
/// ① 내 보관함에 있으면 바로 재생, ② 없으면 공식으로 듣거나 살 수 있는 곳과 "사고 싶은 곡"에 담기를 보여 준다.
struct LinkLookupView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Environment(PlayerEngine.self) private var player
    @Environment(\.openURL) private var openURL
    @Query private var tracks: [Track]
    @Query private var wishes: [WishItem]

    @State private var link = ""
    @State private var candidates: [CatalogItem] = []
    @State private var isLoading = false
    @State private var errorText: String?
    @State private var addedMessage: String?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack {
                        TextField("https://open.spotify.com/track/…", text: $link)
                            .keyboardType(.URL)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .onSubmit { Task { await lookUp() } }
                        Button {
                            if let pasted = UIPasteboard.general.string { link = pasted }
                            Task { await lookUp() }
                        } label: {
                            Label("붙여넣기", systemImage: "doc.on.clipboard").labelStyle(.iconOnly)
                        }
                        .buttonStyle(.borderless)
                        .accessibilityLabel("붙여넣고 찾기")
                    }
                    Button {
                        Task { await lookUp() }
                    } label: {
                        if isLoading { ProgressView() } else { Text("찾기") }
                    }
                    .disabled(link.isEmpty || isLoading)
                } footer: {
                    Text("곡 정보는 Spotify·YouTube의 공개 미리보기(oEmbed)와 Apple iTunes 검색으로 알아봐요. 음원 파일은 받지 않아요.")
                }

                if let errorText {
                    Section { Text(errorText).foregroundStyle(.secondary) }
                }

                if let best = candidates.first {
                    Section("가장 비슷한 곡") {
                        CandidateRow(item: best, owned: owned(best), wished: wished(best))
                    }
                    resultActions(for: best)
                    if candidates.count > 1 {
                        Section("다른 후보") {
                            ForEach(candidates.dropFirst()) { item in
                                Button {
                                    // 고른 후보를 맨 위로
                                    candidates.removeAll { $0.id == item.id }
                                    candidates.insert(item, at: 0)
                                } label: {
                                    CandidateRow(item: item, owned: owned(item), wished: wished(item))
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }
            }
            .navigationTitle("링크로 찾기")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("완료") { dismiss() } }
            }
            .overlay(alignment: .bottom) {
                if let addedMessage {
                    Text(addedMessage)
                        .font(.subheadline.weight(.medium))
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .glassEffect()
                        .padding(.bottom, 20)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .animation(.smooth, value: addedMessage)
        }
    }

    @ViewBuilder
    private func resultActions(for item: CatalogItem) -> some View {
        if let track = owned(item) {
            Section {
                Button {
                    player.play([track])
                    dismiss()
                } label: {
                    Label("내 보관함에 있어요 · 재생", systemImage: "play.fill")
                }
            }
        } else {
            Section {
                if wished(item) {
                    Label("사고 싶은 곡에 담겨 있어요", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.secondary)
                } else {
                    Button {
                        modelContext.insert(WishItem(item))
                        try? modelContext.save()
                        flash("사고 싶은 곡에 담았어요")
                    } label: {
                        Label("사고 싶은 곡에 담기", systemImage: "heart.text.square")
                    }
                }
            } footer: {
                Text("나중에 같은 곡을 보관함에 넣으면 목록에서 알아서 빠져요.")
            }
            Section("듣거나 사기") {
                ForEach(CatalogLookup.storeLinks(for: item)) { store in
                    Button {
                        openURL(store.url)
                    } label: {
                        Label(store.label, systemImage: store.symbol)
                    }
                }
            }
        }
    }

    private func owned(_ item: CatalogItem) -> Track? {
        LibraryMatcher.match(title: item.title, artist: item.artist, in: tracks)
    }

    private func wished(_ item: CatalogItem) -> Bool {
        let title = LibraryMatcher.normalize(item.title)
        let artist = LibraryMatcher.normalize(item.artist)
        return wishes.contains { LibraryMatcher.normalize($0.title) == title && LibraryMatcher.normalize($0.artist) == artist }
    }

    private func lookUp() async {
        let trimmed = link.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        isLoading = true
        errorText = nil
        defer { isLoading = false }
        do {
            var found = try await CatalogLookup.resolve(trimmed)
            // 내 보관함에 있는 후보를 맨 위로
            found.sort { (owned($0) != nil ? 0 : 1) < (owned($1) != nil ? 0 : 1) }
            candidates = found
            if found.isEmpty { errorText = CatalogLookup.LookupError.notFound.localizedDescription }
        } catch {
            candidates = []
            errorText = error.localizedDescription
        }
    }

    private func flash(_ message: String) {
        addedMessage = message
        Task {
            try? await Task.sleep(for: .seconds(2))
            if addedMessage == message { addedMessage = nil }
        }
    }
}

struct CandidateRow: View {
    let item: CatalogItem
    var owned: Track?
    var wished = false

    var body: some View {
        HStack(spacing: Spacing.m) {
            AsyncImage(url: item.artworkURL) { image in
                image.resizable().scaledToFill()
            } placeholder: {
                RoundedRectangle(cornerRadius: Radius.listArtwork).fill(Color(.tertiarySystemFill))
            }
            .frame(width: 52, height: 52)
            .clipShape(RoundedRectangle(cornerRadius: Radius.listArtwork, style: .continuous))

            VStack(alignment: .leading, spacing: 2) {
                Text(item.title).font(.body).lineLimit(1)
                Text([item.artist, item.album].filter { !$0.isEmpty }.joined(separator: " · "))
                    .font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: Spacing.s)
            if owned != nil {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(Color.tuneAccent)
                    .accessibilityLabel("보관함에 있음")
            } else if wished {
                Image(systemName: "heart.text.square.fill").foregroundStyle(.secondary)
                    .accessibilityLabel("사고 싶은 곡에 있음")
            }
        }
        .contentShape(Rectangle())
    }
}

/// 사고 싶은 곡 목록
struct WishlistView: View {
    @Query(sort: \WishItem.addedAt, order: .reverse) private var wishes: [WishItem]
    @Environment(\.modelContext) private var modelContext
    @Environment(\.openURL) private var openURL
    @State private var showLookup = false

    var body: some View {
        List {
            ForEach(wishes) { wish in
                Menu {
                    ForEach(CatalogLookup.storeLinks(for: wish.catalogItem)) { store in
                        Button { openURL(store.url) } label: { Label(store.label, systemImage: store.symbol) }
                    }
                    Divider()
                    Button(role: .destructive) {
                        modelContext.delete(wish)
                        try? modelContext.save()
                    } label: { Label("목록에서 빼기", systemImage: "trash") }
                } label: {
                    CandidateRow(item: wish.catalogItem)
                }
                .buttonStyle(.plain)
            }
            .onDelete { offsets in
                for index in offsets { modelContext.delete(wishes[index]) }
                try? modelContext.save()
            }
        }
        .listStyle(.plain)
        .navigationTitle("사고 싶은 곡")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { showLookup = true } label: { Image(systemName: "link.badge.plus") }
                    .accessibilityLabel("링크로 찾기")
            }
        }
        .sheet(isPresented: $showLookup) { LinkLookupView() }
        .overlay {
            if wishes.isEmpty {
                ContentUnavailableView("사고 싶은 곡이 없어요", systemImage: "heart.text.square",
                                       description: Text("검색 화면의 '링크로 찾기'나 CSV 플레이리스트 가져오기에서 담을 수 있어요."))
            }
        }
        .task { LibraryMatcher.pruneWishlist(context: modelContext) }
    }
}
