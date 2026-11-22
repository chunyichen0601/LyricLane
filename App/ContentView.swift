import ActivityKit
import SwiftUI

/// 根畫面：沒登入 → 引導畫面；登入後 → 歌詞主畫面
struct ContentView: View {
    @EnvironmentObject private var auth: SpotifyAuth
    @EnvironmentObject private var engine: SyncEngine
    @ObservedObject private var settings = AppSettings.shared

    var body: some View {
        Group {
            if auth.isLoggedIn {
                NowPlayingView()
            } else {
                OnboardingView()
            }
        }
        .preferredColorScheme(.dark)
        .tint(Theme.accent)
        .onChange(of: settings.offsetMs) { engine.settingsChanged() }
        .onChange(of: settings.toTraditional) { engine.settingsChanged() }
        .onChange(of: settings.carFontSize) { engine.settingsChanged() }
        .onChange(of: settings.carShowNext) { engine.settingsChanged() }
        .onChange(of: settings.useAppRemote) {
            engine.stop()
            engine.start()
        }
        .onChange(of: auth.isLoggedIn) { _, loggedIn in
            if loggedIn { engine.appBecameActive() } else { engine.stop() }
        }
    }
}

enum Theme {
    static let accent = Color(red: 0.12, green: 0.84, blue: 0.38)
    static let background = LinearGradient(
        colors: [Color(red: 0.05, green: 0.06, blue: 0.08), Color(red: 0.02, green: 0.16, blue: 0.10)],
        startPoint: .top, endPoint: .bottom
    )
}

// MARK: - 主畫面

/// 「更頻繁更新」沒開時的提醒：沒開的話 App 在背景約 30 秒後即時動態就不再更新
struct FrequentUpdatesBanner: View {
    @Environment(\.scenePhase) private var scenePhase
    @State private var enabled = ActivityAuthorizationInfo().frequentPushesEnabled

    var body: some View {
        Group {
            if !enabled {
                Button {
                    if let url = URL(string: UIApplication.openSettingsURLString) {
                        UIApplication.shared.open(url)
                    }
                } label: {
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("請開啟「更頻繁更新」").font(.subheadline.bold())
                            Text("沒開的話，動態島和 CarPlay 歌詞會在背景約 30 秒後停住。點這裡 → 即時動態 → 更頻繁更新")
                                .font(.caption).foregroundStyle(.secondary)
                                .multilineTextAlignment(.leading)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(10)
                    .background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 16)
                .padding(.bottom, 6)
            }
        }
        // 從設定頁回來時重新檢查
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { enabled = ActivityAuthorizationInfo().frequentPushesEnabled }
        }
    }
}

