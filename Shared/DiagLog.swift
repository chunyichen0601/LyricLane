import Foundation

/// 診斷紀錄：寫進 App Group 裡的檔案，App 和小工具共用同一份。
/// 開車時沒辦法接 Xcode 看 log，所以把關鍵事件記下來，事後從「進階與診斷」匯出。
///
/// 看紀錄的重點：
/// - 「第 i/N 句」一直有在記，但動態島沒動 → App 活著，是 iOS 沒把更新顯示出來（節流）
/// - 紀錄中間出現一大段空白，或「計時器晚了 X 秒」→ App 被系統暫停過
/// - 「App 啟動」出現在開車途中 → App 被系統結束後又被叫起來
enum DiagLog {
    private static let queue = DispatchQueue(label: "lyriclane.diaglog")
    private static let maxBytes = 768 * 1024

    #if WIDGET_EXTENSION
    private static let tag = "小工具"
    #else
    private static let tag = "App"
    #endif

    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "MM-dd HH:mm:ss.SSS"
        return f
    }()

    static var fileURL: URL? { SharedStore.containerURL?.appendingPathComponent("LyricLane-diag.txt") }

    static func log(_ message: String) {
        let now = Date()
        queue.async {
            guard let url = fileURL else { return }
            let line = "\(formatter.string(from: now)) [\(tag)] \(message)\n"
            guard let data = line.data(using: .utf8) else { return }
            trimIfNeeded(url)
            if let handle = try? FileHandle(forWritingTo: url) {
                defer { try? handle.close() }
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: data)
            } else {
                try? data.write(to: url, options: .atomic)
            }
        }
    }

    /// 最後 n 行（給 App 裡的「查看最近紀錄」用）
    static func tail(_ n: Int) -> String {
        queue.sync {
            guard let url = fileURL, let text = try? String(contentsOf: url, encoding: .utf8) else { return "" }
            return text.split(separator: "\n", omittingEmptySubsequences: true).suffix(n).joined(separator: "\n")
        }
    }

    static func clear() {
        queue.async {
            guard let url = fileURL else { return }
            try? FileManager.default.removeItem(at: url)
        }
        log("紀錄已清除")
    }

    /// 超過上限就只留後半段，避免檔案一直長大
    private static func trimIfNeeded(_ url: URL) {
        guard let size = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int,
              size > maxBytes,
              let data = try? Data(contentsOf: url) else { return }
        var tail = data.suffix(maxBytes / 2)
        // 從下一個換行開始，不要留半行
        if let nl = tail.firstIndex(of: UInt8(ascii: "\n")) { tail = tail[(nl + 1)...] }
        try? Data(tail).write(to: url, options: .atomic)
    }
}
