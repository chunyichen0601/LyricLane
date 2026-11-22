import ActivityKit
import Foundation
import WidgetKit

/// 核心同步引擎：
/// 1. 優先用 App Remote 直接向手機上的 Spotify App 取得播放位置（本機、事件推送、幾乎零延遲）
/// 2. 連不上時退回 Web API；因為伺服器回報的進度「只會落後、不會超前」，只接受往前的修正
/// 3. 在本機用「錨點 + 經過時間」推算目前位置，用精準計時器在每句的時間點換句
/// 4. 每首歌把整首時間表交給 CarPlay 小工具，讓它自己照表換句
@MainActor
final class SyncEngine: ObservableObject {
    @Published private(set) var track: PlaybackSnapshot?
    @Published private(set) var lines: [LyricLine] = []
    @Published private(set) var currentIndex = -1
    @Published private(set) var status = "尚未開始"
    @Published private(set) var lyricsStatus = ""
    @Published private(set) var isRunning = false
    @Published private(set) var activityRunning = false

    // 診斷資訊
    @Published private(set) var syncSource = "—"
    @Published private(set) var isDirect = false
    @Published private(set) var resyncPhase: ResyncPhase = .idle
    @Published private(set) var widgetReloads = 0

    enum ResyncPhase: Equatable {
        case idle
        case working
        case done(String)
        case failed(String)
    }

    var isResyncing: Bool { resyncPhase == .working }
    @Published private(set) var remoteDetail = ""
    @Published private(set) var lastDriftMs = 0
    @Published private(set) var latencyMs = 0

    private let auth: SpotifyAuth
    private let client: SpotifyClient
    private let remote = SpotifyRemote()
    private let provider = LyricsProvider()
    private let activity = LiveActivityManager()
    private var rawLines: [LyricLine] = []

    // 計時錨點：在 anchorDate 這個時間，歌曲播放到 anchorProgress 秒
    private var anchorProgress = 0.0
    private var anchorDate = Date()
    private var playing = false
    private var behindStreak = 0
    private var previousTrackID: String?
    private var trackChangedAt = Date.distantPast
    private var lastTrackChangeTrusted = false
    private var lineTimerDeadline = Date.distantFuture
    /// 即時動態上顯示的那一句（比畫面上的歌詞提早 activityLead 秒換）
    private var activityIndex = -1
    /// 使用者有開即時動態：被滑掉／超過 8 小時被系統結束後，下次回到前景自動重開
    private var wantsActivity = false
    private var prefetchTask: Task<Void, Never>?
    private var lastDiagSummaryAt = Date.distantPast

    /// 即時動態提早送出的秒數。
    /// activity.update 回傳不代表已經顯示，系統還要傳遞、重畫；不提早的話畫面一定慢半拍。
    /// 參考 DriveVerse：轉場 0.35 秒 + 0.15 秒緩衝 = 0.5 秒。
    static let activityLead = 0.5
    /// CarPlay 小工具額外提早（CarPlay 切換時間點本來就會晚一點，Lyrics Dash 也有同樣的設定）
    static let carWidgetLead = 0.5
    /// 預抓接下來幾首的歌詞
    static let prefetchCount = 5

    private var pollTask: Task<Void, Never>?
    private var lyricsTask: Task<Void, Never>?
    private var widgetTask: Task<Void, Never>?
    private var lineTimer: DispatchSourceTimer?

    init(auth: SpotifyAuth) {
        self.auth = auth
        self.client = SpotifyClient(auth: auth)
        remote.onSnapshot = { [weak self] snap in
            self?.ingest(snap, trusted: true)
            self?.status = snap.isPlaying ? "同步中" : "已暫停"
        }
        remote.onStatusChange = { [weak self] _ in self?.updateSourceLabel() }
        activity.onEnded = { [weak self] in
            self?.activityRunning = false
            DiagLog.log("即時動態已結束（被滑掉或到了系統時間上限），下次打開 App 會自動重開")
        }
    }

    func position(at date: Date = Date()) -> Double {
        playing ? anchorProgress + date.timeIntervalSince(anchorDate) : anchorProgress
    }

    // MARK: - 生命週期

    func appBecameActive() {
        guard auth.isLoggedIn else { return }
        start() // 背景同步一律開著（CarPlay 小工具靠它更新）
        if activity.isActive {
            activityRunning = true
        } else if AppSettings.shared.autoLiveActivity || wantsActivity {
            // 「自動開啟」，或之前有開但被滑掉／到了 8 小時上限：App 在前景時才能開新的
            startActivity()
        }
    }

