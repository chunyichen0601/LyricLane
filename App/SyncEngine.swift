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
        } else if AppSettings.shared.autoLiveActivity {
            startActivity() // 只有使用者選擇「自動開啟」才會出現在動態島
        }
    }

    func start() {
        guard pollTask == nil else { return }
        KeepAlive.shared.start()
        isRunning = true
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let delay = await self?.pollOnce() else { return }
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            }
        }
    }

    func stop() {
        pollTask?.cancel()
        pollTask = nil
        lineTimer?.cancel()
        lineTimer = nil
        remote.disconnect()
        KeepAlive.shared.stop()
        isRunning = false
        status = "已停止"
        updateSourceLabel()
    }

    func startActivity() {
        do {
            try activity.start(state: makeState())
            activityRunning = true
        } catch {
            activityRunning = false
            status = "無法啟動即時動態：\(error.localizedDescription)"
        }
    }

    func endActivity() {
        activity.end()
        activityRunning = false
    }

    /// 給 Siri／捷徑／CarPlay 自動化呼叫（可在背景執行）
    func startFromIntent() -> Bool {
        guard auth.isLoggedIn else { return false }
        start()
        if AppSettings.shared.autoLiveActivity { startActivity() }
        publishWidget()
        return true
    }

    func stopFromIntent() {
        endActivity()
        stop()
        SharedStore.markClosed()
        WidgetCenter.shared.reloadAllTimelines()
    }

    func settingsChanged() {
        rebuildLines()
        reschedule()
        publishWidget()
    }

    // MARK: - 取得播放位置

    /// 回傳下次輪詢前要等幾秒
    private func pollOnce() async -> Double {
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
            return Double(max(seconds, 1))
        } catch {
            status = "連線錯誤：\(error.localizedDescription)"
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
        status = "目前沒有播放"
        if playing {
            anchorProgress = position()
            anchorDate = Date()
            playing = false
        }
        reschedule()
        publishWidget()
    }

    /// trusted = true：來自 App Remote（本機，準確）
    /// trusted = false：來自 Web API（伺服器資料可能是舊的，只會讓進度看起來「落後」）
    private func ingest(_ snap: PlaybackSnapshot, trusted: Bool) {
        let progress = Double(snap.progressMs) / 1000
        latencyMs = Int((snap.latency * 1000).rounded())

        if snap.trackID != track?.trackID {
            track = snap
            setAnchor(progress, snap.sampledAt, snap.isPlaying)
            behindStreak = 0
            lastDriftMs = 0
            rawLines = []
            lines = []
            currentIndex = -1
            loadLyrics(for: snap)
            reschedule()
            publishWidget()
            return
        }

        track = snap
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
            let result = await self.provider.lyrics(for: snap)
            guard !Task.isCancelled, self.track?.trackID == snap.trackID else { return }
            self.rawLines = result
            self.lyricsStatus = result.isEmpty ? "找不到同步歌詞" : ""
            self.rebuildLines()
            self.reschedule()
            self.publishWidget()
        }
    }

    private func rebuildLines() {
        guard AppSettings.shared.toTraditional else { lines = rawLines; return }
        let toHant = StringTransform("Hans-Hant")
        lines = rawLines.map {
            LyricLine(time: $0.time, text: $0.text.applyingTransform(toHant, reverse: false) ?? $0.text)
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
        if idx != currentIndex { currentIndex = idx }
        activity.update(makeState())

        guard playing, idx + 1 < lines.count else { return }
        let wait = max(0.005, lines[idx + 1].time - pos)
        let timer = DispatchSource.makeTimerSource(flags: .strict, queue: .main)
        timer.schedule(deadline: .now() + wait, leeway: .milliseconds(2))
        timer.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.reschedule() }
        }
        timer.resume()
        lineTimer = timer
    }

    // MARK: - 即時動態 / 小工具

    /// 把整首歌的時間表交給 CarPlay 小工具（只在換歌、對時、暫停播放時呼叫）。
    /// 防抖 0.4 秒：連續跳歌時只送最後一首，避免小工具被反覆刷新而被系統限制。
    private func publishWidget() {
        widgetTask?.cancel()
        widgetTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 400_000_000)
            guard let self, !Task.isCancelled else { return }
            self.writeWidgetNow()
        }
    }

    private func writeWidgetNow() {
        let duration = Double(track?.durationMs ?? 0) / 1000
        let message: String
        if track == nil {
            message = "打開 Spotify 播放音樂"
        } else if lines.isEmpty {
            message = lyricsStatus.isEmpty ? (track?.title ?? "") : lyricsStatus
        } else {
            message = ""
        }
        SharedStore.save(.init(
            title: track?.title ?? "",
            artist: track?.artist ?? "",
            isPlaying: playing,
            lines: lines.map { .init(time: $0.time, text: $0.text) },
            trackStart: anchorDate.addingTimeInterval(-anchorProgress),
            pausedPosition: position(),
            duration: duration,
            offset: AppSettings.shared.offsetMs / 1000,
            carFontSize: AppSettings.shared.carFontSize,
            carShowNext: AppSettings.shared.carShowNext,
            message: message
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
        } else if currentIndex < 0 {
            line = "♪ " + title
            next = lines[0].text
        } else {
            line = lines[currentIndex].text
            if currentIndex + 1 < lines.count { next = lines[currentIndex + 1].text }
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
