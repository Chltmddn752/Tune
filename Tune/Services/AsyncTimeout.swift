import Foundation

/// 파일 제공 앱·깨진 파일 때문에 작업이 영원히 멈추지 않게 시간 제한을 둔다.
enum AsyncTimeout {
    /// `seconds` 안에 끝나면 결과를, 넘으면 nil을 돌려준다(작업은 취소한다).
    static func value<T: Sendable>(seconds: Double, operation: @escaping @Sendable () async -> T) async -> T? {
        await withTaskGroup(of: T?.self) { group in
            group.addTask { await operation() }
            group.addTask {
                try? await Task.sleep(for: .seconds(seconds))
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }
}
