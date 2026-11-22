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

    @ViewBuilder
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
            CarPreview()
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets())
        } header: {
            Text("CarPlay 小工具")
        } footer: {
            Text("""
            有三種樣式可以挑：「歌詞」「歌詞＋歌曲」「歌詞＋快慢」。\
            到 iPhone 設定 › 一般 › CarPlay › 你的車 › 小工具 加入你要的那一個。\
            字放不下時會自動縮小，不會被切掉。預覽是近似大小，以實際車機為準。
            """)
        }

        Section {
            Toggle(isOn: $settings.autoLiveActivity) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("自動開啟即時動態")
                    Text("會同時出現在動態島、鎖定畫面與 CarPlay")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Toggle("即時動態顯示下一句", isOn: $settings.carShowNext)
            Toggle(isOn: $settings.useLocationKeepAlive) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("用定位保持背景執行")
                    Text("定位權限：\(LocationKeepAlive.describe(LocationKeepAlive.shared.authorization))")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .onChange(of: settings.useLocationKeepAlive) { _, on in
                on ? LocationKeepAlive.shared.start() : LocationKeepAlive.shared.stop()
            }
        } header: {
            Text("即時動態")
        } footer: {
            Text("""
            不想佔用動態島就關閉「自動開啟」，只用 CarPlay 小工具即可。
            「用定位保持背景執行」請保持開啟：iOS 不讓只在背景播音訊的 App 更新即時動態，\
            有定位才行（跟導航 App 一樣）。只用低精度定位、不開 GPS，位置不會儲存或上傳。\
            定位權限建議選「永遠」，CarPlay 自動化才能在背景啟動。
            """)
        }
    }

    private var siriSection: some View {
        Section {
            NavigationLink {
                CarPlayAutomationGuide()
            } label: {
                Label("CarPlay 自動開關", systemImage: "car.fill")
            }
            SiriTipView(intent: CarPlayArriveIntent())
            ShortcutsLink()
        } header: {
            Text("Siri 與捷徑")
        } footer: {
            Text("設定一次，上車自動開歌詞與 Spotify，下車自動關閉 LyricLane。")
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

/// 帶使用者建立兩個 CarPlay 自動化（iOS 不允許 App 自己建立自動化，只能引導）
struct CarPlayAutomationGuide: View {
    var body: some View {
        List {
            Section {
                Text("LyricLane 已經把「上車」和「下車」兩個動作放進捷徑 App 了。你只要建立兩個自動化，大約 1 分鐘。")
                    .font(.subheadline)
            }

            Section {
                step(1, "打開「捷徑」App，點下方「自動化」")
                step(2, "點右上角 ＋，選「CarPlay」")
                step(3, "勾「連線時」，選「立即執行」，點「下一步」")
                step(4, "搜尋 LyricLane，選「上車：開始歌詞＋打開 Spotify」")
            } header: {
                Label("上車：自動開歌詞＋Spotify", systemImage: "car.fill")
            }

            Section {
                step(1, "再點一次 ＋，選「CarPlay」")
                step(2, "這次勾「中斷連線時」，選「立即執行」")
                step(3, "搜尋 LyricLane，選「下車：關閉 LyricLane」")
            } header: {
                Label("下車：自動關閉 LyricLane", systemImage: "parkingsign.circle.fill")
            } footer: {
                Text("下車只會關閉 LyricLane 的歌詞、即時動態和背景同步，Spotify 不會被關掉。")
            }

            Section {
                Button {
                    if let url = URL(string: "shortcuts://") { UIApplication.shared.open(url) }
                } label: {
                    Label("打開捷徑 App", systemImage: "arrow.up.forward.app")
                }
            }
        }
        .navigationTitle("CarPlay 自動開關")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func step(_ n: Int, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text("\(n)")
                .font(.caption.bold())
                .frame(width: 22, height: 22)
                .background(Theme.accent, in: Circle())
                .foregroundStyle(.black)
            Text(text)
        }
    }
}

/// 與 CarPlay 上相同的排版規則
struct CarPreview: View {
    @EnvironmentObject private var engine: SyncEngine
    @ObservedObject private var settings = AppSettings.shared

    var body: some View {
        let i = engine.currentIndex
        let prev = text(i - 1, "上一句歌詞")
        let line = text(i, "這是一句比較長的歌詞範例，看看會不會破圖")
        let next = text(i + 1, "下一句歌詞")
        let prevSize = max(11, settings.carFontSize * 0.5)
        let nextSize = max(12, settings.carFontSize * 0.6)

        // 與 CarPlay 小工具相同的排版：上一句最小最淡、本句大字、下一句小字但清晰
        VStack(alignment: .leading, spacing: 3) {
            Text(prev)
                .font(.system(size: prevSize, weight: .semibold, design: .rounded))
                .foregroundStyle(.white.opacity(0.3))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text(line)
                .font(.system(size: settings.carFontSize, weight: .heavy, design: .rounded))
                .lineLimit(3)
                .minimumScaleFactor(0.4)
                .allowsTightening(true)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                .layoutPriority(1)
            Text(next)
                .font(.system(size: nextSize, weight: .semibold, design: .rounded))
                .foregroundStyle(.white.opacity(0.75))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .foregroundStyle(.white)
        .padding(10)
        .frame(width: 170, height: 170) // CarPlay 小工具是正方形
        .background(Color.black, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).stroke(.white.opacity(0.15)))
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
    }

    private func text(_ k: Int, _ fallback: String) -> String {
        let lines = engine.lines
        guard k >= 0, k < lines.count else { return fallback }
        return lines[k].text.isEmpty ? "♪" : lines[k].text
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

            Section {
                LabeledContent("共用空間") {
                    Text(SharedStore.isAvailable ? "正常" : "無法使用")
                        .foregroundStyle(SharedStore.isAvailable ? Theme.accent : .red)
                }
                LabeledContent("App 要求刷新", value: "\(engine.widgetReloads) 次")
                TimelineView(.periodic(from: .now, by: 1)) { _ in
                    widgetStatusRows
                }
            } header: {
                Text("CarPlay 小工具")
            } footer: {
                Text("如果「小工具上的歌」跟現在播的不一樣、而且「最後重算」停在很久以前，代表 iOS 暫時不讓小工具刷新（刷新次數被系統限制）。這時改用即時動態最穩定。")
            }

            Section {
                if let url = DiagLog.fileURL {
                    ShareLink(item: url) {
                        Label("匯出診斷紀錄", systemImage: "square.and.arrow.up")
                    }
                }
                NavigationLink("查看最近紀錄") { DiagLogView() }
                Button("清除紀錄", role: .destructive) { DiagLog.clear() }
            } header: {
                Text("診斷紀錄")
            } footer: {
                Text("歌詞卡住時，記下大概的時間（或按一下 ↻ 重新同步，紀錄裡會留一筆當記號）。回家後按「匯出診斷紀錄」把檔案傳給 Claude。紀錄只存在手機裡，不含帳號資料。")
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

    /// 小工具自己記錄的「上次被系統叫起來重算」的時間與歌名
    @ViewBuilder
    private var widgetStatusRows: some View {
        if let s = SharedStore.loadWidgetStatus() {
            let ago = Int(Date().timeIntervalSince(s.lastTimelineAt))
            LabeledContent("最後重算", value: ago < 60 ? "\(ago) 秒前" : "\(ago / 60) 分鐘前")
            LabeledContent("小工具上的歌") {
                let matches = s.title == (engine.track?.title ?? "")
                Text(s.title.isEmpty ? "—" : s.title)
                    .foregroundStyle(matches ? Theme.accent : .orange)
                    .lineLimit(1)
            }
        } else {
            LabeledContent("最後重算", value: "還沒有紀錄（小工具尚未加入或尚未顯示過）")
        }
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

/// 在手機上直接看最近的診斷紀錄（最新的在最下面）
struct DiagLogView: View {
    @State private var text = ""

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                Text(text.isEmpty ? "還沒有紀錄" : text)
                    .font(.caption2.monospaced())
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
                Color.clear.frame(height: 1).id("bottom")
            }
            .onAppear {
                text = DiagLog.tail(400)
                DispatchQueue.main.async { proxy.scrollTo("bottom") }
            }
            .refreshable { text = DiagLog.tail(400) }
        }
        .navigationTitle("最近紀錄")
        .navigationBarTitleDisplayMode(.inline)
    }
}
