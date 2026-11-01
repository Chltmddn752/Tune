import SwiftUI

/// 가져오기·인증·재생 안내를 하나의 글래스 토스트로 모은다.
struct BannerBridge: View {
    @Environment(ToastCenter.self) private var toasts
    @Environment(LibraryImporter.self) private var importer
    @Environment(PlayerEngine.self) private var player
    @Environment(ExtensionStore.self) private var extensions
    @State private var center = ExtensionVerificationCenter.shared

    private var verificationTitle: String {
        guard let id = center.pending?.extensionID,
              let installed = extensions.installedExtension(id: id) else { return "확장" }
        return installed.title
    }

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .onChange(of: importer.isWorking) { _, working in
                if working {
                    toasts.progress("가져오는 중 \(importer.done)/\(importer.total)", symbol: "square.and.arrow.down")
                }
            }
            .onChange(of: importer.done) { _, done in
                guard importer.isWorking else { return }
                toasts.progress("가져오는 중 \(done)/\(importer.total)", symbol: "square.and.arrow.down")
            }
            .onChange(of: importer.lastResult) { _, result in
                guard let result else { return }
                toasts.finish(result, symbol: "checkmark.circle.fill")
                importer.lastResult = nil
            }
            .onChange(of: player.playbackNotice) { _, notice in
                guard let notice else { return }
                toasts.show(notice, symbol: "exclamationmark.circle")
                player.playbackNotice = nil
            }
            .onChange(of: center.pending?.extensionID) { _, id in
                guard id != nil else { return }
                toasts.show("\(verificationTitle) 인증이 필요해요", symbol: "person.badge.key", actionTitle: "인증하기") {
                    center.start()
                }
            }
            .onChange(of: center.isAuthenticating) { _, working in
                guard working, center.pending != nil else { return }
                toasts.progress("\(verificationTitle) 인증 페이지를 여는 중", symbol: "person.badge.key")
            }
            .onChange(of: center.lastError) { _, error in
                guard let error, center.pending != nil else { return }
                toasts.show(
                    "\(verificationTitle) 인증이 필요해요 · \(error)",
                    symbol: "exclamationmark.triangle.fill",
                    actionTitle: "다시 열기"
                ) { center.start() }
            }
            .onChange(of: center.lastMessage) { _, message in
                guard let message else { return }
                toasts.finish(message, symbol: "checkmark.circle.fill")
                center.clearMessage()
            }
    }
}
