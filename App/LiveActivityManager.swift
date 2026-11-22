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
    private var pendingStale: Date?
    private var sending = false
    /// 目前這輪送出開始的時間，用來偵測「送出卡住」
    private var sendStartedAt = Date.distantPast
    /// 每開一個新的送出迴圈就 +1；舊的迴圈發現自己過期了就自行結束
    private var senderGeneration = 0
    private var loggedInactive = false

    // 診斷：送出的序號、iOS 回報已套用的序號
    private(set) var sentSeq = 0
    private(set) var appliedSeq = 0
    private var reportedLag = false
    private var watchers: [Task<Void, Never>] = []
    private var watchedID: String?

    /// 即時動態被使用者滑掉、或到了 iOS 的時間上限（約 8 小時）而結束時通知
    var onEnded: (() -> Void)?
    /// 單次 update 超過這個時間還沒回來，就當作卡住，不再等它
    private static let sendTimeout: TimeInterval = 1.5

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
        sentSeq += 1
        var first = state
        first.seq = sentSeq
        let created = try Activity.request(
            attributes: LyricsActivityAttributes(),
            content: content(first),
            pushType: nil
        )
        activity = created
        watch(created)
        lastState = state
        lastSent = Date()
        DiagLog.log("即時動態：已開啟")
    }

    /// 在本機直接更新（不經過推播，所以沒有推播的次數限制與網路延遲）
    /// 重新同步用：不管內容有沒有變，都送一次
    func forceRefresh(_ state: State, staleDate: Date? = nil) {
        lastState = nil
        update(state, staleDate: staleDate)
    }

    func update(_ state: State, staleDate: Date? = nil) {
        guard let activity, activity.activityState == .active else {
            if let activity, !loggedInactive {
                loggedInactive = true
                DiagLog.log("即時動態：已不在顯示（狀態 \(String(describing: activity.activityState))），之後的更新都送不出去")
            }
            return
        }
        loggedInactive = false
        // 內容沒變就不送，但每分鐘送一次心跳，延後「已停止」的時間
        guard state != lastState || Date().timeIntervalSince(lastSent) > Self.heartbeat else { return }
        lastState = state
        lastSent = Date()
        // 「只送最新的」：上一個更新還在送時，新的狀態先放著；送完後只補送最後一個。
        // 連續跳歌時不會排出一長串過期的更新，畫面也不會落後好幾首歌。
        pending = state
        pendingStale = staleDate
        // 上一個 update 還在送：正常情況就等它送完再補送最新的。
        // 但 CarPlay 上系統有時會讓 activity.update 很久都不返回，
        // 以前一卡住 sending 就永遠是 true，之後所有換句都被擋住（歌詞停在某一句）。
        // 超過 sendTimeout 就放棄等待，另開一個送出迴圈。
        if sending, Date().timeIntervalSince(sendStartedAt) < Self.sendTimeout { return }
        if sending {
            DiagLog.log("即時動態：上一個更新卡住超過 \(Self.sendTimeout) 秒，不等了")
        }
        startSender(activity)
    }

    private func startSender(_ activity: Activity<LyricsActivityAttributes>) {
        senderGeneration += 1
        let generation = senderGeneration
        sending = true
        Task { [weak self] in
            while let me = self, me.senderGeneration == generation, var next = me.pending {
                let stale = me.pendingStale
                me.pending = nil
                me.sentSeq += 1
                next.seq = me.sentSeq
                let t0 = Date()
                me.sendStartedAt = t0
                await activity.update(me.content(next, staleDate: stale))
                let took = Date().timeIntervalSince(t0)
                if took > 0.5 {
                    DiagLog.log(String(format: "即時動態：一次更新花了 %.1f 秒（系統在拖延）", took))
                }
            }
            // 只有「目前這一代」的迴圈可以把 sending 關掉（舊的、卡住的迴圈回來時不要動它）
            if let me = self, me.senderGeneration == generation { me.sending = false }
        }
    }

    func end() {
        DiagLog.log("即時動態：關閉")
        let all = Activity<LyricsActivityAttributes>.activities
        activity = nil
        lastState = nil
        pending = nil
        senderGeneration += 1
        sending = false
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
        senderGeneration += 1
        sending = false
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

    private func content(_ state: State, staleDate: Date? = nil) -> ActivityContent<State> {
        ActivityContent(state: state, staleDate: staleDate ?? Date().addingTimeInterval(Self.staleAfter))
    }

    private func adoptExisting() {
        if activity?.activityState != .active {
            activity = Activity<LyricsActivityAttributes>.activities.first { $0.activityState == .active }
            if let activity { watch(activity) }
        }
    }

    /// 盯著即時動態：iOS 套用了哪一次更新、什麼時候結束
    private func watch(_ a: Activity<LyricsActivityAttributes>) {
        guard watchedID != a.id else { return }
        watchedID = a.id
        appliedSeq = 0
        reportedLag = false
        watchers.forEach { $0.cancel() }
        watchers = [
            Task { [weak self] in
                for await state in a.activityStateUpdates {
                    guard let self else { return }
                    DiagLog.log("即時動態：狀態變成 \(String(describing: state))")
                    if state == .ended || state == .dismissed {
                        if self.activity?.id == a.id {
                            self.activity = nil
                            self.lastState = nil
                        }
                        self.onEnded?()
                    }
                }
            },
            Task { [weak self] in
                for await content in a.contentUpdates {
                    guard let self else { return }
                    self.appliedSeq = max(self.appliedSeq, content.state.seq)
                    let behind = self.sentSeq - self.appliedSeq
                    if behind > 5, !self.reportedLag {
                        self.reportedLag = true
                        DiagLog.log("⚠️ 即時動態：iOS 沒有套用更新（送出 #\(self.sentSeq)，套用到 #\(self.appliedSeq)）")
                    } else if behind <= 1, self.reportedLag {
                        self.reportedLag = false
                        DiagLog.log("即時動態：iOS 恢復套用更新（#\(self.appliedSeq)）")
                    }
                }
            },
        ]
    }

    /// 給診斷紀錄的摘要：送出／iOS 套用／實際畫出（CarPlay 與其他）
    func diagSummary() -> String {
        let p = SharedStore.loadDrawProbe()
        func ago(_ d: Date?) -> String {
            guard let d, d > .distantPast else { return "從未" }
            return "\(Int(Date().timeIntervalSince(d))) 秒前"
        }
        return "即時動態：送出 #\(sentSeq)、iOS 套用 #\(appliedSeq)、CarPlay 畫出 #\(p?.carPlaySeq ?? 0)（\(ago(p?.carPlayAt))）、"
            + "鎖定畫面/動態島畫出 #\(p?.otherSeq ?? 0)（\(ago(p?.otherAt))）、狀態 \(activity.map { String(describing: $0.activityState) } ?? "沒有")"
    }
}
