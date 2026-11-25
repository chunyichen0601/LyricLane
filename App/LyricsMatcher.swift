import Foundation

/// 歌詞搜尋用的比對工具：繁簡互查、歌手別名、標題比對。
///
/// 為什麼需要：Spotify 給的歌名／歌手常常跟 LRCLIB 收錄的寫法不同，例如
/// - Spotify 寫「Jay Chou」，LRCLIB 收的是「周杰伦」
/// - Spotify 是繁體「說好不哭」，LRCLIB 只有簡體「说好不哭」
/// 所以搜尋時要把歌名、歌手換成各種寫法都試一次。
/// 找到的歌詞一律在顯示時轉成繁體（`SyncEngine.rebuildLines`）。
///
/// 做法參考開源專案「沿途 CarPlayLyrics」（MIT）的 LRCLIB 查找邏輯與歌手別名表。
enum LyricsMatcher {
    // MARK: - 繁簡

    static func toSimplified(_ s: String) -> String {
        s.applyingTransform(StringTransform("Hant-Hans"), reverse: false) ?? s
    }

    static func toTraditional(_ s: String) -> String {
        s.applyingTransform(StringTransform("Hans-Hant"), reverse: false) ?? s
    }

    static func containsHan(_ s: String) -> Bool {
        s.range(of: "\\p{Han}", options: .regularExpression) != nil
    }

    /// 比對用的鍵：小寫、轉簡體、去掉標點與空白。繁簡、大小寫、標點不同都算同一個
    static func key(_ s: String) -> String {
        toSimplified(s.lowercased())
            .replacingOccurrences(of: "[\\p{P}\\p{S}\\s]+", with: "", options: .regularExpression)
    }

    // MARK: - 歌手別名（用繁體寫；比對時繁簡都認得）

    /// 同一組裡的名字都是同一位歌手。只用來搜尋歌詞，不會改顯示的歌手名稱。
    /// 要新增就加一行，第一個放中文名。
    private static let artistGroups: [[String]] = [
        ["周杰倫", "Jay Chou"],
        ["林俊傑", "JJ Lin", "J.J. Lin"],
        ["陳奕迅", "Eason Chan"],
        ["鄧紫棋", "G.E.M.", "GEM", "G.E.M.鄧紫棋"],
        ["陶喆", "David Tao"],
        ["李榮浩", "Ronghao Li", "Li Ronghao"],
        ["張信哲", "Jeff Chang"],
        ["黃麗玲", "A-Lin"],
        ["薛之謙", "Joker Xue"],
        ["蕭敬騰", "Jam Hsiao"],
        ["楊宗緯", "Aska Yang"],
        ["孫燕姿", "Stefanie Sun"],
        ["蔡依林", "Jolin Tsai"],
        ["張惠妹", "A-Mei", "aMEI"],
        ["莫文蔚", "Karen Mok"],
        ["王力宏", "Leehom Wang", "Wang Leehom"],
        ["王菲", "Faye Wong"],
        ["劉德華", "Andy Lau"],
        ["張學友", "Jacky Cheung"],
        ["張國榮", "Leslie Cheung"],
        ["梁靜茹", "Fish Leong"],
        ["梁詠琪", "Gigi Leung"],
        ["容祖兒", "Joey Yung"],
        ["楊千嬅", "Miriam Yeung"],
        ["許茹芸", "Valen Hsu"],
        ["林宥嘉", "Yoga Lin"],
        ["劉若英", "Rene Liu"],
        ["王心凌", "Cyndi Wang"],
        ["田馥甄", "Hebe Tien"],
        ["楊丞琳", "Rainie Yang"],
        ["周興哲", "Eric Chou"],
        ["五月天", "Mayday"],
        ["蘇打綠", "Sodagreen"],
        ["告五人", "Accusefive"],
        ["盧廣仲", "Crowd Lu"],
        ["韋禮安", "WeiBird"],
        ["吳青峰", "Qingfeng Wu"],
        ["徐佳瑩", "LaLa Hsu"],
        ["艾怡良", "Eve Ai"],
        ["魏如萱", "Waa Wei"],
        ["楊乃文", "Faith Yang"],
        ["伍佰", "Wu Bai"],
        ["張震嶽", "A-Yue"],
        ["動力火車", "Power Station"],
        ["戴佩妮", "Penny Tai"],
        ["蕭亞軒", "Elva Hsiao"],
        ["潘瑋柏", "Wilber Pan"],
        ["羅志祥", "Show Lo"],
        ["光良", "Michael Wong"],
        ["品冠", "Victor Wong"],
        ["草東沒有派對", "No Party For Cao Dong"],
        ["茄子蛋", "EggPlantEgg"],
        ["八三夭", "831"],
        ["毛不易", "Mao Buyi"],
        ["華晨宇", "Hua Chenyu"],
        ["張韶涵", "Angela Chang"],
        ["范瑋琪", "Christine Fan"],
        ["郭靜", "Claire Kuo"],
        ["李宗盛", "Jonathan Lee"],
        ["周華健", "Wakin Chau", "Emil Chau"],
        ["任賢齊", "Richie Jen"],
        ["伍思凱", "Sky Wu"],
        ["The Weeknd", "Weeknd", "Abel Tesfaye"],
    ]

