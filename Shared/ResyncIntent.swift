import AppIntents

/// 「重新同步」：歌詞卡住、不同步、抓錯歌詞時用。
/// 可以從 Siri（「LyricLane 重新同步」）、捷徑、或 CarPlay 小工具上的 ↻ 觸發。
/// 宣告成 LiveActivityIntent，系統會交給主 App 執行，並允許它重新開啟即時動態。
struct ResyncIntent: LiveActivityIntent {
    static var title: LocalizedStringResource = "重新同步歌詞"
    static var description = IntentDescription("歌詞卡住時使用：重新連線 Spotify、重新抓歌詞、重新開啟即時動態。")
    static var openAppWhenRun = false

    @MainActor
    func perform() async throws -> some IntentResult {
        #if !WIDGET_EXTENSION
        AppModel.shared.engine.resync()
        #endif
        return .result()
    }
}
