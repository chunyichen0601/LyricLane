import ActivityKit
import SwiftUI
import WidgetKit

@main
struct DynLyricsWidgetBundle: WidgetBundle {
    var body: some Widget {
        LyricsLiveActivity()
        CarLyricsWidget()
        CarLyricsInfoWidget()
        CarLyricsAdjustWidget()
    }
}

struct LyricsLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: LyricsActivityAttributes.self) { context in
            // 鎖定畫面、通知中心、CarPlay（.small）、Apple Watch 都走這裡
            LyricsActivityView(state: context.state, isStale: context.isStale)
                .activityBackgroundTint(Color.black.opacity(0.85))
                .activitySystemActionForegroundColor(.white)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Image(systemName: context.state.isPlaying ? "music.note" : "pause.fill")
                        .foregroundStyle(.green)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Text(context.state.artist).font(.caption2).lineLimit(1)
                        .foregroundStyle(.white.opacity(0.7))
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(context.state.line).font(.headline).lineLimit(2)
                        if !context.state.nextLine.isEmpty {
                            Text(context.state.nextLine).font(.caption)
                                .foregroundStyle(.white.opacity(0.6)).lineLimit(1)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            } compactLeading: {
                Image(systemName: context.state.isPlaying ? "music.note" : "pause.fill")
                    .foregroundStyle(.green)
            } compactTrailing: {
                Text(context.isStale ? "已停止" : context.state.line)
                    .font(.caption2).lineLimit(1).frame(maxWidth: 110)
            } minimal: {
                Image(systemName: "music.note").foregroundStyle(.green)
            }
        }
        // .small = CarPlay（iOS 26）與 Apple Watch 智慧型堆疊
        .supplementalActivityFamilies([.small, .medium])
    }
}

struct LyricsActivityView: View {
    @Environment(\.activityFamily) private var family
    let state: LyricsActivityAttributes.ContentState
    var isStale = false

    var body: some View {
        if isStale {
            // App 已經沒在更新（被系統關閉等），不要顯示過期的歌詞
            Label("LyricLane 已停止", systemImage: "pause.circle")
                .font(.headline)
                .foregroundStyle(.white.opacity(0.7))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(8)
        } else if family == .small {
            smallView
        } else {
            mediumView
        }
    }

    /// CarPlay 版：字盡量大，但「不破圖」優先——
    /// 放不下時整句自動等比縮小（最小到 40%），絕不截斷或超出框外。
    private var smallView: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(state.line)
                .font(.system(size: state.carFontSize, weight: .heavy, design: .rounded))
                .lineLimit(3)
                .minimumScaleFactor(0.4)
                .allowsTightening(true)
                .multilineTextAlignment(.leading)
                .contentTransition(.opacity)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                .layoutPriority(1) // 空間優先給目前這句

            if state.carShowNext && !state.nextLine.isEmpty {
                Text(state.nextLine)
                    .font(.system(size: max(12, state.carFontSize * 0.6), weight: .semibold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.75))
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                    .truncationMode(.tail)
            }
        }
        .foregroundStyle(.white)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
    }

    private var mediumView: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: state.isPlaying ? "music.note" : "pause.fill").foregroundStyle(.green)
                Text(state.artist.isEmpty ? state.title : "\(state.title) · \(state.artist)").lineLimit(1)
            }
            .font(.caption)
            .foregroundStyle(.white.opacity(0.7))

            Text(state.line)
                .font(.title3.bold())
                .lineLimit(2)
                .minimumScaleFactor(0.7)

            if !state.nextLine.isEmpty {
                Text(state.nextLine)
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.6))
                    .lineLimit(1)
            }
            progress
        }
        .foregroundStyle(.white)
        .padding()
    }

    @ViewBuilder
    private var progress: some View {
        if state.isPlaying && state.trackStart < state.trackEnd {
            // 系統自己會讓進度條前進，不需要 App 每秒更新
            ProgressView(timerInterval: state.trackStart...state.trackEnd, countsDown: false) {
                EmptyView()
            } currentValueLabel: {
                EmptyView()
            }
            .tint(.green)
        } else {
            ProgressView(value: state.pausedProgress).tint(.green)
        }
    }
}
