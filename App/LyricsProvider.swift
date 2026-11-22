import Foundation

struct LyricLine: Codable, Hashable {
    let time: Double // 秒
    let text: String
}

enum LRCParser {
    private static let tag = try! NSRegularExpression(pattern: #"\[(\d{1,3}):(\d{1,2})(?:[.:](\d{1,3}))?\]"#)

    static func parse(_ lrc: String) -> [LyricLine] {
        var out: [LyricLine] = []
        var offset = 0.0

        for raw in lrc.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.lowercased().hasPrefix("[offset:") {
                let v = line.dropFirst(8).dropLast().trimmingCharacters(in: .whitespaces)
                offset = (Double(v) ?? 0) / 1000
                continue
            }
            let ns = line as NSString
            let matches = tag.matches(in: line, range: NSRange(location: 0, length: ns.length))
            guard let last = matches.last else { continue }

            var text = ns.substring(from: last.range.location + last.range.length)
            // 去掉逐字時間標記 <00:12.34>
            text = text.replacingOccurrences(of: #"<\d+:\d+(?:[.:]\d+)?>"#, with: "", options: .regularExpression)
                .trimmingCharacters(in: .whitespaces)

            for m in matches {
                let min = Double(ns.substring(with: m.range(at: 1))) ?? 0
                let sec = Double(ns.substring(with: m.range(at: 2))) ?? 0
                var frac = 0.0
                if m.range(at: 3).location != NSNotFound {
                    let f = ns.substring(with: m.range(at: 3))
                    frac = (Double(f) ?? 0) / pow(10, Double(f.count))
                }
                out.append(LyricLine(time: min * 60 + sec + frac - offset, text: text))
            }
        }

        out.sort { $0.time < $1.time }

        // 同一時間點的多行（例如原文＋翻譯）合併成一句
        var merged: [LyricLine] = []
        for l in out {
            if let prev = merged.last, abs(prev.time - l.time) < 0.01 {
                let joined = [prev.text, l.text].filter { !$0.isEmpty }.joined(separator: "\n")
                merged[merged.count - 1] = LyricLine(time: prev.time, text: joined)
            } else {
                merged.append(l)
            }
        }
        return merged
    }
}

/// 從 LRCLIB（免費、開放的同步歌詞資料庫）取得歌詞，並快取到磁碟。
@MainActor
final class LyricsProvider {
    private var memory: [String: [LyricLine]] = [:]

