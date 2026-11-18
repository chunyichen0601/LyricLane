import Foundation

struct PlaybackSnapshot: Equatable {
    let trackID: String
    let title: String
    let artist: String        // 顯示用，多位歌手以逗號分隔
    let primaryArtist: String // 搜尋歌詞用
    let album: String
    let durationMs: Int
    let progressMs: Int
    let isPlaying: Bool
    /// 本機時間：progressMs 在這個時間點成立（已扣掉一半網路來回時間）
    let sampledAt: Date
}

enum SpotifyError: LocalizedError {
    case unauthorized
    case rateLimited(Int)
    case http(Int)

    var errorDescription: String? {
        switch self {
        case .unauthorized: return "Spotify 授權失效"
        case let .rateLimited(s): return "Spotify 限流 \(s) 秒"
        case let .http(c): return "Spotify HTTP \(c)"
        }
    }
}

@MainActor
final class SpotifyClient {
    private let auth: SpotifyAuth
    // 共用同一個 session，讓 HTTP 連線保持 keep-alive，降低每次輪詢的延遲
    private let session: URLSession = {
        let c = URLSessionConfiguration.default
        c.timeoutIntervalForRequest = 6
        c.requestCachePolicy = .reloadIgnoringLocalCacheData
        c.urlCache = nil
        return URLSession(configuration: c)
    }()

    init(auth: SpotifyAuth) { self.auth = auth }

    /// 回傳 nil 代表目前沒有在播放任何東西
    func currentlyPlaying() async throws -> PlaybackSnapshot? {
        let token = try await auth.validToken()
        var req = URLRequest(url: URL(string: "https://api.spotify.com/v1/me/player/currently-playing?additional_types=track,episode")!)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        let t0 = Date()
        let (data, resp) = try await session.data(for: req)
        let t1 = Date()

        let http = resp as? HTTPURLResponse
        switch http?.statusCode ?? 0 {
        case 200: break
        case 204: return nil
        case 401:
            auth.invalidate()
            throw SpotifyError.unauthorized
        case 429:
            let wait = Int(http?.value(forHTTPHeaderField: "Retry-After") ?? "") ?? 5
            throw SpotifyError.rateLimited(wait)
        case let code:
            throw SpotifyError.http(code)
        }

        let r = try JSONDecoder().decode(CurrentlyPlaying.self, from: data)
        guard let item = r.item, let progress = r.progress_ms else { return nil }

        // Spotify 回傳的 timestamp 欄位不可靠，改用本機量到的來回時間中點
        let sampledAt = t0.addingTimeInterval(t1.timeIntervalSince(t0) / 2)
        let artists = item.artists?.map(\.name) ?? []
        let artist = artists.isEmpty ? (item.show?.name ?? "") : artists.joined(separator: ", ")

        return PlaybackSnapshot(
            trackID: item.id ?? item.uri ?? item.name,
            title: item.name,
            artist: artist,
            primaryArtist: artists.first ?? artist,
            album: item.album?.name ?? "",
            durationMs: item.duration_ms,
            progressMs: progress,
            isPlaying: r.is_playing,
            sampledAt: sampledAt
        )
    }

    private struct CurrentlyPlaying: Decodable {
        let is_playing: Bool
        let progress_ms: Int?
        let item: Item?

        struct Item: Decodable {
            let id: String?
            let uri: String?
            let name: String
            let duration_ms: Int
            let artists: [Named]?
            let album: Named?
            let show: Named?
        }
        struct Named: Decodable { let name: String }
    }
}
