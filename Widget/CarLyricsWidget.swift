import SwiftUI
import WidgetKit

// CarPlay 小工具頁（iOS 26）與 iPhone 主畫面的小工具。
// iOS 的 CarPlay 只支援 systemSmall 尺寸，所以這裡把一格空間盡量給歌詞用。
//
// App 每首歌只交一次「整首歌時間表」，這裡把每一句排成一個 timeline entry，
// 由系統在每句的時間點自動切換，不需要 App 一直更新。
//
// 三種樣式各是一個獨立的小工具，在「設定 › CarPlay › 小工具」裡挑：
//   LyricLane 歌詞        純歌詞（上一句／本句／下一句）
//   LyricLane 歌詞＋歌曲  底部顯示歌名與歌手
//   LyricLane 歌詞＋快慢  底部有 🐢／🐇 微調按鈕

enum CarLyricsStyle {
    case pure, info, adjust
}

private func makeConfiguration(kind: String, style: CarLyricsStyle,
                               name: LocalizedStringKey, description: LocalizedStringKey) -> some WidgetConfiguration {
    StaticConfiguration(kind: kind, provider: CarLyricsProvider()) { entry in
        CarLyricsView(entry: entry, style: style)
            .containerBackground(for: .widget) { Color.black }
    }
    .configurationDisplayName(name)
    .description(description)
    .supportedFamilies([.systemSmall])
    .contentMarginsDisabled()
}

struct CarLyricsWidget: Widget {
    var body: some WidgetConfiguration {
        makeConfiguration(kind: SharedStore.widgetKind, style: .pure,
                          name: "LyricLane 歌詞",
                          description: "純歌詞：上一句、本句、下一句。")
    }
}

struct CarLyricsInfoWidget: Widget {
    var body: some WidgetConfiguration {
        makeConfiguration(kind: SharedStore.widgetKindInfo, style: .info,
                          name: "LyricLane 歌詞＋歌曲",
                          description: "歌詞，底部顯示歌名、歌手和 ↻ 重新同步按鈕。")
    }
}

struct CarLyricsAdjustWidget: Widget {
    var body: some WidgetConfiguration {
        makeConfiguration(kind: SharedStore.widgetKindAdjust, style: .adjust,
                          name: "LyricLane 歌詞＋快慢",
                          description: "歌詞，底部有 🐢／🐇 按鈕可以微調歌詞快慢。")
    }
}

// MARK: - Timeline

struct CarLyricsEntry: TimelineEntry {
    let date: Date
    var previous = ""
    let line: String
    let next: String
    var title = ""
    var artist = ""
    let fontSize: Double
    var offsetMs = 0
}

struct CarLyricsProvider: TimelineProvider {
    func placeholder(in context: Context) -> CarLyricsEntry {
        CarLyricsEntry(date: Date(), previous: "上一句歌詞", line: "♪ LyricLane", next: "下一句歌詞",
                       title: "歌名", artist: "歌手", fontSize: 26)
    }

    func getSnapshot(in context: Context, completion: @escaping (CarLyricsEntry) -> Void) {
        if context.isPreview, SharedStore.load() == nil {
            completion(placeholder(in: context))
            return
        }
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
        // 診斷：記下系統真的叫小工具重算的時間，App 的「進階與診斷」看得到
        SharedStore.saveWidgetStatus(.init(lastTimelineAt: now, title: np?.title ?? "", entries: entries.count))
        completion(Timeline(entries: entries, policy: policy))
    }