    func start() {
        guard pollTask == nil else { return }
        DiagLog.log("開始背景同步")
        KeepAlive.shared.start()
        LocationKeepAlive.shared.start()
        isRunning = true
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let delay = await self?.pollOnce() else { return }
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            }
        }
    }

    func stop() {
        DiagLog.log("停止背景同步")
        pollTask?.cancel()
        pollTask = nil
        lineTimer?.cancel()
        lineTimer = nil
        remote.disconnect()
        KeepAlive.shared.stop()
        LocationKeepAlive.shared.stop()
        isRunning = false
        status = "已停止"
        updateSourceLabel()
    }

    func startActivity() {
        do {
            try activity.start(state: makeState())
            activityRunning = true
            wantsActivity = true
            if !ActivityAuthorizationInfo().frequentPushesEnabled {
                DiagLog.log("⚠️ 「更頻繁更新」沒開：設定 › LyricLane › 即時動態 › 更頻繁更新")
            }
        } catch {
            activityRunning = false
            status = "無法啟動即時動態：\(error.localizedDescription)"
        }
    }

    func endActivity() {
        wantsActivity = false
        activity.end()
        activityRunning = false
    }

    /// 給 Siri／捷徑／CarPlay 自動化呼叫（可在背景執行）
    func startFromIntent() -> Bool {
        guard auth.isLoggedIn else { return false }
        start()
        if AppSettings.shared.autoLiveActivity { startActivity() }
        publishWidget(force: true)
        return true
    }

    func stopFromIntent() {
        endActivity()
        stop()
        SharedStore.markClosed()
        WidgetCenter.shared.reloadAllTimelines()
    }

    /// 重新同步：歌詞卡住、不同步、抓錯歌詞時用。整套流程重來，不只是刷新畫面。
    func resync() {
        guard auth.isLoggedIn, !isResyncing else { return }
        DiagLog.log("手動重新同步")
        resyncPhase = .working
        status = "重新同步中…"
        let keepActivity = activityRunning || activity.isActive

        // 1. 停掉所有進行中的工作
        lyricsTask?.cancel()
        widgetTask?.cancel()
        lineTimer?.cancel()
        lineTimer = nil
        pollTask?.cancel()
        pollTask = nil

        // 2. 斷開直連，並允許立刻重連
        remote.disconnect()
        remote.resetBackoff()

        // 3. 丟掉這首歌的歌詞快取與所有計時狀態
        if let id = track?.trackID { provider.forget(id) }
        track = nil
        rawLines = []
        lines = []
        currentIndex = -1
        activityIndex = -1
        lyricsStatus = ""
        behindStreak = 0
        lastDriftMs = 0
        setAnchor(0, Date(), false)

        // 4. 重建背景執行，立刻重新抓目前播放的歌（第一輪馬上執行，不用等）
        KeepAlive.shared.restart()
        isRunning = false
        start()

        // 5. 即時動態：不要關掉再重開！App 在背景時 iOS 常常不讓你開新的，
        //    以前在車上按 ↻ 可能讓歌詞直接消失。現在只強制送一次最新內容。
        if activity.isActive {
            activity.forceRefresh(makeState(), staleDate: staleDateForCurrentLine())
            activityRunning = true
        } else if keepActivity {
            startActivity() // 原本有、但已經不見了：試著重開（前景一定成功，背景看系統）
        }

        // 正常情況：抓到歌詞（或確認沒在播放）就會結束；最多等 8 秒
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 8_000_000_000)
            guard let self, self.isResyncing else { return }
            if self.track == nil {
                self.endResync(.failed("連不上 Spotify"))
            } else {
                self.finishResyncIfNeeded()
            }
        }
    }

    /// 重新同步完成：告訴使用者結果（連線方式＋歌詞狀態）
    private func finishResyncIfNeeded() {
        guard isResyncing else { return }
        let via = isDirect ? "直連" : "網路"
        if track == nil {
            endResync(.done("已連線 · 目前沒有播放"))
        } else if lines.isEmpty {
            endResync(.failed("\(via) · 這首找不到歌詞"))
        } else {
            endResync(.done("\(via) · 歌詞已更新"))
        }
    }

    private func endResync(_ phase: ResyncPhase) {
        resyncPhase = phase
        switch phase {
        case let .done(message), let .failed(message):
            status = message
        case .idle, .working:
            break
        }
        // 結果顯示 3 秒後收起來
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            guard let self, self.resyncPhase == phase else { return }
            self.resyncPhase = .idle
        }
    }

    func settingsChanged() {
        rebuildLines()
        reschedule()
        publishWidget(force: true)
    }

    // MARK: - 取得播放位置

    /// 回傳下次輪詢前要等幾秒
    private func pollOnce() async -> Double {
        KeepAlive.shared.ensureRunning() // 每輪（最多 5 秒）檢查一次背景音訊還在不在
        LocationKeepAlive.shared.ensureRunning()
        if activityRunning, Date().timeIntervalSince(lastDiagSummaryAt) > 60 {
            lastDiagSummaryAt = Date()
            DiagLog.log(activity.diagSummary())
        }
        guard auth.isLoggedIn else {
            status = "請先登入 Spotify"
            return 3
        }

        // App Remote 連著時，它會主動推送，不需要輪詢網路
        if remote.isConnected {
            if remote.isHealthy {
                updateSourceLabel()
                return 5
            }
            // 連著但 15 秒沒收到任何狀態（例如連續跳歌後 Spotify 那邊卡住）：
            // 自動斷開，這一輪先改用網路模式，下一輪再重新直連——不用使用者手動重開 App
            DiagLog.log("直連：15 秒沒收到狀態，斷開改用網路")
            remote.disconnect()
        }
        await tryConnectRemote()

        do {
            guard let snap = try await client.currentlyPlaying() else {
                handleIdle()
                return 5
            }
            if remote.isConnected { return 5 } // 剛好連上了，以 App Remote 為準
            ingest(snap, trusted: false)
            status = snap.isPlaying ? "同步中" : "已暫停"
            updateSourceLabel()
            guard snap.isPlaying else { return 3 }
            // 歌曲開頭密集取樣，快速收斂到最新的進度
            if position() < 12 { return 1 }
            // 歌快結束時，在換歌後馬上再問一次，切歌才不會慢
            let remaining = Double(snap.durationMs - snap.progressMs) / 1000
            return max(0.5, min(3, remaining + 0.3))
        } catch SpotifyError.rateLimited(let seconds) {
            status = "Spotify 限流，\(seconds) 秒後重試"
            DiagLog.log(status)
            return Double(max(seconds, 1))
        } catch {
            status = "連線錯誤：\(error.localizedDescription)"
            DiagLog.log(status)
            return 5
        }
    }

    private func tryConnectRemote() async {
        guard AppSettings.shared.useAppRemote, auth.hasRemoteScope,
              let token = try? await auth.validToken() else { return }
        remote.connect(clientID: auth.currentClientID, token: token)
    }

    private func updateSourceLabel() {
        isDirect = remote.isConnected
        if remote.isConnected {
            syncSource = "Spotify App 直連（即時）"
            remoteDetail = ""
        } else {
            syncSource = isRunning ? "Web API（網路，可能落後）" : "—"
            if !AppSettings.shared.useAppRemote {
                remoteDetail = "已關閉直連"
            } else if !auth.hasRemoteScope {
                remoteDetail = "需要重新登入 Spotify 才能直連"
            } else if case let .failed(msg) = remote.status {
                remoteDetail = "直連失敗：\(msg)"
            } else {
                remoteDetail = ""
            }
        }
    }

    private func handleIdle() {
        if status != "目前沒有播放" { DiagLog.log("Spotify 目前沒有播放") }
        status = "目前沒有播放"
        if playing {
            anchorProgress = position()
            anchorDate = Date()
            playing = false
        }
        reschedule()
        publishWidget()
        finishResyncIfNeeded()
    }

    /// trusted = true：來自 App Remote（本機，準確）
    /// trusted = false：來自 Web API（伺服器資料可能是舊的，只會讓進度看起來「落後」）
    private func ingest(_ snap: PlaybackSnapshot, trusted: Bool) {
        let progress = Double(snap.progressMs) / 1000
        latencyMs = Int((snap.latency * 1000).rounded())

        if snap.trackID != track?.trackID {
            // 網路資料常常落後好幾秒：直連剛告訴我們換歌了，Web API 卻還在回報上一首。
            // 以前會把它當成「又換回上一首」，歌詞被清掉重抓，連續跳歌時就一路跟不上。
            if !trusted, lastTrackChangeTrusted, snap.trackID == previousTrackID,
               Date().timeIntervalSince(trackChangedAt) < 10 {
                DiagLog.log("忽略網路回報的舊資料（還是上一首：\(snap.title)）")
                return
            }
            previousTrackID = track?.trackID
            trackChangedAt = Date()
            lastTrackChangeTrusted = trusted
            DiagLog.log("換歌：\(snap.title) - \(snap.artist)（\(trusted ? "直連" : "網路")，位置 \(String(format: "%.1f", progress)) 秒\(snap.isPlaying ? "" : "，暫停中")）")
            track = snap
            setAnchor(progress, snap.sampledAt, snap.isPlaying)
            behindStreak = 0
            lastDriftMs = 0
            rawLines = []
            lines = []
            currentIndex = -1
            activityIndex = -1
            loadLyrics(for: snap)
            reschedule()
            publishWidget(after: 4) // 一首歌只刷一次：等歌詞抓到；抓不到最多等 4 秒
            return
        }

        track = snap
        let playingBefore = playing
        let drift = progress - position(at: snap.sampledAt)
        lastDriftMs = Int((drift * 1000).rounded())
        var reanchored = false

        if snap.isPlaying != playing {
            setAnchor(progress, snap.sampledAt, snap.isPlaying) // 播放／暫停切換
            reanchored = true
        } else if !playing {
            if abs(drift) > 0.05 { setAnchor(progress, snap.sampledAt, false); reanchored = true }
        } else if trusted {
            // App Remote 的位置是本機即時的，直接採用
            if abs(drift) > 0.04 { setAnchor(progress, snap.sampledAt, true); reanchored = true }
        } else if drift > 0.1 || drift < -2.0 {
            // Web API：比我們快 → 我們之前用到的是舊資料，往前修正
            //          慢超過 2 秒 → 使用者往回拖了進度條
            setAnchor(progress, snap.sampledAt, true)
            behindStreak = 0
            reanchored = true
        } else if drift < -0.6 {
            // 連續 3 次明顯落後才相信（可能是網路卡頓造成真的停頓）
            behindStreak += 1
            if behindStreak >= 3 {
                setAnchor(progress, snap.sampledAt, true)
                behindStreak = 0
                reanchored = true
            }
        } else {
            behindStreak = 0 // 小幅落後：視為伺服器的舊資料，忽略
        }

        if reanchored, abs(drift) > 0.3 || snap.isPlaying != playingBefore {
            DiagLog.log("重新對時：誤差 \(lastDriftMs) ms（\(trusted ? "直連" : "網路")\(snap.isPlaying ? "" : "，暫停")）")
        }
        reschedule()
        if reanchored { publishWidget() }
    }

    private func setAnchor(_ progress: Double, _ date: Date, _ isPlaying: Bool) {
        anchorProgress = progress
        anchorDate = date
        playing = isPlaying
    }

    // MARK: - 歌詞

    private func loadLyrics(for snap: PlaybackSnapshot) {
        lyricsTask?.cancel()
        lyricsStatus = "載入歌詞中…"
        lyricsTask = Task { [weak self] in
            // 防抖：停在同一首 0.35 秒才開始抓歌詞；連續跳歌時中間的歌都不會送出請求
            try? await Task.sleep(nanoseconds: 350_000_000)
            guard let self, !Task.isCancelled else { return }
            let t0 = Date()
            let result = await self.provider.lyrics(for: snap)
            guard !Task.isCancelled, self.track?.trackID == snap.trackID else { return }
            DiagLog.log(result.isEmpty ? "找不到歌詞：\(snap.title)"
                        : "歌詞載入：\(result.count) 句（\(Int(Date().timeIntervalSince(t0) * 1000)) ms）")
            self.rawLines = result
            self.lyricsStatus = result.isEmpty ? "找不到同步歌詞" : ""
            self.rebuildLines()
            self.reschedule()
            self.publishWidget(after: 0.2) // 歌詞到了就刷（會取消上面那個 4 秒的）
            self.finishResyncIfNeeded()
            self.prefetchUpcoming(after: snap.trackID)
        }
    }

    private func rebuildLines() {
        // 歌詞一律顯示繁體：不管 LRCLIB 收的是簡體還是繁體（搜尋時繁簡互查找到的也一樣）
        lines = rawLines.map { LyricLine(time: $0.time, text: LyricsMatcher.toTraditional($0.text)) }
    }

    /// 預抓 Spotify 播放佇列裡接下來幾首的歌詞（存進快取）。
    /// 換歌時歌詞馬上就有，開到沒訊號的地方也不會斷。
    /// 等 5 秒再開始：連續跳歌時不要每首都去問。
    private func prefetchUpcoming(after trackID: String) {
        prefetchTask?.cancel()
        prefetchTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            guard let self, !Task.isCancelled, self.track?.trackID == trackID else { return }
            guard let upcoming = try? await self.client.queue(limit: Self.prefetchCount + 1) else { return }
            var cached = 0, fetched = 0, missing = 0
            for song in upcoming where song.trackID != trackID {
                if Task.isCancelled { return }
                let had = self.provider.hasCached(song.trackID)
                let result = await self.provider.lyrics(for: song)
                if had { cached += 1 } else if result.isEmpty { missing += 1 } else { fetched += 1 }
            }
            if !Task.isCancelled, cached + fetched + missing > 0 {
                DiagLog.log("預抓歌詞：接下來 \(cached + fetched + missing) 首，已有 \(cached)、新抓 \(fetched)、找不到 \(missing)")
            }
        }
    }

    // MARK: - 精準計時

    private func index(for pos: Double) -> Int {
        var lo = 0, hi = lines.count - 1, ans = -1
        while lo <= hi {
            let mid = (lo + hi) / 2
            if lines[mid].time <= pos { ans = mid; lo = mid + 1 } else { hi = mid - 1 }
        }
        return ans
    }

    private func reschedule() {
        lineTimer?.cancel()
        lineTimer = nil

        let pos = position() + AppSettings.shared.offsetMs / 1000
        let idx = index(for: pos)
        let activityPos = pos + Self.activityLead
        activityIndex = index(for: activityPos)
        if idx != currentIndex {
            currentIndex = idx
            // 拿來跟畫面對照：這裡有記但動態島沒動 = iOS 沒顯示更新；這裡也停了 = App 被暫停
            if idx >= 0 { DiagLog.log("第 \(idx + 1)/\(lines.count) 句") }
        }
        activity.update(makeState(), staleDate: staleDateForCurrentLine())

        // 下一次要叫醒的時間：畫面上的下一句，或即時動態的下一句（提早 0.5 秒），取比較早的
        guard playing else { return }
        var waits: [Double] = []
        if idx + 1 < lines.count { waits.append(lines[idx + 1].time - pos) }
        if activityIndex + 1 < lines.count { waits.append(lines[activityIndex + 1].time - activityPos) }
        guard let soonest = waits.min() else { return }
        let wait = max(0.005, soonest)
        let timer = DispatchSource.makeTimerSource(flags: .strict, queue: .main)
        timer.schedule(deadline: .now() + wait, leeway: .milliseconds(2))
        lineTimerDeadline = Date().addingTimeInterval(wait)
        timer.setEventHandler { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                let late = Date().timeIntervalSince(self.lineTimerDeadline)
                if late > 1.5 {
                    DiagLog.log(String(format: "⚠️ 換句計時器晚了 %.1f 秒（App 被系統暫停過）", late))
                }
                self.reschedule()
            }
        }
        timer.resume()
        lineTimer = timer
    }

    // MARK: - 即時動態 / 小工具

    /// 即時動態的「過期時間」：下一句該出現的時間再加 10 秒。
    /// App 如果真的被系統結束，動態島很快就會改顯示「已停止」，不會一直停在舊歌詞上。
    /// 暫停或沒有歌詞時回傳 nil（用預設的 2 分鐘，靠心跳延長）。
    private func staleDateForCurrentLine() -> Date? {
        guard playing, !lines.isEmpty else { return nil }
        let pos = position() + AppSettings.shared.offsetMs / 1000 + Self.activityLead
        let idx = index(for: pos)
        guard idx + 1 < lines.count else { return nil }
        return Date().addingTimeInterval(max(0, lines[idx + 1].time - pos) + 10)
    }

    /// 把整首歌的時間表交給 CarPlay 小工具。
    ///
    /// iOS 會限制 App 要求小工具刷新的次數，用完了系統就不理會，小工具就會卡在舊歌。
    /// 所以這裡盡量省：
    /// - 每首歌只刷一次（等歌詞抓到才刷）
    /// - 連續跳歌時只刷最後停下的那首（防抖）
    /// - 播放位置只差一點點（< 0.5 秒）的對時，不刷
    private func publishWidget(after delay: Double = 0.4, force: Bool = false) {
        var delay = delay
        // 同一首歌的對時修正：至少隔 widgetMinInterval 秒才刷一次。
        // 直連斷斷續續時會一直來回對時，以前每次都 reloadAllTimelines，
        // 系統覺得刷太兇就開始忽略，小工具就停在某一句。換歌、手動調整（force）不受限。
        if !force, track?.trackID == lastWidgetSignature?.trackID, let last = lastWidgetReloadAt {
            delay = max(delay, Self.widgetMinInterval - Date().timeIntervalSince(last))
        }
        widgetTask?.cancel()
        widgetTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard let self, !Task.isCancelled else { return }
            self.writeWidgetNow(force: force)
        }
    }

    /// 上次真的送給小工具的內容摘要，用來判斷這次有沒有必要刷新
    private struct WidgetSignature: Equatable {
        var trackID: String?
        var isPlaying: Bool
        var lineCount: Int
        var message: String
    }
    private var lastWidgetSignature: WidgetSignature?
    private var lastWidgetTrackStart: Date?
    private var lastWidgetReloadAt: Date?
    private static let widgetMinInterval: TimeInterval = 10

    private func writeWidgetNow(force: Bool) {
        let duration = Double(track?.durationMs ?? 0) / 1000
        let message: String
        if track == nil {
            message = "打開 Spotify 播放音樂"
        } else if lines.isEmpty {
            message = lyricsStatus.isEmpty ? (track?.title ?? "") : lyricsStatus
        } else {
            message = ""
        }
        let trackStart = anchorDate.addingTimeInterval(-anchorProgress)
        let signature = WidgetSignature(trackID: track?.trackID, isPlaying: playing,
                                        lineCount: lines.count, message: message)
        if !force, signature == lastWidgetSignature,
           let last = lastWidgetTrackStart, abs(last.timeIntervalSince(trackStart)) < 0.5 {
            return // 內容沒有實質變化，不浪費刷新次數
        }
        lastWidgetSignature = signature
        lastWidgetTrackStart = trackStart
        lastWidgetReloadAt = Date()
        widgetReloads += 1
        DiagLog.log("通知小工具刷新：\(track?.title ?? "沒有播放")（\(lines.count) 句，第 \(widgetReloads) 次）")

        SharedStore.save(.init(
            title: track?.title ?? "",
            artist: track?.artist ?? "",
            isPlaying: playing,
            lines: lines.map { .init(time: $0.time, text: $0.text) },
            trackStart: trackStart,
            pausedPosition: position(),
            duration: duration,
            offset: AppSettings.shared.offsetMs / 1000,
            carFontSize: AppSettings.shared.carFontSize,
            carShowNext: AppSettings.shared.carShowNext,
            message: message,
            lead: Self.carWidgetLead
        ))
        WidgetCenter.shared.reloadAllTimelines()
    }

    func makeState() -> LyricsActivityAttributes.ContentState {
        let title = track?.title ?? "未在播放"
        let artist = track?.artist ?? ""
        var line: String
        var next = ""

        if lines.isEmpty {
            line = track == nil ? "打開 Spotify 播放音樂" : (lyricsStatus.isEmpty ? title : lyricsStatus)
        } else if activityIndex < 0 || activityIndex >= lines.count {
            line = "♪ " + title
            next = lines[0].text
        } else {
            line = lines[activityIndex].text
            if activityIndex + 1 < lines.count { next = lines[activityIndex + 1].text }
        }
        if line.isEmpty { line = "♪" }

        let duration = Double(track?.durationMs ?? 0) / 1000
        // 取整秒，避免微小校正造成不必要的即時動態更新
        let start = Date(timeIntervalSince1970: (anchorDate.timeIntervalSince1970 - anchorProgress).rounded())
        let paused = (!playing && duration > 0) ? min(1, max(0, position() / duration)) : 0

        return .init(
            line: line,
            nextLine: next,
            title: title,
            artist: artist,
            isPlaying: playing,
            trackStart: start,
            trackEnd: start.addingTimeInterval(max(duration, 1)),
            pausedProgress: paused,
            carFontSize: AppSettings.shared.carFontSize,
            carShowNext: AppSettings.shared.carShowNext
        )
    }
}
