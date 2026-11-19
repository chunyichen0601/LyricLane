import Foundation

/// App 與 CarPlay 小工具之間共用的資料（透過 App Group）。
/// App 每首歌只寫一次「整首歌的時間表」，小工具自己照時間表換句，
/// 不需要 App 每句都去更新，所以不會有更新延遲或次數限制。
enum SharedStore {
    static let widgetKind = "CarLyrics"
    private static let defaultGroup = "group.com.example.dynlyrics"
    private static let key = "nowPlaying"

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
        /// 小工具上是否顯示 🐢／🐇 微調按鈕（舊資料沒有這欄，所以是 Optional）
        var showAdjustButtons: Bool?
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

    static var isAvailable: Bool {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: groupID) != nil
    }

    static func save(_ value: NowPlaying) {
        guard let d = UserDefaults(suiteName: groupID),
              let data = try? JSONEncoder().encode(value) else { return }
        d.set(data, forKey: key)
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
        guard let data = UserDefaults(suiteName: groupID)?.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(NowPlaying.self, from: data)
    }
}
