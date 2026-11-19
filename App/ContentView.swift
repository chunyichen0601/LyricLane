import AppIntents
import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var auth: SpotifyAuth
    @EnvironmentObject private var engine: SyncEngine
    @ObservedObject private var settings = AppSettings.shared

    var body: some View {
        NavigationStack {
            Form {
                nowPlayingSection
                lyricsSection
                syncSection
                carPlaySection
                activitySection
                siriSection
                spotifySection
            }
            .navigationTitle("LyricLane")
        }
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

    private var nowPlayingSection: some View {
        Section("現正播放") {
            VStack(alignment: .leading, spacing: 4) {
                Text(engine.track?.title ?? "—").font(.headline)
                Text(engine.track?.artist ?? "").font(.subheadline).foregroundStyle(.secondary)
                Text(engine.status).font(.caption).foregroundStyle(.secondary)
            }
            LabeledContent("同步來源", value: engine.syncSource)
                .font(.footnote)
            if !engine.remoteDetail.isEmpty {
                Text(engine.remoteDetail).font(.caption).foregroundStyle(.orange)
            }
            if auth.isLoggedIn && !auth.hasRemoteScope {
                Button("重新登入 Spotify 以啟用即時直連") { auth.login() }
            }
            LabeledContent("上次對時誤差") {
                Text("\(engine.lastDriftMs) ms · 來回 \(engine.latencyMs) ms")
                    .font(.footnote.monospacedDigit())
            }
            .font(.footnote)
        }
    }

    private var lyricsSection: some View {
        Section("歌詞") {
            if engine.lines.isEmpty {
                Text(engine.lyricsStatus.isEmpty ? "—" : engine.lyricsStatus)
                    .foregroundStyle(.secondary)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 10) {
                            ForEach(Array(engine.lines.enumerated()), id: \.offset) { i, line in
                                Text(line.text.isEmpty ? "♪" : line.text)
                                    .font(i == engine.currentIndex ? .title3.bold() : .body)
                                    .foregroundStyle(i == engine.currentIndex ? Color.primary : Color.secondary)
                                    .id(i)
                            }
                        }
                        .padding(.vertical, 8)
                    }
                    .frame(height: 260)
                    .onChange(of: engine.currentIndex) { _, new in
                        withAnimation(.easeOut(duration: 0.25)) {
                            proxy.scrollTo(max(new, 0), anchor: .center)
                        }
                    }
                }
            }
        }
    }

    private var syncSection: some View {
        Section {
            VStack(alignment: .leading) {
                Text("歌詞提早：\(Int(settings.offsetMs)) ms")
                Slider(value: $settings.offsetMs, in: -1500...1500, step: 25)
            }
            Toggle("簡體轉繁體", isOn: $settings.toTraditional)
            Toggle("直連手機上的 Spotify（最準）", isOn: $settings.useAppRemote)
        } header: {
            Text("同步調整")
        } footer: {
            Text("歌詞比歌聲慢就往右調，比歌聲快就往左調。車機的藍牙或無線 CarPlay 音訊本身有延遲，通常要往左調一些。")
        }
    }

    private var carPlaySection: some View {
        Section {
            VStack(alignment: .leading) {
                Text("歌詞字級：\(Int(settings.carFontSize)) pt")
                Slider(value: $settings.carFontSize, in: 18...36, step: 1)
            }
            Toggle("顯示下一句", isOn: $settings.carShowNext)
            carPreview
        } header: {
            Text("CarPlay 顯示")
        } footer: {
            Text("字放不下時會自動縮小，不會被切掉。關閉「顯示下一句」可以讓目前這句更大。預覽框大小是近似值。")
        }
    }

    /// 與 CarPlay 上相同的排版規則，方便調整字級
    private var carPreview: some View {
        let line = engine.currentIndex >= 0 && engine.currentIndex < engine.lines.count
            ? engine.lines[engine.currentIndex].text : "這是一句比較長的歌詞範例，看看會不會破圖"
        let next = engine.currentIndex + 1 < engine.lines.count && engine.currentIndex + 1 >= 0
            ? engine.lines[engine.currentIndex + 1].text : "下一句歌詞"
        return VStack(alignment: .leading, spacing: 2) {
            Text(line.isEmpty ? "♪" : line)
                .font(.system(size: settings.carFontSize, weight: .heavy, design: .rounded))
                .lineLimit(3)
                .minimumScaleFactor(0.4)
                .allowsTightening(true)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                .layoutPriority(1)
            if settings.carShowNext {
                Text(next)
                    .font(.system(size: max(11, settings.carFontSize * 0.5), weight: .medium, design: .rounded))
                    .foregroundStyle(.white.opacity(0.55))
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
            }
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .frame(width: 280, height: 90)
        .background(Color.black, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .frame(maxWidth: .infinity)
    }

    private var siriSection: some View {
        Section {
            SiriTipView(intent: StartLyricsIntent())
            ShortcutsLink()
        } header: {
            Text("Siri 與捷徑")
        } footer: {
            Text("建議在「捷徑 > 自動化」設定「連接 CarPlay 時」執行「開始顯示歌詞」，上車就自動出現歌詞，不用先打開 App。")
        }
    }

    private var activitySection: some View {
        Section {
            if engine.activityRunning {
                Button("關閉即時動態", role: .destructive) { engine.endActivity() }
            } else {
                Button("啟動即時動態（CarPlay／動態島）") { engine.startActivity() }
            }
            Button(engine.isRunning ? "停止背景同步" : "開始背景同步") {
                engine.isRunning ? engine.stop() : engine.start()
            }
        } header: {
            Text("即時動態")
        } footer: {
            Text("iOS 只允許 App 在前景時啟動即時動態，每次最長約 8 小時。上車前打開本 App 一次即可，之後可以切到別的 App。")
        }
    }

    private var spotifySection: some View {
        Section {
            TextField("Spotify Client ID", text: $settings.clientID)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .font(.footnote.monospaced())
            LabeledContent("Redirect URI") {
                Text(SpotifyAuth.redirectURI).font(.footnote.monospaced()).textSelection(.enabled)
            }
            LabeledContent("Bundle ID") {
                Text(Bundle.main.bundleIdentifier ?? "—").font(.footnote.monospaced()).textSelection(.enabled)
            }
            LabeledContent("小工具共用空間") {
                Text(SharedStore.isAvailable ? "正常" : "無法使用").font(.footnote)
                    .foregroundStyle(SharedStore.isAvailable ? Color.green : Color.red)
            }
            if auth.isLoggedIn {
                Button("登出 Spotify", role: .destructive) { auth.logout() }
            } else {
                Button("登入 Spotify") { auth.login() }
            }
            if let err = auth.lastError {
                Text(err).font(.caption).foregroundStyle(.red)
            }
        } header: {
            Text("Spotify 帳號")
        }
    }
}
