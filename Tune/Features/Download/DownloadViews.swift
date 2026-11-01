import SwiftUI

// MARK: - 온라인 검색 결과 한 줄

/// 온라인 곡 한 줄. 행 전체를 누르거나 오른쪽 ↓를 누르면 기본 음질로 바로 받는다.
struct ProviderResultRow: View {
    let track: ProviderTrack
    let installed: InstalledExtension
    var job: DownloadJob? = nil
    var isSelecting = false
    var isSelected = false
    /// 앨범·플레이리스트 안에서 보여 줄 곡 번호
    var number: Int? = nil
    var artworkSize: CGFloat = 52
    /// 행을 눌렀을 때 할 일을 바깥에서 정한다(선택 모드 등).
    var onTap: (() -> Void)? = nil

    @Environment(DownloadCoordinator.self) private var coordinator
    @Environment(DownloadManager.self) private var downloads
    @Environment(ExtensionStore.self) private var store
    @Environment(ToastCenter.self) private var toasts

    var body: some View {
        HStack(spacing: Spacing.m) {
            if let number {
                Text("\(number)")
                    .font(.footnote.monospacedDigit())
                    .foregroundStyle(.tertiary)
                    .frame(width: 22, alignment: .trailing)
            }
            AsyncImage(url: track.coverURL.flatMap(URL.init(string:))) { image in
                image.resizable().scaledToFill()
            } placeholder: {
                RoundedRectangle(cornerRadius: Radius.listArtwork)
                    .fill(Color(.tertiarySystemFill))
                    .overlay {
                        Image(systemName: "music.note")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
            }
            .frame(width: artworkSize, height: artworkSize)
            .clipShape(RoundedRectangle(cornerRadius: Radius.listArtwork, style: .continuous))

            VStack(alignment: .leading, spacing: 2) {
                Text(track.title)
                    .font(.body)
                    .lineLimit(1)
                Text(track.artist.isEmpty ? "알 수 없는 아티스트" : track.artist)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Text(meta)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: Spacing.s)

            if isSelecting {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(isSelected ? Color.tuneAccent : Color.secondary)
                    .frame(width: 44, height: 44)
                    .accessibilityLabel(isSelected ? "선택됨" : "선택 안 됨")
            } else {
                DownloadButton(track: track, job: job)
            }
        }
        .frame(minHeight: 56)
        .contentShape(Rectangle())
        .onTapGesture {
            if let onTap {
                onTap()
            } else if !isSelecting {
                coordinator.requestDownload(track: track, store: store, downloads: downloads, toasts: toasts)
            }
        }
        .contextMenu {
            if !isSelecting {
                Button {
                    coordinator.requestDownload(track: track, store: store, downloads: downloads, toasts: toasts)
                } label: {
                    Label("받기", systemImage: "arrow.down.circle")
                }
            }
        }
    }

    private var meta: String {
        guard track.durationMs > 0 else { return installed.title }
        return "\(installed.title) · \(Formatters.time(Double(track.durationMs) / 1000))"
    }
}
