import SwiftUI
import UIKit
import WidgetKit

/// 從多工畫面把 App 滑掉時，iOS 會呼叫 applicationWillTerminate：
/// 在這裡關掉即時動態（動態島、鎖定畫面、CarPlay），並把小工具改成「已關閉」。
final class AppDelegate: NSObject, UIApplicationDelegate {
    func applicationWillTerminate(_ application: UIApplication) {
        LiveActivityManager.endAllBeforeTermination()
        SharedStore.markClosed()
        WidgetCenter.shared.reloadTimelines(ofKind: SharedStore.widgetKind)
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
            if phase == .active { engine.appBecameActive() }
        }
    }
}
