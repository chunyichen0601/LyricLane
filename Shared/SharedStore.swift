import Foundation

/// App 與 CarPlay 小工具之間共用的資料（透過 App Group）。
/// App 每首歌只寫一次「整首歌的時間表」，小工具自己照時間表換句，
/// 不需要 App 每句都去更新，所以不會有更新延遲或次數限制。
enum SharedStore {
    static let widgetKind = "CarLyrics"
    static let widgetKindInfo = "CarLyricsInfo"
    static let widgetKindAdjust = "CarLyricsAdjust"
    private static let defaultGroup = "group.com.example.dynlyrics"

    struct Line: Codable, Hashable {
        var time: Double
        var text: String
    }

    struct NowPlaying: Codable {
        var title: String
        var artist: String
        var isPlaying: Bool
        var lines: [Line]
        /// 歌曲 0 秒對應的時間點（播放中才有意義）
        var trackStart: Date
        /// 暫停時的播放位置（秒）
        var pausedPosition: Double
        var duration: Double
        /// 歌詞提早量（秒）
        var offset: Double
        var carFontSize: Double
        var carShowNext: Bool
        /// 沒有歌詞時要顯示的文字
        var message: String
        /// CarPlay 小工具額外提早的秒數（CarPlay 換時間點本來就會晚一點）
        var lead: Double?
    }

    /// SideStore／AltStore 用免費帳號簽名時會改掉 App Group 名稱，
    /// 並把真正的名稱寫進 Info.plist 的 ALTAppGroups；先找它，找不到才用預設值。
    static let groupID: String = {
        func groups(at bundleURL: URL) -> [String]? {
            let dict = NSDictionary(contentsOf: bundleURL.appendingPathComponent("Info.plist")) as? [String: Any]
            return dict?["ALTAppGroups"] as? [String]
        }
        let me = Bundle.main.bundleURL
        // 小工具在 App.app/PlugIns/X.appex 裡，往上兩層就是主 App
        let host = me.deletingLastPathComponent().deletingLastPathComponent()
        for url in [me, host] {
            if let g = groups(at: url), let first = g.first(where: { $0.contains("dynlyrics") }) ?? g.first {
                return first
            }
        }
        return defaultGroup
    }()

    static var isAvailable: Bool { containerURL != nil }

    static var containerURL: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: groupID)
    }

    // 用「檔案」而不是 UserDefaults 交換資料：
    // UserDefaults 跨程式（App ↔ 小工具）可能讀到快取的舊值，檔案每次讀都是最新的。
    private static var nowPlayingURL: URL? { containerURL?.appendingPathComponent("nowPlaying.json") }
    private static var widgetStatusURL: URL? { containerURL?.appendingPathComponent("widgetStatus.json") }

    static func save(_ value: NowPlaying) {
        guard let url = nowPlayingURL, let data = try? JSONEncoder().encode(value) else { return }
        try? data.write(to: url, options: .atomic)
    }

    // MARK: - 小工具診斷：小工具每次真的被系統叫起來重算時記一筆

    struct WidgetStatus: Codable {
        var lastTimelineAt: Date
        var title: String
        var entries: Int
    }

    // MARK: - 即時動態「畫出來了沒」：小工具擴充功能在畫即時動態時記下序號

    struct DrawProbe: Codable {
        var carPlaySeq = 0
        var carPlayAt = Date.distantPast
        var otherSeq = 0
        var otherAt = Date.distantPast
    }

    private static var drawProbeURL: URL? { containerURL?.appendingPathComponent("drawProbe.json") }

    /// 在即時動態畫面的 body 裡呼叫（side effect，只有寫一個小檔案）
    @discardableResult
    static func recordDraw(seq: Int, carPlay: Bool) -> Bool {
        guard seq > 0, let url = drawProbeURL else { return false }
        var p = loadDrawProbe() ?? DrawProbe()
        if carPlay {
            guard seq > p.carPlaySeq else { return false }
            p.carPlaySeq = seq
            p.carPlayAt = Date()
        } else {
            guard seq > p.otherSeq else { return false }
            p.otherSeq = seq
            p.otherAt = Date()
        }
        guard let data = try? JSONEncoder().encode(p) else { return false }
        try? data.write(to: url, options: .atomic)
        return true
    }

    static func loadDrawProbe() -> DrawProbe? {
        guard let url = drawProbeURL, let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(DrawProbe.self, from: data)
    }

    static func resetDrawProbe() {
        guard let url = drawProbeURL else { return }
        try? FileManager.default.removeItem(at: url)
    }

    static func saveWidgetStatus(_ s: WidgetStatus) {
        guard let url = widgetStatusURL, let data = try? JSONEncoder().encode(s) else { return }
        try? data.write(to: url, options: .atomic)
    }

    static func loadWidgetStatus() -> WidgetStatus? {
        guard let url = widgetStatusURL, let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(WidgetStatus.self, from: data)
    }

    /// App 被關閉：小工具改顯示「已關閉」
    static func markClosed() {
        guard var np = load() else { return }
        np.isPlaying = false
        np.lines = []
        np.message = "LyricLane 已關閉"
        save(np)
    }

    static func load() -> NowPlaying? {
        guard let url = nowPlayingURL, let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(NowPlaying.self, from: data)
    }
}