    private let dir: URL = {
        let d = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("lyrics", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }()

    private let session: URLSession = {
        let c = URLSessionConfiguration.default
        c.timeoutIntervalForRequest = 8
        c.httpAdditionalHeaders = ["User-Agent": "DynLyrics/1.0 (personal use)"]
        return URLSession(configuration: c)
    }()

    private struct Record: Decodable {
        let trackName: String?
        let artistName: String?
        let duration: Double?
        let instrumental: Bool?
        let syncedLyrics: String?
    }

    /// 這首歌的歌詞是不是已經在手機裡（記憶體或磁碟）
    func hasCached(_ key: String) -> Bool {
        if memory[key] != nil { return true }
        let safe = key.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? "x"
        return FileManager.default.fileExists(atPath: dir.appendingPathComponent(safe + ".json").path)
    }

    /// 忘掉某首歌的歌詞（記憶體＋磁碟），下次重新抓
    func forget(_ key: String) {
        memory.removeValue(forKey: key)
        let safe = key.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? "x"
        try? FileManager.default.removeItem(at: dir.appendingPathComponent(safe + ".json"))
    }

    /// 找不到時回傳空陣列
    func lyrics(for s: PlaybackSnapshot) async -> [LyricLine] {
        let key = s.trackID
        if let m = memory[key] { return m }

        let safe = key.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? "x"
        let file = dir.appendingPathComponent(safe + ".json")
        if let d = try? Data(contentsOf: file),
           let cached = try? JSONDecoder().decode([LyricLine].self, from: d) {
            memory[key] = cached
            return cached
        }

        let lines = await fetch(title: s.title, artist: s.primaryArtist, album: s.album, durationMs: s.durationMs)
        // 跳歌時被取消的請求不能記成「找不到」，否則切回這首歌會一直沒有歌詞
        guard !Task.isCancelled else { return [] }
        // 只快取找到的歌詞；找不到（可能只是網路不穩）下次再試
        if !lines.isEmpty {
            memory[key] = lines
            if let d = try? JSONEncoder().encode(lines) { try? d.write(to: file) }
        }
        return lines
    }

    /// 每首歌最多打幾次 LRCLIB（各種寫法排列組合很多，不能無限試）
    private static let requestBudget = 16

    private func fetch(title: String, artist: String, album: String, durationMs: Int) async -> [LyricLine] {
        let dur = Double(durationMs) / 1000
        var budget = Self.requestBudget
        var tried = 0

        // 1. 精準比對（歌名＋歌手＋專輯＋長度）
        budget -= 1; tried += 1
        if let r: Record = await get("api/get", [
            ("track_name", title), ("artist_name", artist),
            ("album_name", album), ("duration", String(Int(dur.rounded()))),
        ]) {
            if r.instrumental == true { return [LyricLine(time: 0, text: "♪ 純音樂 ♪")] }
            if let s = r.syncedLyrics {
                let l = LRCParser.parse(s)
                if !l.isEmpty { return l }
            }
        }

        // 2. 模糊搜尋：歌名 × 歌手的各種寫法（繁體、簡體、英文名／中文名別名）
        let cleaned = Self.clean(title)
        let titles = LyricsMatcher.titleVariants(cleaned)
        let artists = LyricsMatcher.artistVariants(artist)
        var queries: [[(String, String)]] = []
        for a in artists {
            for t in titles { queries.append([("track_name", t), ("artist_name", a)]) }
        }
        // 3. 最後只用歌名搜（這時一定要歌名、歌手或長度對得上才採用）
        let titleOnly = titles.map { [("q", $0)] }

        var seen = Set<String>()
        for (i, q) in (queries + titleOnly).enumerated() {
            if Task.isCancelled || budget <= 0 { break } // 已經跳到下一首，或試夠多次了
            let sig = q.map { "\($0.0)=\($0.1)" }.joined(separator: "&")
            guard seen.insert(sig).inserted else { continue }
            budget -= 1; tried += 1
            guard let results: [Record] = await get("api/search", q) else { continue }
            let strict = i >= queries.count
            if let lines = pick(results, title: cleaned, artist: artist, duration: dur, strict: strict) {
                if tried > 2 {
                    DiagLog.log("歌詞：換寫法才找到（第 \(tried) 次查詢：\(q.map(\.1).joined(separator: " / "))）")
                }
                return lines
            }
        }
        return []
    }

    /// 從搜尋結果挑最像的：歌名相同 > 歌手相同（含別名、繁簡）> 長度最接近
    private func pick(_ results: [Record], title: String, artist: String, duration: Double, strict: Bool) -> [LyricLine]? {
        let wantTitle = LyricsMatcher.key(title)
        struct Candidate { let titleOK: Bool; let artistOK: Bool; let diff: Double; let lrc: String }
        let candidates: [Candidate] = results.compactMap { r in
            guard let lrc = r.syncedLyrics, !lrc.isEmpty else { return nil }
            let diff = duration > 0 ? abs((r.duration ?? duration) - duration) : 0
            guard diff < 8 else { return nil }
            let titleOK = LyricsMatcher.key(Self.clean(r.trackName ?? "")) == wantTitle
            let artistOK = LyricsMatcher.sameArtist(r.artistName ?? "", artist)
            // 只用歌名搜的結果容易抓錯同名歌：歌名要對，而且歌手對得上或長度差 3 秒內
            if strict, !(titleOK && (artistOK || diff < 3)) { return nil }
            // 有指定歌手的搜尋：歌名或歌手至少一個要對得上
            if !strict, !(titleOK || artistOK) { return nil }
            return Candidate(titleOK: titleOK, artistOK: artistOK, diff: diff, lrc: lrc)
        }
        let best = candidates.min { a, b in
            if a.titleOK != b.titleOK { return a.titleOK }
            if a.artistOK != b.artistOK { return a.artistOK }
            return a.diff < b.diff
        }
        guard let best else { return nil }
        let lines = LRCParser.parse(best.lrc)
        return lines.isEmpty ? nil : lines
    }

    private func get<T: Decodable>(_ path: String, _ items: [(String, String)]) async -> T? {
        var c = URLComponents(string: "https://lrclib.net/" + path)!
        c.queryItems = items.map { URLQueryItem(name: $0.0, value: $0.1) }
        c.percentEncodedQuery = c.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        guard let url = c.url,
              let result = try? await session.data(from: url),
              (result.1 as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return try? JSONDecoder().decode(T.self, from: result.0)
    }

    /// 去掉「 - Remastered」「(feat. xxx)」之類的後綴
    static func clean(_ title: String) -> String {
        var s = title
        if let r = s.range(of: " - ") { s = String(s[..<r.lowerBound]) }
        s = s.replacingOccurrences(of: #"\s*[\(\[（【][^\)\]）】]*[\)\]）】]"#, with: "", options: .regularExpression)
        let t = s.trimmingCharacters(in: .whitespaces)
        return t.isEmpty ? title : t
    }
}
