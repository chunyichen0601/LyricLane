import Foundation

final class AppSettings: ObservableObject {
    static let shared = AppSettings()

    /// Spotify Developer Dashboard 的 Client ID
    @Published var clientID: String {
        didSet { UserDefaults.standard.set(clientID, forKey: "clientID") }
    }
    /// 正值 = 歌詞提早出現（毫秒）。預設 +150ms 補償即時動態的渲染延遲。
    @Published var offsetMs: Double {
        didSet { UserDefaults.standard.set(offsetMs, forKey: "offsetMs") }
    }
    @Published var toTraditional: Bool {
        didSet { UserDefaults.standard.set(toTraditional, forKey: "toTraditional") }
    }

    /// CarPlay 歌詞字級
    @Published var carFontSize: Double {
        didSet { UserDefaults.standard.set(carFontSize, forKey: "carFontSize") }
    }
    @Published var carShowNext: Bool {
        didSet { UserDefaults.standard.set(carShowNext, forKey: "carShowNext") }
    }

    /// 優先用 App Remote 直連手機上的 Spotify（最準）
    @Published var useAppRemote: Bool {
        didSet { UserDefaults.standard.set(useAppRemote, forKey: "useAppRemote") }
    }

    /// 打開 App／連上 CarPlay 時是否自動開啟即時動態（動態島、鎖定畫面、CarPlay 即時動態）。
    /// 預設關閉：只用 CarPlay 小工具，不會佔用動態島。
    @Published var autoLiveActivity: Bool {
        didSet { UserDefaults.standard.set(autoLiveActivity, forKey: "autoLiveActivity") }
    }

    /// CarPlay／主畫面小工具底部顯示 🐢／🐇 微調按鈕（會讓歌詞字變小一點）
    @Published var widgetAdjustButtons: Bool {
        didSet { UserDefaults.standard.set(widgetAdjustButtons, forKey: "widgetAdjustButtons") }
    }

    private init() {
        let d = UserDefaults.standard
        widgetAdjustButtons = d.object(forKey: "widgetAdjustButtons") as? Bool ?? false
        autoLiveActivity = d.object(forKey: "autoLiveActivity") as? Bool ?? false
        useAppRemote = d.object(forKey: "useAppRemote") as? Bool ?? true
        clientID = d.string(forKey: "clientID") ?? ""
        offsetMs = d.object(forKey: "offsetMs") as? Double ?? 150
        toTraditional = d.object(forKey: "toTraditional") as? Bool ?? true
        carFontSize = d.object(forKey: "carFontSize") as? Double ?? 26
        carShowNext = d.object(forKey: "carShowNext") as? Bool ?? false
    }
}

enum Keychain {
    private static func base(_ key: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: "dynlyrics",
         kSecAttrAccount as String: key]
    }

    static func set(_ value: String?, for key: String) {
        SecItemDelete(base(key) as CFDictionary)
        guard let value else { return }
        var add = base(key)
        add[kSecValueData as String] = Data(value.utf8)
        // 車上手機常是鎖定狀態，背景也要讀得到
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(add as CFDictionary, nil)
    }

    static func get(_ key: String) -> String? {
        var q = base(key)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess,
              let data = out as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
