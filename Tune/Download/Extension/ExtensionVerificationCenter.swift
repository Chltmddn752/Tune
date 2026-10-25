import AuthenticationServices
import Foundation
import Observation
import UIKit

/// 서명 세션 인증이 필요할 때 ASWebAuthenticationSession을 띄우고,
/// 돌아온 `mornye://session-grant` 콜백의 grant를 세션으로 교환한다.
@MainActor
@Observable
final class ExtensionVerificationCenter: NSObject, ASWebAuthenticationPresentationContextProviding {
    struct Pending: Identifiable, Equatable, Sendable {
        let id = UUID()
        var extensionID: String
        var authURL: String
        var createdAt: Date
    }

    static let shared = ExtensionVerificationCenter()

    private(set) var pending: Pending?
    private(set) var isAuthenticating = false
    var lastMessage: String?
    var lastError: String?

    @ObservationIgnored private var session: ASWebAuthenticationSession?

    private override init() {
        super.init()
    }

    func install() {
        SignedSessionManager.shared.onVerificationRequired = { [weak self] extensionID, authURL in
            Task { @MainActor [weak self] in
                self?.request(extensionID: extensionID, authURL: authURL)
            }
        }
    }

    func request(extensionID: String, authURL: String) {
        guard URL(string: authURL)?.scheme?.lowercased() == "https" else {
            lastError = "인증 페이지 주소가 올바르지 않아요."
            return
        }
        if isAuthenticating { return }
        pending = Pending(extensionID: extensionID, authURL: authURL, createdAt: .now)
        lastError = nil
        start()
    }

    func start() {
        guard !isAuthenticating, let pending, let url = URL(string: pending.authURL) else { return }
        let session = ASWebAuthenticationSession(url: url, callbackURLScheme: "mornye") { [weak self] callbackURL, error in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.session = nil
                self.isAuthenticating = false
                if let callbackURL {
                    self.handle(callbackURL: callbackURL)
                    return
                }
                if let error {
                    let nsError = error as NSError
                    if nsError.domain == "ASWebAuthenticationSessionErrorDomain", nsError.code == 1 {
                        self.lastError = "인증을 취소했어요."
                    } else {
                        self.lastError = error.localizedDescription
                    }
                }
            }
        }
        session.presentationContextProvider = self
        session.prefersEphemeralWebBrowserSession = false
        self.session = session
        isAuthenticating = true
        if !session.start() {
            self.session = nil
            isAuthenticating = false
            lastError = "인증 페이지를 열지 못했어요. 다시 시도해 주세요."
        }
    }

    func cancel() {
        session?.cancel()
        session = nil
        isAuthenticating = false
    }

    func dismiss() {
        cancel()
        pending = nil
        lastError = nil
    }

    func clearMessage() {
        lastMessage = nil
        lastError = nil
    }

    private func handle(callbackURL: URL) {
        guard callbackURL.host?.lowercased() == "session-grant"
                || callbackURL.path.lowercased().contains("session-grant") else {
            lastError = "인증 결과를 알아보지 못했어요."
            return
        }
        let items = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let grant = items.first { $0.name == "grant" }?.value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let state = items.first { $0.name == "state" }?.value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !grant.isEmpty else {
            lastError = "인증 결과에 코드가 없어요."
            return
        }

        Task.detached(priority: .userInitiated) {
            let result = SignedSessionManager.shared.completeGrantFromCallback(state: state, grant: grant)
            await MainActor.run { [weak self] in
                guard let self else { return }
                if (result["success"] as? Bool) == true {
                    let extensionID = result["extension_id"] as? String ?? self.pending?.extensionID
                    let name = extensionID.flatMap { ExtensionStore.shared.installedExtension(id: $0)?.title } ?? "확장"
                    self.pending = nil
                    self.lastError = nil
                    self.lastMessage = "\(name) 인증을 마쳤어요. 다시 시도해 주세요."
                } else {
                    self.lastError = result["error"] as? String ?? "인증을 마치지 못했어요."
                }
            }
        }
    }

    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let active = scenes.first { $0.activationState == .foregroundActive } ?? scenes.first
        if let active {
            if let existing = active.windows.first(where: { $0.isKeyWindow }) ?? active.windows.first {
                return existing
            }
            return UIWindow(windowScene: active)
        }
        return UIWindow()
    }
}
