import ActivityKit
import Foundation

enum ActivityError: LocalizedError {
    case disabled
    var errorDescription: String? { "請到「設定 > LyricLane」開啟「即時動態」" }
}

@MainActor
final class LiveActivityManager {
    typealias State = LyricsActivityAttributes.ContentState

    private var activity: Activity<LyricsActivityAttributes>?
    private var lastState: State?
    private var chain: Task<Void, Never>?

    var isActive: Bool {
        adoptExisting()
        return activity?.activityState == .active
    }

    /// 只能在 App 位於前景時呼叫（iOS 限制）
    func start(state: State) throws {
        adoptExisting()
        if activity != nil {
            lastState = nil
            update(state)
            return
        }
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { throw ActivityError.disabled }
        activity = try Activity.request(
            attributes: LyricsActivityAttributes(),
            content: ActivityContent(state: state, staleDate: nil),
            pushType: nil
        )
        lastState = state
    }

    /// 在本機直接更新（不經過推播，所以沒有推播的次數限制與網路延遲）
    func update(_ state: State) {
        guard let activity, activity.activityState == .active, state != lastState else { return }
        lastState = state
        let previous = chain
        chain = Task {
            await previous?.value // 確保更新依序送出
            await activity.update(ActivityContent(state: state, staleDate: nil))
        }
    }

    func end() {
        let all = Activity<LyricsActivityAttributes>.activities
        activity = nil
        lastState = nil
        Task {
            for a in all { await a.end(nil, dismissalPolicy: .immediate) }
        }
    }

    private func adoptExisting() {
        if activity?.activityState != .active {
            activity = Activity<LyricsActivityAttributes>.activities.first { $0.activityState == .active }
        }
    }
}
