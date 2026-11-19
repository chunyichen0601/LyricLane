import AVFoundation

/// 播放無聲音訊（與 Spotify 混音，不會打斷它），讓 App 能在背景持續執行，
/// 才能在每一句歌詞的時間點即時更新即時動態。
final class KeepAlive {
    static let shared = KeepAlive()

    private var engine: AVAudioEngine?
    private var player: AVAudioPlayerNode?
    private var observers: [NSObjectProtocol] = []
    private(set) var isRunning = false

    private init() {
        let nc = NotificationCenter.default
        observers.append(nc.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] note in
            guard let self, self.isRunning,
                  let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  AVAudioSession.InterruptionType(rawValue: raw) == .ended else { return }
            self.restart()
        })
        observers.append(nc.addObserver(forName: .AVAudioEngineConfigurationChange, object: nil, queue: .main) { [weak self] _ in
            guard let self, self.isRunning else { return }
            self.restart() // 例如接上 / 拔掉 CarPlay、藍牙切換
        })
        observers.append(nc.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification, object: nil, queue: .main) { [weak self] _ in
            guard let self, self.isRunning else { return }
            self.restart()
        })
    }

    func start() {
        guard !isRunning else { return }
        isRunning = true
        startEngine()
    }

    func stop() {
        isRunning = false
        teardown()
        try? AVAudioSession.sharedInstance().setActive(false)
    }

    /// 重新建立背景音訊（重新同步時也會用到）
    func restart() {
        isRunning = true
        teardown()
        startEngine()
    }

    private func teardown() {
        player?.stop()
        engine?.stop()
        player = nil
        engine = nil
    }

    private func startEngine() {
        do {
            let s = AVAudioSession.sharedInstance()
            try s.setCategory(.playback, mode: .default, options: [.mixWithOthers])
            try s.setActive(true)

            let engine = AVAudioEngine()
            let player = AVAudioPlayerNode()
            let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 2)!
            engine.attach(player)
            engine.connect(player, to: engine.mainMixerNode, format: format)

            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 44_100) else { return }
            buffer.frameLength = buffer.frameCapacity
            for ch in 0..<Int(format.channelCount) {
                buffer.floatChannelData?[ch].update(repeating: 0, count: Int(buffer.frameLength))
            }

            try engine.start()
            player.scheduleBuffer(buffer, at: nil, options: .loops)
            player.play()
            self.engine = engine
            self.player = player
        } catch {
            print("KeepAlive 啟動失敗：\(error)")
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
                guard let self, self.isRunning, self.engine == nil else { return }
                self.startEngine()
            }
        }
    }
}
