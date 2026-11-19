import ActivityKit
import Foundation

enum ActivityError: LocalizedError {
    case disabled
    var errorDescription: String? { "請到「設定 > LyricLane」開啟「即時動態」" }
}

@MainActor
final class LiveActivityManager {
    typealias State = LyricsActivityAttributes.ContentState

    /// 超過這個時間沒收到 App 的更新，即時動態會顯示「已停止」
    /// （保險：App 被系統直接結束、來不及關掉即時動態時）
    private static let staleAfter: TimeInterval = 120
    private static let heartbeat: TimeInterval = 60

    private var activity: Activity<LyricsActivityAttributes>?
    private var lastState: State?
    private var lastSent = Date.distantPast
    private var pending: State?
    private var sending = false

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
            content: content(state),
            pushType: nil
        )
        lastState = state
        lastSent = Date()
    }

    /// 在本機直接更新（不經過推播，所以沒有推播的次數限制與網路延遲）
    func update(_ state: State) {
        guard let activity, activity.activityState == .active else { return }
        // 內容沒變就不送，但每分鐘送一次心跳，延後「已停止」的時間
        guard state != lastState || Date().timeIntervalSince(lastSent) > Self.heartbeat else { return }
        lastState = state
        lastSent = Date()
        // 「只送最新的」：上一個更新還在送時，新的狀態先放著；送完後只補送最後一個。
        // 連續跳歌時不會排出一長串過期的更新，畫面也不會落後好幾首歌。
        pending = state
        guard !sending else { return }
        sending = true
        Task { [weak self] in
            while let me = self, let next = me.pending {
                me.pending = nil
                await activity.update(me.content(next))
            }
            self?.sending = false
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

    /// 關掉所有即時動態並等它們真的結束（重新同步時，關完才開新的）
    func endAndWait() async {
        let all = Activity<LyricsActivityAttributes>.activities
        activity = nil
        lastState = nil
        pending = nil
        for a in all { await a.end(nil, dismissalPolicy: .immediate) }
    }

    /// App 即將被關閉（從多工畫面滑掉）時呼叫：同步等待即時動態結束，最多等 2 秒
    nonisolated static func endAllBeforeTermination() {
        let done = DispatchSemaphore(value: 0)
        Task.detached {
            for a in Activity<LyricsActivityAttributes>.activities {
                await a.end(nil, dismissalPolicy: .immediate)
            }
            done.signal()
        }
        _ = done.wait(timeout: .now() + 2)
    }

    private func content(_ state: State) -> ActivityContent<State> {
        ActivityContent(state: state, staleDate: Date().addingTimeInterval(Self.staleAfter))
    }

    private func adoptExisting() {
        if activity?.activityState != .active {
            activity = Activity<LyricsActivityAttributes>.activities.first { $0.activityState == .active }
        }
    }
}
