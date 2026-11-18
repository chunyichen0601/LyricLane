import AppIntents

// 與 Apple 體系整合：Siri 語音、捷徑 App、捷徑自動化（例如「連接 CarPlay 時」）
// LiveActivityIntent 讓系統允許在背景啟動即時動態，不必先打開 App。

struct StartLyricsIntent: LiveActivityIntent {
    static var title: LocalizedStringResource = "開始顯示歌詞"
    static var description = IntentDescription("同步 Spotify 正在播放的歌詞，顯示在 CarPlay、動態島與鎖定畫面。")
    static var openAppWhenRun = false

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let ok = AppModel.shared.engine.startFromIntent()
        return .result(dialog: ok ? "歌詞已開始顯示" : "請先打開 LyricLane 登入 Spotify")
    }
}

struct StopLyricsIntent: LiveActivityIntent {
    static var title: LocalizedStringResource = "停止顯示歌詞"
    static var description = IntentDescription("關閉歌詞即時動態並停止背景同步。")
    static var openAppWhenRun = false

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        AppModel.shared.engine.stopFromIntent()
        return .result(dialog: "歌詞已關閉")
    }
}

/// 不用設定就會自動出現在「捷徑」App 與 Siri 裡
struct LyricLaneShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: StartLyricsIntent(),
            phrases: [
                "用\(.applicationName)顯示歌詞",
                "\(.applicationName)開始",
                "Start \(.applicationName)",
            ],
            shortTitle: "開始顯示歌詞",
            systemImageName: "music.note"
        )
        AppShortcut(
            intent: StopLyricsIntent(),
            phrases: [
                "用\(.applicationName)關閉歌詞",
                "\(.applicationName)停止",
                "Stop \(.applicationName)",
            ],
            shortTitle: "停止顯示歌詞",
            systemImageName: "stop.fill"
        )
    }
}
