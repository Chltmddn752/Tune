import Foundation

/// 확장이 그대로 던진 오류를 사용자가 이해할 수 있는 문장으로 바꾼다.
enum ExtensionErrorText {
    static func localized(_ error: Error) -> String {
        let message = error.localizedDescription
        let lowered = message.lowercased()
        // Spotify가 2025년부터 웹 플레이어용 익명 토큰 발급을 막았다.
        // 확장은 TOTP까지 맞춰 요청하지만 서버가 400으로 거절한다.
        if lowered.contains("access token"), lowered.contains("http 400") || lowered.contains("http 401") {
            return "Spotify Web은 Spotify가 앱에서의 익명 토큰 발급을 막아 검색할 수 없어요. Apple Music이나 다른 음원 확장을 골라 주세요."
        }
        return message
    }
}
