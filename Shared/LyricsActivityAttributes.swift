import ActivityKit
import Foundation

/// App 與 Widget 共用的即時動態資料。
struct LyricsActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        var line: String
        var nextLine: String
        var title: String
        var artist: String
        var isPlaying: Bool
        /// 對應歌曲 0 秒的時間點（給進度條自動前進用，不需要每秒更新）
        var trackStart: Date
        var trackEnd: Date
        /// 暫停時顯示的進度 0...1
        var pausedProgress: Double
        /// CarPlay 歌詞字級（pt）。空間不夠時會自動縮小，不會被截斷
        var carFontSize: Double
        /// CarPlay 是否顯示下一句（關閉可讓目前這句更大）
        var carShowNext: Bool
        /// 每次送出就 +1，用來確認 iOS 有沒有真的套用／畫出來（診斷用，由 LiveActivityManager 填）
        var seq: Int = 0
    }
}