    static func entries(from np: SharedStore.NowPlaying?, now: Date, limit: Int) -> [CarLyricsEntry] {
        guard let np else {
            let msg = SharedStore.isAvailable ? "打開 LyricLane" : "請用 SideStore 重新安裝 LyricLane"
            return [CarLyricsEntry(date: now, line: msg, next: "", fontSize: 22)]
        }

        func text(_ i: Int) -> String {
            guard i >= 0, i < np.lines.count else { return "" }
            let t = np.lines[i].text
            return t.isEmpty ? "♪" : t
        }

        func make(_ date: Date, _ idx: Int) -> CarLyricsEntry {
            var line: String
            var prev = ""
            var next = ""
            if np.lines.isEmpty {
                line = np.message.isEmpty ? np.title : np.message
            } else if idx < 0 {
                line = "♪"
                next = text(0)
            } else {
                prev = text(idx - 1)
                line = text(idx)
                next = text(idx + 1)
            }
            return CarLyricsEntry(date: date, previous: prev, line: line, next: next,
                                  title: np.title, artist: np.artist,
                                  fontSize: np.carFontSize,
                                  offsetMs: Int((np.offset * 1000).rounded()))
        }

        func index(at pos: Double) -> Int {
            np.lines.lastIndex(where: { $0.time <= pos }) ?? -1
        }

        // 暫停或沒有歌詞：只顯示一個畫面
        guard np.isPlaying, !np.lines.isEmpty else {
            return [make(now, index(at: np.pausedPosition + np.offset))]
        }

        // 歌曲結束之後：不要一直停在最後一句，改顯示「等待下一首」
        let songEnd = np.trackStart.addingTimeInterval(np.duration + 1)
        let waiting = CarLyricsEntry(date: songEnd, previous: "", line: "♪ 等待下一首", next: "",
                                     title: np.title, artist: np.artist, fontSize: np.carFontSize * 0.8,
                                     offsetMs: Int((np.offset * 1000).rounded()))
        if np.duration > 0, now >= songEnd {
            return [CarLyricsEntry(date: now, previous: waiting.previous, line: waiting.line, next: "",
                                   title: waiting.title, artist: waiting.artist,
                                   fontSize: waiting.fontSize, offsetMs: waiting.offsetMs)]
        }

        let pos = now.timeIntervalSince(np.trackStart) + np.offset
        let current = index(at: pos)
        var result = [make(now, current)]
        var i = current + 1
        while i < np.lines.count, result.count < limit {
            let date = np.trackStart.addingTimeInterval(np.lines[i].time - np.offset)
            if np.duration > 0, date >= songEnd { break }
            result.append(make(date, i))
            i += 1
        }
        if np.duration > 0 { result.append(waiting) }
        return result
    }
}

// MARK: - 畫面

struct CarLyricsView: View {
    let entry: CarLyricsEntry
    let style: CarLyricsStyle

    /// 上下兩句：比本句小、半透明、霧化
    private var sideSize: Double { max(11, entry.fontSize * 0.5) }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            side(entry.previous)

            // 本句：清晰、最大；放不下就自動縮小，不截斷
            Text(entry.line)
                .font(.system(size: entry.fontSize, weight: .heavy, design: .rounded))
                .foregroundStyle(.white)
                .lineLimit(3)
                .minimumScaleFactor(0.4)
                .allowsTightening(true)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                .layoutPriority(1)

            side(entry.next)

            switch style {
            case .pure:
                EmptyView()
            case .info:
                infoBar
            case .adjust:
                adjustBar
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func side(_ text: String) -> some View {
        // 沒有上一句／下一句時也保留位置，本句才不會上下跳動
        Text(text.isEmpty ? " " : text)
            .font(.system(size: sideSize, weight: .semibold, design: .rounded))
            .foregroundStyle(.white.opacity(0.4))
            .blur(radius: 1.2)
            .lineLimit(1)
            .minimumScaleFactor(0.7)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var infoBar: some View {
        HStack(spacing: 4) {
            Image(systemName: "music.note")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(Color(red: 0.12, green: 0.84, blue: 0.38))
            Text(entry.artist.isEmpty ? entry.title : "\(entry.title) · \(entry.artist)")
                .font(.system(size: 11, weight: .medium, design: .rounded))
                .foregroundStyle(.white.opacity(0.65))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .frame(maxWidth: .infinity, alignment: .leading)
            // ↻ 重新同步（交給主 App 執行）
            Button(intent: ResyncIntent()) {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 28, height: 24)
                    .background(.white.opacity(0.15), in: Capsule())
            }
            .buttonStyle(.plain)
        }
        .padding(.top, 2)
    }

    /// 🐢 延後 / 目前值 / 🐇 提早（按鈕交給主 App 執行，立刻生效）
    private var adjustBar: some View {
        HStack(spacing: 6) {
            Button(intent: AdjustOffsetIntent(delta: -100)) {
                Image(systemName: "tortoise.fill")
                    .frame(maxWidth: .infinity, minHeight: 26)
            }
            Text(entry.offsetMs == 0 ? "0" : String(format: "%+d", entry.offsetMs))
                .font(.system(size: 11, weight: .semibold, design: .rounded).monospacedDigit())
                .foregroundStyle(.white.opacity(0.7))
                .lineLimit(1)
                .fixedSize()
            Button(intent: AdjustOffsetIntent(delta: 100)) {
                Image(systemName: "hare.fill")
                    .frame(maxWidth: .infinity, minHeight: 26)
            }
            Button(intent: ResyncIntent()) {
                Image(systemName: "arrow.clockwise")
                    .frame(maxWidth: .infinity, minHeight: 26)
            }
        }
        .buttonStyle(.plain)
        .font(.system(size: 13))
        .foregroundStyle(.white)
        .padding(.vertical, 2)
        .background(.white.opacity(0.12), in: Capsule())
    }
}
