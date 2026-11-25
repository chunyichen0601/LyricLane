import AVFoundation

/// 播放無聲音訊（與 Spotify 混音，不會打斷它），讓 App 能在背景持續執行，
/// 才能在每一句歌詞的時間點即時更新即時動態。
final class KeepAlive {
    static let shared = KeepAlive()

    private var engine: AVAudioEngine?
    private var player: AVAudioPlayerNode?
    private var observers: [NSObjectProtocol] = []
    private(set) var isRunning = false
    /// 上次重新啟動的時間：避免「音訊裝置變更 → 重啟 → 又觸發變更」的循環一直燒 CPU
    private var lastRestart = Date.distantPast
    private static let minRestartInterval: TimeInterval = 10

    private init() {
        let nc = NotificationCenter.default
        observers.append(nc.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] note in
            guard let self, self.isRunning,
                  let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
            if type == .began {
                DiagLog.log("背景音訊被打斷（Siri／導航語音／電話？）")
                return
            }
            self.restart(reason: "打斷結束")
        })
        observers.append(nc.addObserver(forName: .AVAudioEngineConfigurationChange, object: nil, queue: .main) { [weak self] _ in
            guard let self, self.isRunning else { return }
            self.restart(reason: "音訊裝置變更") // 例如接上 / 拔掉 CarPlay、藍牙切換
        })
        observers.append(nc.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification, object: nil, queue: .main) { [weak self] _ in
            guard let self, self.isRunning else { return }
            self.restart(reason: "系統音訊服務重設")
        })
    }

    func start() {
        guard !isRunning else { return }
        isRunning = true
        DiagLog.log("背景音訊：啟動")
        startEngine()
    }

    func stop() {
        DiagLog.log("背景音訊：停止")
        isRunning = false
        teardown()
        try? AVAudioSession.sharedInstance().setActive(false)
    }

    /// 看門狗：背景音訊停了就重新啟動。
    /// 被 Siri、導航語音、電話打斷後，iOS 不保證一定會送「打斷結束」通知；
    /// 沒收到的話無聲音訊就一直停著，App 幾十秒後被暫停，動態島的歌詞就卡在那一句。
    func ensureRunning() {
        guard isRunning, engine?.isRunning != true else { return }
        restart(reason: "看門狗發現背景音訊停了")
    }

    /// 重新建立背景音訊（重新同步時也會用到）
    func restart(reason: String = "重新同步") {
        // 10 秒內最多重啟一次（CarPlay、藍牙切換時系統會連發好幾個通知）
        guard Date().timeIntervalSince(lastRestart) > Self.minRestartInterval else { return }
        lastRestart = Date()
        DiagLog.log("背景音訊：重新啟動（\(reason)）")
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
            DiagLog.log("背景音訊啟動失敗：\(error.localizedDescription)，5 秒後重試")
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
                guard let self, self.isRunning, self.engine == nil else { return }
                self.startEngine()
            }
        }
    }
}
