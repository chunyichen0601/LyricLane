import Foundation
import SpotifyiOS

/// Spotify App Remote：直接跟「手機上的 Spotify App」溝通，不經過網路。
/// 播放、暫停、拖進度、換歌都會即時推送事件，播放位置幾乎沒有延遲。
/// 連不上時（例如 Spotify 沒在執行），SyncEngine 會自動退回 Web API。
@MainActor
final class SpotifyRemote: NSObject {
    enum Status: Equatable {
        case idle
        case connecting
        case connected
        case failed(String)
    }

    private(set) var status: Status = .idle
    var onSnapshot: (@MainActor (PlaybackSnapshot) -> Void)?
    var onStatusChange: (@MainActor (Status) -> Void)?

    private var appRemote: SPTAppRemote?
    private var refreshTimer: Timer?
    private var lastAttempt = Date.distantPast

    var isConnected: Bool { appRemote?.isConnected == true }

    /// 最後一次收到 Spotify 狀態的時間（用來判斷直連是否「連著但卡住」）
    private(set) var lastEventAt = Date.distantPast
    /// 最後一次收到 Spotify「主動推送」事件的時間
    private var lastPushAt = Date.distantPast

    /// 連著，而且最近 15 秒內有收到狀態（每 5 秒會主動問一次）
    var isHealthy: Bool {
        isConnected && Date().timeIntervalSince(lastEventAt) < 15
    }

    func connect(clientID: String, token: String) {
        guard !isConnected else { return }
        // 卡在「連線中」超過 15 秒：視為失敗，丟掉重來（避免永遠等下去）
        if status == .connecting {
            guard Date().timeIntervalSince(lastAttempt) > 15 else { return }
            appRemote?.playerAPI?.delegate = nil
            appRemote?.delegate = nil
            appRemote?.disconnect()
            setStatus(.failed("連線逾時"))
            DiagLog.log("直連：連線逾時（15 秒）")
        }
        // 失敗後至少隔 10 秒再試，避免一直重連
        guard Date().timeIntervalSince(lastAttempt) > 10 else { return }
        lastAttempt = Date()

        let config = SPTConfiguration(clientID: clientID, redirectURL: URL(string: SpotifyAuth.redirectURI)!)
        let remote = SPTAppRemote(configuration: config, logLevel: .error)
        remote.connectionParameters.accessToken = token
        remote.delegate = self
        appRemote = remote
        setStatus(.connecting)
        DiagLog.log("直連：嘗試連線 Spotify")
        remote.connect()
    }

    /// 重新同步時呼叫：取消「失敗後 10 秒內不重試」的限制
    func resetBackoff() {
        lastAttempt = .distantPast
    }

    func disconnect() {
        refreshTimer?.invalidate()
        refreshTimer = nil
        // 先拔掉 delegate：舊連線之後才回來的「已中斷」通知不能影響新連線
        appRemote?.playerAPI?.delegate = nil
        appRemote?.delegate = nil
        appRemote?.disconnect()
        appRemote = nil
        setStatus(.idle)
    }

    private func setStatus(_ s: Status) {
        status = s
        onStatusChange?(s)
    }

    /// 主動問一次目前狀態（本機 IPC，來回只要幾毫秒）
    private func requestState() {
        let t0 = Date()
        appRemote?.playerAPI?.getPlayerState { [weak self] result, _ in
            let t1 = Date()
            guard let state = result as? SPTAppRemotePlayerState else { return }
            let mid = t0.addingTimeInterval(t1.timeIntervalSince(t0) / 2)
            Task { @MainActor in
                // 送出詢問後又收到了新的事件（例如剛好跳歌）→ 這個回應已經過期，丟掉
                guard let self, self.lastPushAt < t0 else { return }
                self.emit(state, at: mid, latency: t1.timeIntervalSince(t0))
            }
        }
    }

    private func emit(_ s: SPTAppRemotePlayerState, at date: Date, latency: Double) {
        lastEventAt = Date()
        let track = s.track
        let snap = PlaybackSnapshot(
            trackID: track.uri,
            title: track.name,
            artist: track.artist.name,
            primaryArtist: track.artist.name,
            album: track.album.name,
            durationMs: Int(track.duration),
            progressMs: s.playbackPosition,
            isPlaying: !s.isPaused,
            sampledAt: date,
            latency: latency
        )
        onSnapshot?(snap)
    }

    fileprivate func didConnect(_ remote: SPTAppRemote) {
        guard remote === appRemote else { return } // 過期的連線
        DiagLog.log("直連：已連上")
        lastEventAt = Date() // 給第一次狀態回來的緩衝時間
        setStatus(.connected)
        remote.playerAPI?.delegate = self
        remote.playerAPI?.subscribe(toPlayerState: { _, _ in })
        requestState()
        // 事件推送之外，每 5 秒再對時一次
        refreshTimer?.invalidate()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.requestState() }
        }
    }

    fileprivate func didDrop(_ remote: SPTAppRemote, _ message: String) {
        // 以前沒有檢查是哪一條連線：舊連線晚到的「已中斷」會把新連線的
        // 5 秒對時計時器關掉，直連就會每 15 秒左右斷一次、反覆重連，歌詞一直被重新對時。
        guard remote === appRemote else {
            DiagLog.log("直連：忽略舊連線的通知（\(message)）")
            return
        }
        DiagLog.log("直連：中斷（\(message)）")
        refreshTimer?.invalidate()
        refreshTimer = nil
        setStatus(.failed(message))
    }
}

extension SpotifyRemote: SPTAppRemoteDelegate, SPTAppRemotePlayerStateDelegate {
    nonisolated func appRemoteDidEstablishConnection(_ appRemote: SPTAppRemote) {
        Task { @MainActor in self.didConnect(appRemote) }
    }

    nonisolated func appRemote(_ appRemote: SPTAppRemote, didFailConnectionAttemptWithError error: Error?) {
        let msg = error?.localizedDescription ?? "連線失敗"
        Task { @MainActor in self.didDrop(appRemote, msg) }
    }

    nonisolated func appRemote(_ appRemote: SPTAppRemote, didDisconnectWithError error: Error?) {
        let msg = error?.localizedDescription ?? "已中斷"
        Task { @MainActor in self.didDrop(appRemote, msg) }
    }

    nonisolated func playerStateDidChange(_ playerState: SPTAppRemotePlayerState) {
        let now = Date() // 事件到達的瞬間就記時間，避免排隊造成誤差
        Task { @MainActor in
            self.lastPushAt = now
            self.emit(playerState, at: now, latency: 0)
        }
    }
}