    private static let groupsByKey: [String: [String]] = {
        var index: [String: [String]] = [:]
        for group in artistGroups {
            for name in group { index[key(name)] = group }
        }
        return index
    }()

    /// 搜尋用的歌手寫法：原名、別名，以及中文名的繁體／簡體版本（去重，原名排第一）
    static func artistVariants(_ artist: String) -> [String] {
        let original = cleanArtist(artist)
        var names = [original]
        if let group = groupsByKey[key(original)] { names += group }
        var out: [String] = []
        var seen = Set<String>()
        func add(_ s: String) {
            let t = s.trimmingCharacters(in: .whitespaces)
            guard !t.isEmpty, seen.insert(t.lowercased()).inserted else { return }
            out.append(t)
        }
        for n in names {
            add(n)
            if containsHan(n) {
                add(toSimplified(n))
                add(toTraditional(n))
            }
        }
        return out
    }

    /// 搜尋用的歌名寫法：原樣、繁體、簡體；中文歌名再加一個「標點換成空白」的版本
    static func titleVariants(_ title: String) -> [String] {
        var out: [String] = []
        var seen = Set<String>()
        func add(_ s: String) {
            let t = s.trimmingCharacters(in: .whitespaces)
            guard !t.isEmpty, seen.insert(t).inserted else { return }
            out.append(t)
        }
        add(title)
        if containsHan(title) {
            add(toSimplified(title))
            add(toTraditional(title))
            for t in out {
                add(t.replacingOccurrences(of: "[\\p{P}\\s]+", with: " ", options: .regularExpression))
            }
        }
        return out
    }

    /// 兩個歌手名是不是同一位（考慮別名與繁簡）
    static func sameArtist(_ a: String, _ b: String) -> Bool {
        let ka = key(cleanArtist(a)), kb = key(cleanArtist(b))
        if ka.isEmpty || kb.isEmpty { return false }
        if ka == kb || ka.contains(kb) || kb.contains(ka) { return true }
        if let group = groupsByKey[ka] { return group.contains { key($0) == kb } }
        return false
    }

    /// 去掉「feat. xxx」和括號，多位歌手只留第一位
    static func cleanArtist(_ s: String) -> String {
        var t = s
        for marker in [" feat. ", " feat ", " featuring ", " ft. ", " ft ", " & ", ", ", "、", " x ", " X "] {
            if let r = t.range(of: marker, options: .caseInsensitive) { t = String(t[..<r.lowerBound]) }
        }
        t = t.replacingOccurrences(of: #"\s*[\(\[（【][^\)\]）】]*[\)\]）】]"#, with: "", options: .regularExpression)
        return t.trimmingCharacters(in: .whitespaces)
    }
}
