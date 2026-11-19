import AppIntents

// 與 Apple 體系整合：Siri 語音、捷徑 App、捷徑自動化（例如「連接 CarPlay 時」）
// LiveActivityIntent 讓系統允許在背景啟動即時動態，不必先打開 App。

struct StartLyricsIntent: LiveActivityIntent {
    static var title: LocalizedStringResource = "開始顯示歌詞"
    static var description = IntentDescription("開始同步 Spotify 歌詞，更新 CarPlay 小工具（若在設定中開啟，也會顯示即時動態）。")
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

// MARK: - CarPlay 上車／下車（給「捷徑 › 自動化 › CarPlay」用）
// 不回傳對話框，避免在車上被 Siri 念出來。

struct CarPlayArriveIntent: LiveActivityIntent {
    static var title: LocalizedStringResource = "上車：開始歌詞＋打開 Spotify"
    static var description = IntentDescription("開始同步歌詞（更新 CarPlay 小工具），並打開 Spotify。")
    static var openAppWhenRun = false

    @MainActor
    func perform() async throws -> some IntentResult & OpensIntent {
        _ = AppModel.shared.engine.startFromIntent()
        return .result(opensIntent: OpenURLIntent(URL(string: "spotify:")!))
    }
}

struct CarPlayLeaveIntent: LiveActivityIntent {
    static var title: LocalizedStringResource = "下車：關閉 LyricLane"
    static var description = IntentDescription("關閉歌詞與即時動態、停止背景同步。Spotify 不受影響。")
    static var openAppWhenRun = false

    @MainActor
    func perform() async throws -> some IntentResult {
        AppModel.shared.engine.stopFromIntent()
        return .result()
    }
}

/// 不用設定就會自動出現在「捷徑」App 與 Siri 裡
struct LyricLaneShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: ResyncIntent(),
            phrases: [
                "\(.applicationName)重新同步",
                "用\(.applicationName)重新同步歌詞",
                "Resync \(.applicationName)",
            ],
            shortTitle: "重新同步歌詞",
            systemImageName: "arrow.clockwise"
        )
        AppShortcut(
            intent: CarPlayArriveIntent(),
            phrases: [
                "\(.applicationName)上車",
                "Drive with \(.applicationName)",
            ],
            shortTitle: "上車：歌詞＋Spotify",
            systemImageName: "car.fill"
        )
        AppShortcut(
            intent: CarPlayLeaveIntent(),
            phrases: [
                "\(.applicationName)下車",
                "Park \(.applicationName)",
            ],
            shortTitle: "下車：關閉 LyricLane",
            systemImageName: "parkingsign.circle.fill"
        )
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
