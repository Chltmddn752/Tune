import SwiftUI

/// 대기열: 셔플 · 반복 · 자동 재생, 다음 곡 목록(순서 바꾸기·빼기), 기록
struct QueueView: View {
    @Environment(PlayerEngine.self) private var player
    @AppStorage(SettingsKey.autoplay) private var autoplay = true
    @State private var showHistory = false

    var body: some View {
        @Bindable var player = player

        List {
            Section {
                HStack(spacing: Spacing.s) {
                    toggle("셔플", systemImage: "shuffle", isOn: player.shuffle) { player.shuffle.toggle() }
                    toggle(player.repeatMode == .one ? "한 곡 반복" : "반복", systemImage: player.repeatMode.symbol,
                           isOn: player.repeatMode != .off) { player.repeatMode = player.repeatMode.next }
                    toggle("자동 재생", systemImage: "infinity", isOn: autoplay) { autoplay.toggle() }
                }
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets(top: 4, leading: 20, bottom: 4, trailing: 20))
            }

            if showHistory, !player.history.isEmpty {
                Section("기록") {
                    ForEach(player.history.suffix(30).reversed()) { item in
                        QueueRow(item: item)
                            .opacity(0.6)
                            .onTapGesture { player.jump(to: item) }
                    }
                }
                .listRowBackground(Color.clear)
            }

            Section {
                ForEach(player.upNext) { item in
                    QueueRow(item: item)
                        .contentShape(Rectangle())
                        .onTapGesture { player.jump(to: item) }
                }
                .onMove { player.moveUpNext(from: $0, to: $1) }
                .onDelete { player.removeFromUpNext(at: $0) }
                .listRowBackground(Color.clear)
            } header: {
                HStack {
                    Text("다음 곡")
                    Spacer()
                    if !player.history.isEmpty {
                        Button(showHistory ? "기록 숨기기" : "기록") { withAnimation { showHistory.toggle() } }
                    }
                    if !player.upNext.isEmpty {
                        Button("지우기") { player.clearUpNext() }
                    }
                }
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.white.opacity(0.8))
            } footer: {
                if player.upNext.isEmpty {
                    Text(autoplay ? "대기열이 끝나면 비슷한 곡을 이어서 틀어요." : "다음 곡이 없어요.")
                        .foregroundStyle(.white.opacity(0.6))
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .environment(\.editMode, .constant(.active))
        .mask(
            LinearGradient(stops: [
                .init(color: .clear, location: 0), .init(color: .black, location: 0.04),
                .init(color: .black, location: 0.94), .init(color: .clear, location: 1)
            ], startPoint: .top, endPoint: .bottom)
        )
    }

    private func toggle(_ title: String, systemImage: String, isOn: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .labelStyle(.iconOnly)
                .font(.headline)
                .frame(maxWidth: .infinity, minHeight: 36)
                .foregroundStyle(isOn ? Color.black.opacity(0.75) : Color.white)
                .background(isOn ? Color.white.opacity(0.9) : Color.white.opacity(0.15), in: Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityAddTraits(isOn ? .isSelected : [])
        .sensoryFeedback(.selection, trigger: isOn)
    }
}

private struct QueueRow: View {
    let item: QueueItem

    var body: some View {
        HStack(spacing: Spacing.m) {
            ArtworkView(file: item.artworkFile, cornerRadius: Radius.listArtwork)
                .frame(width: 44, height: 44)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title).font(.body).lineLimit(1)
                Text(item.artist).font(.subheadline).foregroundStyle(.white.opacity(0.6)).lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .foregroundStyle(.white)
    }
}