struct NowPlayingView: View {
    @EnvironmentObject private var auth: SpotifyAuth
    @EnvironmentObject private var engine: SyncEngine
    @State private var showSettings = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                header
                FrequentUpdatesBanner()
                LyricsScroller()
                bottomBar
            }
            .background(Theme.background.ignoresSafeArea())
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showSettings = true } label: {
                        Image(systemName: "gearshape.fill")
                    }
                    .accessibilityLabel("設定")
                }
            }
            .sheet(isPresented: $showSettings) {
                SettingsView()
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(engine.track?.title ?? "LyricLane")
                .font(.title2.bold())
                .lineLimit(1)
            if let artist = engine.track?.artist, !artist.isEmpty {
                Text(artist)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            HStack {
                StatusPill()
                Spacer()
                ResyncButton()
            }
            .padding(.top, 4)
            ResyncBanner()
                .animation(.spring(duration: 0.35), value: engine.resyncPhase)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 24)
        .padding(.bottom, 8)
    }

    private var bottomBar: some View {
        VStack(spacing: 10) {
            if !auth.hasRemoteScope {
                Button { auth.login() } label: {
                    Label("重新登入 Spotify，啟用零延遲直連", systemImage: "bolt.fill")
                        .font(.footnote.weight(.semibold))
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .tint(.orange)
            }

            Button {
                engine.activityRunning ? engine.endActivity() : engine.startActivity()
            } label: {
                Label(engine.activityRunning ? "即時動態顯示中（點一下關閉）" : "開啟即時動態（動態島＋CarPlay）",
                      systemImage: engine.activityRunning ? "checkmark.circle.fill" : "dot.radiowaves.left.and.right")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
            }
            .buttonStyle(.borderedProminent)
            .tint(engine.activityRunning ? Theme.accent.opacity(0.35) : Theme.accent)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(.ultraThinMaterial)
    }
}

/// 一眼看懂現在的同步狀態
struct StatusPill: View {
    @EnvironmentObject private var engine: SyncEngine

    private var info: (String, Color) {
        if engine.isResyncing { return ("重新同步中…", .blue) }
        if !engine.isRunning { return ("已停止", .gray) }
        guard let track = engine.track else { return ("等待 Spotify 播放", .gray) }
        if !track.isPlaying { return ("已暫停", .gray) }
        return engine.isDirect ? ("同步中 · 直連", Theme.accent) : ("同步中 · 網路", .orange)
    }

    var body: some View {
        let (text, color) = info
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(text).font(.caption.weight(.medium))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(color.opacity(0.15), in: Capsule())
        .foregroundStyle(color == .gray ? Color.secondary : color)
    }
}

/// 歌詞卡住、不同步、抓錯歌詞時按：整套同步流程重來
/// 三段式回饋：同步中（轉圈）→ 完成 ✓（綠）／失敗 ⚠︎（橘），震動也不同
struct ResyncButton: View {
    @EnvironmentObject private var engine: SyncEngine
    @State private var taps = 0

    private var look: (icon: String, text: String, color: Color) {
        switch engine.resyncPhase {
        case .idle: return ("arrow.clockwise", "重新同步", .white)
        case .working: return ("arrow.clockwise", "同步中…", .blue)
        case .done: return ("checkmark.circle.fill", "完成", Theme.accent)
        case .failed: return ("exclamationmark.triangle.fill", "再試一次", .orange)
        }
    }

    var body: some View {
        let l = look
        Button {
            taps += 1
            engine.resync()
        } label: {
            HStack(spacing: 6) {
                Image(systemName: l.icon)
                    .symbolEffect(.rotate, options: .repeating, isActive: engine.isResyncing)
                    .contentTransition(.symbolEffect(.replace))
                Text(l.text)
                    .contentTransition(.opacity)
            }
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(l.color)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(l.color.opacity(0.15), in: Capsule())
            .overlay(Capsule().stroke(l.color.opacity(0.3)))
            .animation(.spring(duration: 0.35), value: engine.resyncPhase)
        }
        .buttonStyle(.plain)
        .disabled(engine.isResyncing)
        .sensoryFeedback(.impact, trigger: taps)
        .sensoryFeedback(trigger: engine.resyncPhase) { _, new in
            switch new {
            case .done: return .success
            case .failed: return .warning
            default: return nil
            }
        }
        .accessibilityLabel("重新同步")
        .accessibilityHint("重新連線 Spotify、重新抓歌詞")
    }
}

/// 重新同步的結果說明（完成／失敗時在標題下方出現 3 秒）
struct ResyncBanner: View {
    @EnvironmentObject private var engine: SyncEngine

    var body: some View {
        switch engine.resyncPhase {
        case let .done(message):
            banner(message, icon: "checkmark.circle.fill", color: Theme.accent)
        case let .failed(message):
            banner(message + "，可以再按一次", icon: "exclamationmark.triangle.fill", color: .orange)
        case .idle, .working:
            EmptyView()
        }
    }

    private func banner(_ text: String, icon: String, color: Color) -> some View {
        Label(text, systemImage: icon)
            .font(.footnote.weight(.medium))
            .foregroundStyle(color)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(color.opacity(0.12), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .transition(.move(edge: .top).combined(with: .opacity))
    }
}

/// Apple Music 風格的大字歌詞
struct LyricsScroller: View {
    @EnvironmentObject private var engine: SyncEngine

    var body: some View {
        if engine.lines.isEmpty {
            VStack(spacing: 12) {
                Image(systemName: engine.track == nil ? "music.note" : "text.quote")
                    .font(.system(size: 40))
                    .foregroundStyle(.tertiary)
                Text(emptyMessage)
                    .font(.headline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding()
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 22) {
                        ForEach(Array(engine.lines.enumerated()), id: \.offset) { i, line in
                            Text(line.text.isEmpty ? "♪" : line.text)
                                .font(.system(size: 28, weight: .bold, design: .rounded))
                                .foregroundStyle(.white.opacity(opacity(for: i)))
                                .blur(radius: i == engine.currentIndex ? 0 : 0.6)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .id(i)
                        }
                    }
                    .padding(.horizontal, 24)
                    .padding(.vertical, 160)
                }
                .scrollIndicators(.hidden)
                .mask(LinearGradient(colors: [.clear, .black, .black, .clear],
                                     startPoint: .top, endPoint: .bottom))
                .onAppear { proxy.scrollTo(max(engine.currentIndex, 0), anchor: .center) }
                .onChange(of: engine.currentIndex) { _, new in
                    withAnimation(.spring(duration: 0.45)) {
                        proxy.scrollTo(max(new, 0), anchor: .center)
                    }
                }
            }
        }
    }

    private func opacity(for i: Int) -> Double {
        if i == engine.currentIndex { return 1 }
        return abs(i - engine.currentIndex) == 1 ? 0.45 : 0.25
    }

    private var emptyMessage: String {
        if engine.track == nil { return "在 Spotify 播放音樂\n歌詞就會出現在這裡" }
        return engine.lyricsStatus.isEmpty ? "♪" : engine.lyricsStatus
    }
}

// MARK: - 登入引導

struct OnboardingView: View {
    @EnvironmentObject private var auth: SpotifyAuth
    @ObservedObject private var settings = AppSettings.shared

    var body: some View {
        ScrollView {
            VStack(spacing: 28) {
                VStack(spacing: 12) {
                    Image(systemName: "music.note.list")
                        .font(.system(size: 44, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 88, height: 88)
                        .background(Theme.accent.gradient, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
                    Text("LyricLane").font(.largeTitle.bold())
                    Text("Spotify 的歌詞，即時顯示在 CarPlay")
                        .foregroundStyle(.secondary)
                }
                .padding(.top, 40)

                VStack(alignment: .leading, spacing: 16) {
                    step(1, "到 Spotify 開發者後台建立 App，複製 Client ID")
                    TextField("貼上 Client ID", text: $settings.clientID)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .font(.body.monospaced())
                        .padding(12)
                        .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))

                    step(2, "Redirect URI 要填這個")
                    HStack {
                        Text(SpotifyAuth.redirectURI).font(.body.monospaced())
                        Spacer()
                        Button("複製") { UIPasteboard.general.string = SpotifyAuth.redirectURI }
                            .font(.footnote.weight(.semibold))
                    }
                    .padding(12)
                    .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
                }
                .padding(20)
                .background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 20))

                Button { auth.login() } label: {
                    Text("登入 Spotify").font(.headline).frame(maxWidth: .infinity).padding(.vertical, 6)
                }
                .buttonStyle(.borderedProminent)
                .disabled(settings.clientID.trimmingCharacters(in: .whitespaces).isEmpty)

                if let err = auth.lastError {
                    Text(err).font(.footnote).foregroundStyle(.red).multilineTextAlignment(.center)
                }

                Link("開啟 Spotify 開發者後台", destination: URL(string: "https://developer.spotify.com/dashboard")!)
                    .font(.footnote)
            }
            .padding(24)
        }
        .background(Theme.background.ignoresSafeArea())
    }

    private func step(_ n: Int, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text("\(n)")
                .font(.caption.bold())
                .frame(width: 22, height: 22)
                .background(Theme.accent, in: Circle())
                .foregroundStyle(.black)
            Text(text).font(.subheadline)
        }
    }
}
