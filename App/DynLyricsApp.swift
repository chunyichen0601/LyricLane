import SwiftUI
import UIKit
import WidgetKit

/// 從多工畫面把 App 滑掉時，iOS 會呼叫 applicationWillTerminate：
/// 在這裡關掉即時動態（動態島、鎖定畫面、CarPlay），並把小工具改成「已關閉」。
final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        // 開車途中出現這行 = App 之前被系統結束，又被叫起來
        SharedStore.resetDrawProbe() // 序號每次啟動從 1 開始，舊紀錄清掉才比得準
        DiagLog.log("===== App 啟動（版本 \(Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?")）=====")
        return true
    }

    func applicationDidReceiveMemoryWarning(_ application: UIApplication) {
        DiagLog.log("⚠️ 記憶體不足警告（接下來可能被系統結束）")
    }

    func applicationWillTerminate(_ application: UIApplication) {
        DiagLog.log("App 被關閉（從多工畫面滑掉）")
        LiveActivityManager.endAllBeforeTermination()
        SharedStore.markClosed()
        WidgetCenter.shared.reloadAllTimelines()
    }
}

/// 全 App 共用的單一實例：讓 Siri／捷徑在背景啟動時也拿得到同一個引擎
@MainActor
final class AppModel {
    static let shared = AppModel()
    let auth: SpotifyAuth
    let engine: SyncEngine

    private init() {
        auth = SpotifyAuth()
        engine = SyncEngine(auth: auth)
    }
}

@main
struct DynLyricsApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var auth = AppModel.shared.auth
    @StateObject private var engine = AppModel.shared.engine
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(auth)
                .environmentObject(engine)
        }
        .onChange(of: scenePhase) { _, phase in
            DiagLog.log("App 畫面狀態：\(phase == .active ? "前景" : phase == .background ? "背景" : "非作用中")")
            if phase == .active { engine.appBecameActive() }
        }
    }
}
