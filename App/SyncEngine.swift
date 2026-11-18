import Foundation

/// 核心同步引擎：
/// 1. 每 ~3 秒向 Spotify 取一次播放進度（只用來校正，不靠它計時）
/// 2. 在本機用「錨點 + 經過時間」推算目前播放位置
/// 3. 用精準計時器在「下一句歌詞的時間點」觸發，立刻更新即時動態
@MainActor
final class SyncEngine: ObservableObject {
    @Published private(set) var track: PlaybackSnapshot?
    @Published private(set) var lines: [LyricLine] = []
    @Published private(set) var currentIndex = -1
    @Published private(set) var status = "尚未開始"
    @Published private(set) var lyricsStatus = ""
    @Published private(set) var isRunning = false
    @Published private(set) var activityRunning = false

    private let auth: SpotifyAuth
    private let client: SpotifyClient
    private let provider = LyricsProvider()
    private let activity = LiveActivityManager()
    private var rawLines: [LyricLine] = []

    // 計時錨點：在 anchorDate 這個時間，歌曲播放到 anchorProgress 秒
    private var anchorProgress = 0.0
    private var anchorDate = Date()
    private var playing = false

    private var pollTask: Task<Void, Never>?
    private var lyricsTask: Task<Void, Never>?
    private var lineTimer: DispatchSourceTimer?

    init(auth: SpotifyAuth) {
        self.auth = auth
        self.client = SpotifyClient(auth: auth)
    }

    func position(at date: Date = Date()) -> Double {
        playing ? anchorProgress + date.timeIntervalSince(anchorDate) : anchorProgress
    }

    // MARK: - 生命週期

    func appBecameActive() {
        guard auth.isLoggedIn else { return }
        start()
        if activity.isActive {
            activityRunning = true
        } else {
            startActivity() // 例如超過 8 小時被系統結束後，打開 App 會自動重開
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
        KeepAlive.shared.stop()
        isRunning = false
        status = "已停止"
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
        startActivity()
        return activityRunning
    }

    func stopFromIntent() {
        endActivity()
        stop()
    }

    func settingsChanged() {
        rebuildLines()
        reschedule()
    }

    // MARK: - 輪詢 Spotify

    /// 回傳下次輪詢前要等幾秒
    private func pollOnce() async -> Double {
        guard auth.isLoggedIn else {
            status = "請先登入 Spotify"
            return 3
        }
        do {
            guard let snap = try await client.currentlyPlaying() else {
                handleIdle()
                return 5
            }
            apply(snap)
            status = snap.isPlaying ? "同步中" : "已暫停"
            guard snap.isPlaying else { return 3 }
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

    private func handleIdle() {
        status = "目前沒有播放"
        if playing {
            anchorProgress = position()
            anchorDate = Date()
            playing = false
        }
        reschedule()
    }

    private func apply(_ snap: PlaybackSnapshot) {
        let progress = Double(snap.progressMs) / 1000

        if snap.trackID != track?.trackID {
            track = snap
            setAnchor(progress, snap.sampledAt, snap.isPlaying)
            rawLines = []
            lines = []
            currentIndex = -1
            loadLyrics(for: snap)
            reschedule()
            return
        }

        track = snap
        let drift = progress - position(at: snap.sampledAt)
        if snap.isPlaying != playing || abs(drift) > 0.4 {
            // 暫停、播放、拖進度條：直接重設錨點
            setAnchor(progress, snap.sampledAt, snap.isPlaying)
        } else if playing {
            // 小誤差：慢慢修正，避免網路抖動造成歌詞跳動
            anchorProgress += drift * 0.3
        }
        reschedule()
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
            guard let self else { return }
            let result = await self.provider.lyrics(for: snap)
            guard !Task.isCancelled, self.track?.trackID == snap.trackID else { return }
            self.rawLines = result
            self.lyricsStatus = result.isEmpty ? "找不到同步歌詞" : ""
            self.rebuildLines()
            self.reschedule()
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
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + wait, leeway: .milliseconds(5))
        timer.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.reschedule() }
        }
        timer.resume()
        lineTimer = timer
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
