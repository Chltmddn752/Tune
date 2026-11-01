import PhotosUI
import SwiftData
import SwiftUI

/// 아티스트 사진을 직접 고르는 화면. 자동 매칭 후보, 사진 앱, 지우기.
struct ArtistPhotoPicker: View {
    let artist: Artist

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @State private var candidates: [ArtistImageService.ArtistPhotoCandidate] = []
    @State private var isLoading = true
    @State private var pickedItem: PhotosPickerItem?
    @State private var applying = false

    private let columns = [GridItem(.adaptive(minimum: 120), spacing: Spacing.m)]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Spacing.xl) {
                    if isLoading {
                        ProgressView("후보를 찾는 중")
                            .frame(maxWidth: .infinity)
                            .padding(.top, 40)
                    } else if candidates.isEmpty {
                        Text("자동으로 찾은 후보가 없어요. 사진 앱에서 직접 고를 수 있어요.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    } else {
                        Text("자동으로 찾은 후보")
                            .font(.headline)
                        LazyVGrid(columns: columns, spacing: Spacing.l) {
                            ForEach(candidates) { candidate in
                                Button {
                                    apply(candidate)
                                } label: {
                                    VStack(spacing: Spacing.s) {
                                        AsyncImage(url: candidate.pictureURL) { image in
                                            image.resizable().scaledToFill()
                                        } placeholder: {
                                            Color(.secondarySystemBackground)
                                        }
                                        .frame(width: 120, height: 120)
                                        .clipShape(Circle())
                                        Text(candidate.name)
                                            .font(.caption.weight(.medium))
                                            .lineLimit(1)
                                    }
                                }
                                .buttonStyle(.plain)
                                .disabled(applying)
                            }
                        }
                    }

                    VStack(alignment: .leading, spacing: Spacing.m) {
                        Text("직접 고르기")
                            .font(.headline)
                        PhotosPicker(selection: $pickedItem, matching: .images) {
                            Label("사진 앱에서 고르기", systemImage: "photo")
                        }
                        if artist.imageFile != nil {
                            Button(role: .destructive) {
                                ArtistImageService.removePhoto(from: artist, context: modelContext)
                                dismiss()
                            } label: {
                                Label("사진 지우기", systemImage: "trash")
                            }
                        }
                    }
                }
                .padding(Spacing.xl)
            }
            .navigationTitle("아티스트 사진")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("닫기") { dismiss() }
                }
            }
            .task {
                candidates = await ArtistImageService.candidates(for: artist, context: modelContext)
                isLoading = false
            }
            .onChange(of: pickedItem) { _, item in
                guard let item else { return }
                Task {
                    guard let data = try? await item.loadTransferable(type: Data.self),
                          let image = UIImage(data: data) else { return }
                    ArtistImageService.applyManual(image: image, to: artist, context: modelContext)
                    dismiss()
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func apply(_ candidate: ArtistImageService.ArtistPhotoCandidate) {
        applying = true
        Task {
            await ArtistImageService.applyRemote(candidate, to: artist, context: modelContext)
            applying = false
            dismiss()
        }
    }
}
