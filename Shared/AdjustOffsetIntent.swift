import AppIntents

/// 小工具上的「🐢 / 🐇」微調按鈕。
/// 宣告成 LiveActivityIntent，系統會把它交給「主 App」執行（不是小工具），
/// 所以能直接改到正在背景同步的引擎，立刻生效。
struct AdjustOffsetIntent: LiveActivityIntent {
    static var title: LocalizedStringResource = "微調歌詞時間"
    static var description = IntentDescription("讓歌詞提早或延後 100 毫秒。")
    static var isDiscoverable = false

    @Parameter(title: "毫秒")
    var delta: Int

    init() {}

    init(delta: Int) {
        self.delta = delta
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        #if !WIDGET_EXTENSION
        let s = AppSettings.shared
        s.offsetMs = min(1500, max(-1500, s.offsetMs + Double(delta)))
        AppModel.shared.engine.settingsChanged()
        #endif
        return .result()
    }
}
