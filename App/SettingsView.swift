import AppIntents
import SwiftUI

/// 設定頁：常用的放前面，技術細節收在「進階」裡
struct SettingsView: View {
    @EnvironmentObject private var auth: SpotifyAuth
    @EnvironmentObject private var engine: SyncEngine
    @ObservedObject private var settings = AppSettings.shared
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                timingSection
                carPlaySection
                siriSection
                accountSection
                Section {
                    NavigationLink("進階與診斷") { AdvancedView() }
                }
            }
            .navigationTitle("設定")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
        }
    }

    private var timingSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("歌詞時間")
                    Spacer()
                    Text(offsetLabel).foregroundStyle(.secondary).monospacedDigit()
                }
                Slider(value: $settings.offsetMs, in: -1500...1500, step: 25) {
                    Text("歌詞時間")
                } minimumValueLabel: {
                    Image(systemName: "tortoise.fill").foregroundStyle(.secondary)
                } maximumValueLabel: {
                    Image(systemName: "hare.fill").foregroundStyle(.secondary)
                }
            }
            Toggle("簡體轉繁體", isOn: $settings.toTraditional)
        } header: {
            Text("歌詞")
        } footer: {
            Text("歌詞比歌聲慢就往兔子調，比歌聲快就往烏龜調。無線 CarPlay 的聲音本身有延遲，通常要往烏龜調一點。")
        }
    }

    private var offsetLabel: String {
        let v = Int(settings.offsetMs)
        if v == 0 { return "準時" }
        return v > 0 ? "提早 \(v) ms" : "延後 \(-v) ms"
    }

    private var carPlaySection: some View {
        Section {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("字體大小")
                    Spacer()
                    Text("\(Int(settings.carFontSize)) pt").foregroundStyle(.secondary).monospacedDigit()
                }
                Slider(value: $settings.carFontSize, in: 18...36, step: 1) {
                    Text("字體大小")
                } minimumValueLabel: {
                    Image(systemName: "textformat.size.smaller")
                } maximumValueLabel: {
                    Image(systemName: "textformat.size.larger")
                }
            }
            Toggle("顯示下一句", isOn: $settings.carShowNext)
            Toggle(isOn: $settings.autoLiveActivity) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("自動開啟即時動態")
                    Text("會同時出現在動態島、鎖定畫面與 CarPlay")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            CarPreview()
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets())
        } header: {
            Text("CarPlay 顯示")
        } footer: {
            Text("只想在 CarPlay 看歌詞、不想佔用動態島：關閉「自動開啟即時動態」，改用 CarPlay 小工具（設定 › 一般 › CarPlay › 你的車 › 小工具）。字放不下時會自動縮小，不會被切掉。")
        }
    }

    private var siriSection: some View {
        Section {
            SiriTipView(intent: StartLyricsIntent())
            ShortcutsLink()
        } header: {
            Text("Siri 與捷徑")
        } footer: {
            Text("建議在「捷徑 › 自動化 › CarPlay › 連線時」執行「開始顯示歌詞」，上車就會自動出現歌詞。")
        }
    }

    private var accountSection: some View {
        Section {
            HStack {
                Label("Spotify", systemImage: "person.crop.circle.fill")
                Spacer()
                Text("已登入").foregroundStyle(.secondary)
            }
            Toggle("直連手機上的 Spotify（零延遲）", isOn: $settings.useAppRemote)
            if !auth.hasRemoteScope {
                Button("重新登入以啟用直連") { auth.login() }
            }
            Button("登出", role: .destructive) { auth.logout() }
        } header: {
            Text("帳號")
        }
    }
}

/// 與 CarPlay 上相同的排版規則
struct CarPreview: View {
    @EnvironmentObject private var engine: SyncEngine
    @ObservedObject private var settings = AppSettings.shared

    var body: some View {
        let i = engine.currentIndex
        let lines = engine.lines
        let line = (i >= 0 && i < lines.count) ? lines[i].text : "這是一句比較長的歌詞範例，看看會不會破圖"
        let next = (i + 1 >= 0 && i + 1 < lines.count) ? lines[i + 1].text : "下一句歌詞"

        VStack(alignment: .leading, spacing: 2) {
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
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .frame(width: 280, height: 90)
        .background(Color.black, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(.white.opacity(0.15)))
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
    }
}

/// 技術細節：給除錯或第一次設定用
struct AdvancedView: View {
    @EnvironmentObject private var auth: SpotifyAuth
    @EnvironmentObject private var engine: SyncEngine
    @ObservedObject private var settings = AppSettings.shared

    var body: some View {
        Form {
            Section("同步狀態") {
                LabeledContent("來源", value: engine.syncSource)
                if !engine.remoteDetail.isEmpty {
                    Text(engine.remoteDetail).font(.footnote).foregroundStyle(.orange)
                }
                LabeledContent("上次對時誤差", value: "\(engine.lastDriftMs) ms")
                LabeledContent("來回時間", value: "\(engine.latencyMs) ms")
                LabeledContent("狀態", value: engine.status)
                Button(engine.isRunning ? "停止背景同步" : "開始背景同步") {
                    engine.isRunning ? engine.stop() : engine.start()
                }
            }

            Section("CarPlay 小工具") {
                LabeledContent("共用空間") {
                    Text(SharedStore.isAvailable ? "正常" : "無法使用")
                        .foregroundStyle(SharedStore.isAvailable ? Theme.accent : .red)
                }
            }

            Section {
                TextField("Client ID", text: $settings.clientID)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .font(.footnote.monospaced())
                copyRow("Redirect URI", SpotifyAuth.redirectURI)
                copyRow("Bundle ID", Bundle.main.bundleIdentifier ?? "—")
                if let err = auth.lastError {
                    Text(err).font(.footnote).foregroundStyle(.red)
                }
            } header: {
                Text("Spotify 開發者設定")
            } footer: {
                Text("如果直連失敗，到 Spotify 開發者後台勾選 iOS，並把上面的 Bundle ID 加進去。")
            }
        }
        .navigationTitle("進階與診斷")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func copyRow(_ title: String, _ value: String) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.caption).foregroundStyle(.secondary)
                Text(value).font(.footnote.monospaced()).textSelection(.enabled)
            }
            Spacer()
            Button { UIPasteboard.general.string = value } label: {
                Image(systemName: "doc.on.doc")
            }
            .buttonStyle(.borderless)
        }
    }
}
