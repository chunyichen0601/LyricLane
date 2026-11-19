import SwiftUI
import WidgetKit

/// CarPlay 小工具頁（iOS 26）與 iPhone 主畫面的小型小工具。
/// App 每首歌只交一次「整首歌時間表」，這裡把每一句排成一個 timeline entry，
/// 由系統在每句的時間點自動切換，不需要 App 一直更新。
struct CarLyricsWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: SharedStore.widgetKind, provider: CarLyricsProvider()) { entry in
            CarLyricsView(entry: entry)
                .containerBackground(for: .widget) { Color.black }
        }
        .configurationDisplayName("LyricLane 歌詞")
        .description("顯示 Spotify 正在播放的同步歌詞，也可以放在 CarPlay 小工具頁。")
        .supportedFamilies([.systemSmall])
        .contentMarginsDisabled()
    }
}

struct CarLyricsEntry: TimelineEntry {
    let date: Date
    let line: String
    let next: String
    let fontSize: Double
    let showNext: Bool
    let isPlaying: Bool
}

struct CarLyricsProvider: TimelineProvider {
    func placeholder(in context: Context) -> CarLyricsEntry {
        CarLyricsEntry(date: Date(), line: "♪ LyricLane", next: "", fontSize: 26, showNext: false, isPlaying: false)
    }

    func getSnapshot(in context: Context, completion: @escaping (CarLyricsEntry) -> Void) {
        completion(Self.entries(from: SharedStore.load(), now: Date(), limit: 1).first ?? placeholder(in: context))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<CarLyricsEntry>) -> Void) {
        let now = Date()
        let np = SharedStore.load()
        let entries = Self.entries(from: np, now: now, limit: 180)
        // 歌曲結束後請系統再要一次（App 換歌時也會主動通知）
        var policy: TimelineReloadPolicy = .never
        if let np, np.isPlaying, np.duration > 0 {
            policy = .after(np.trackStart.addingTimeInterval(np.duration + 1))
        }
        completion(Timeline(entries: entries, policy: policy))
    }

    static func entries(from np: SharedStore.NowPlaying?, now: Date, limit: Int) -> [CarLyricsEntry] {
        guard let np else {
            let msg = SharedStore.isAvailable ? "打開 LyricLane" : "請用 SideStore 重新安裝 LyricLane"
            return [CarLyricsEntry(date: now, line: msg, next: "", fontSize: 22, showNext: false, isPlaying: false)]
        }

        func make(_ date: Date, _ idx: Int) -> CarLyricsEntry {
            var line: String
            var next = ""
            if np.lines.isEmpty {
                line = np.message.isEmpty ? np.title : np.message
            } else if idx < 0 {
                line = "♪ " + np.title
                next = np.lines[0].text
            } else {
                line = np.lines[idx].text
                if idx + 1 < np.lines.count { next = np.lines[idx + 1].text }
            }
            if line.isEmpty { line = "♪" }
            return CarLyricsEntry(date: date, line: line, next: next,
                                  fontSize: np.carFontSize, showNext: np.carShowNext, isPlaying: np.isPlaying)
        }

        func index(at pos: Double) -> Int {
            np.lines.lastIndex(where: { $0.time <= pos }) ?? -1
        }

        // 暫停或沒有歌詞：只顯示一個畫面
        guard np.isPlaying, !np.lines.isEmpty else {
            return [make(now, index(at: np.pausedPosition + np.offset))]
        }

        let pos = now.timeIntervalSince(np.trackStart) + np.offset
        let current = index(at: pos)
        var result = [make(now, current)]
        var i = current + 1
        while i < np.lines.count, result.count < limit {
            let date = np.trackStart.addingTimeInterval(np.lines[i].time - np.offset)
            result.append(make(date, i))
            i += 1
        }
        return result
    }
}

struct CarLyricsView: View {
    let entry: CarLyricsEntry

    var body: some View {
        // 與即時動態相同的「不破圖」規則：放不下就縮小，不截斷
        VStack(alignment: .leading, spacing: 4) {
            Text(entry.line)
                .font(.system(size: entry.fontSize, weight: .heavy, design: .rounded))
                .lineLimit(4)
                .minimumScaleFactor(0.4)
                .allowsTightening(true)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                .layoutPriority(1)
            if entry.showNext && !entry.next.isEmpty {
                Text(entry.next)
                    .font(.system(size: max(11, entry.fontSize * 0.5), weight: .medium, design: .rounded))
                    .foregroundStyle(.white.opacity(0.55))
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
            }
        }
        .foregroundStyle(.white)
        .padding(10)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }
}
