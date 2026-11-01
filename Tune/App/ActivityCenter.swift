import Foundation
import Observation
import SwiftUI

/// 앱에서 진행되는 모든 작업(가져오기·다운로드·인증·가사·사진·정리)을 한곳에 모은다.
/// 토스트를 놓쳐도 설정 > 진행 중인 작업에서 지금 무엇이 돌고 있는지 볼 수 있다.
@MainActor
@Observable
final class ActivityCenter {
    static let shared = ActivityCenter()

    struct Activity: Identifiable, Hashable {
        let id: UUID
        var title: String
        var symbol: String
        var detail: String?
        var completed: Int
        var total: Int
        var startedAt: Date
        var finishedAt: Date?
        var failed = false
        var message: String?

        var isRunning: Bool { finishedAt == nil }
        var fraction: Double? {
            guard total > 0 else { return nil }
            return min(max(Double(completed) / Double(total), 0), 1)
        }
        var countText: String? {
            guard total > 0 else { return nil }
            return "\(min(completed, total))/\(total)"
        }
    }

    private(set) var running: [Activity] = []
    private(set) var finished: [Activity] = []
    @ObservationIgnored private var cancelHandlers: [UUID: () -> Void] = [:]

    var hasRunning: Bool { !running.isEmpty }

    /// 새 작업을 시작한다. 끝나면 반드시 finish나 fail을 불러야 한다.
    @discardableResult
    func begin(title: String, symbol: String = "hourglass", total: Int = 0,
               detail: String? = nil, onCancel: (() -> Void)? = nil) -> UUID {
        let activity = Activity(
            id: UUID(), title: title, symbol: symbol, detail: detail,
            completed: 0, total: total, startedAt: .now
        )
        running.insert(activity, at: 0)
        if let onCancel { cancelHandlers[activity.id] = onCancel }
        return activity.id
    }

    func update(_ id: UUID, completed: Int? = nil, total: Int? = nil, detail: String? = nil) {
        guard let index = running.firstIndex(where: { $0.id == id }) else { return }
        if let completed { running[index].completed = completed }
        if let total { running[index].total = total }
        if let detail { running[index].detail = detail }
    }

    func finish(_ id: UUID, message: String? = nil) {
        guard let index = running.firstIndex(where: { $0.id == id }) else { return }
        var activity = running.remove(at: index)
        activity.finishedAt = .now
        activity.message = message
        if activity.total > 0 { activity.completed = activity.total }
        archive(activity)
        cancelHandlers[id] = nil
    }

    func fail(_ id: UUID, message: String) {
        guard let index = running.firstIndex(where: { $0.id == id }) else { return }
        var activity = running.remove(at: index)
        activity.finishedAt = .now
        activity.failed = true
        activity.message = message
        archive(activity)
        cancelHandlers[id] = nil
    }

    /// 토스트로만 나오던 짧은 안내도 기록으로 남긴다.
    func record(_ message: String, symbol: String = "info.circle") {
        var activity = Activity(
            id: UUID(), title: message, symbol: symbol, detail: nil,
            completed: 1, total: 1, startedAt: .now
        )
        activity.finishedAt = .now
        archive(activity)
    }

    func canCancel(_ id: UUID) -> Bool { cancelHandlers[id] != nil }

    func cancel(_ id: UUID) {
        guard let handler = cancelHandlers[id] else { return }
        handler()
        fail(id, message: "취소했어요")
    }

    func clearFinished() {
        finished.removeAll()
    }

    private func archive(_ activity: Activity) {
        finished.insert(activity, at: 0)
        if finished.count > 50 { finished.removeLast(finished.count - 50) }
    }
}

/// 설정과 토스트에서 여는 "진행 중인 작업" 화면.
struct ActivityView: View {
    @Environment(ActivityCenter.self) private var center
    @Environment(\.dismiss) private var dismiss
    @Environment(\.horizontalSizeClass) private var sizeClass

    var body: some View {
        NavigationStack {
            List {
                Section("진행 중") {
                    if center.running.isEmpty {
                        Text("지금 진행 중인 작업이 없어요.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(center.running) { activity in
                            runningRow(activity)
                        }
                    }
                }

                let finished = center.finished
                if !finished.isEmpty {
                    Section("최근 완료 · 실패") {
                        ForEach(finished) { activity in
                            finishedRow(activity)
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("진행 중인 작업")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("닫기") { dismiss() }
                }
                if !center.finished.isEmpty {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("기록 지우기") { center.clearFinished() }
                    }
                }
            }
        }
        .presentationDetents(sizeClass == .regular ? [.large] : [.medium, .large])
    }

    private func runningRow(_ activity: ActivityCenter.Activity) -> some View {
        VStack(alignment: .leading, spacing: Spacing.s) {
            HStack(spacing: Spacing.m) {
                Image(systemName: activity.symbol)
                    .foregroundStyle(Color.tuneAccent)
                    .frame(width: 24)
                Text(activity.title).font(.body.weight(.semibold))
                Spacer()
                if let count = activity.countText {
                    Text(count)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                if center.canCancel(activity.id) {
                    Button("취소") { center.cancel(activity.id) }
                        .font(.footnote.weight(.semibold))
                        .buttonStyle(.borderless)
                }
            }

            if let fraction = activity.fraction {
                ProgressView(value: fraction)
            } else {
                ProgressView().controlSize(.small)
            }

            TimelineView(.periodic(from: .now, by: 1)) { context in
                HStack {
                    if let detail = activity.detail {
                        Text(detail).lineLimit(1)
                    }
                    Spacer()
                    Text(elapsed(from: activity.startedAt, to: context.date))
                        .monospacedDigit()
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, Spacing.xs)
    }

    private func finishedRow(_ activity: ActivityCenter.Activity) -> some View {
        HStack(alignment: .top, spacing: Spacing.m) {
            Image(systemName: activity.failed ? "exclamationmark.triangle.fill" : activity.symbol)
                .foregroundStyle(activity.failed ? Color.red : Color.tuneAccent)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(activity.title).font(.body)
                if let message = activity.message {
                    Text(message).font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            Text(activity.finishedAt ?? activity.startedAt, format: .dateTime.hour().minute())
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
    }

    private func elapsed(from start: Date, to now: Date) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(start)))
        if seconds < 60 { return "\(seconds)초" }
        return "\(seconds / 60)분 \(seconds % 60)초"
    }
}
