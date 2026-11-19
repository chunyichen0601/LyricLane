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

    func connect(clientID: String, token: String) {
        guard !isConnected, status != .connecting else { return }
        // 失敗後至少隔 10 秒再試，避免一直重連
        guard Date().timeIntervalSince(lastAttempt) > 10 else { return }
        lastAttempt = Date()

        let config = SPTConfiguration(clientID: clientID, redirectURL: URL(string: SpotifyAuth.redirectURI)!)
        let remote = SPTAppRemote(configuration: config, logLevel: .error)
        remote.connectionParameters.accessToken = token
        remote.delegate = self
        appRemote = remote
        setStatus(.connecting)
        remote.connect()
    }

    func disconnect() {
        refreshTimer?.invalidate()
        refreshTimer = nil
        appRemote?.disconnect()
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
            Task { @MainActor in self?.emit(state, at: mid, latency: t1.timeIntervalSince(t0)) }
        }
    }

    private func emit(_ s: SPTAppRemotePlayerState, at date: Date, latency: Double) {
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

    fileprivate func didDrop(_ message: String) {
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
        Task { @MainActor in self.didDrop(msg) }
    }

    nonisolated func appRemote(_ appRemote: SPTAppRemote, didDisconnectWithError error: Error?) {
        let msg = error?.localizedDescription ?? "已中斷"
        Task { @MainActor in self.didDrop(msg) }
    }

    nonisolated func playerStateDidChange(_ playerState: SPTAppRemotePlayerState) {
        let now = Date() // 事件到達的瞬間就記時間，避免排隊造成誤差
        Task { @MainActor in self.emit(playerState, at: now, latency: 0) }
    }
}
