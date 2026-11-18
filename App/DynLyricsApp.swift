import SwiftUI

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
