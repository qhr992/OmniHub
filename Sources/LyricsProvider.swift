import Foundation

extension Notification.Name {
    static let lyricsChanged = Notification.Name("omnihub.lyricsChanged")
}

/// Time-synced lyrics for the current track, looked up online by title and
/// artist: NetEase Cloud Music first (best coverage for Chinese songs), then
/// LRCLIB. Results are cached for the session; a miss is cached too.
final class LyricsProvider {
    static let shared = LyricsProvider()

    struct Line {
        let time: Double
        let text: String
    }

    private var cache: [String: [Line]] = [:]
    private var loading: Set<String> = []
    private let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 8
        return URLSession(configuration: configuration)
    }()

    private func key(_ title: String, _ artist: String) -> String { "\(title)\u{1F}\(artist)" }

    /// Cached lines, or nil while unknown (a lookup is started). An empty
    /// array means "looked, none found".
    func lines(title: String, artist: String) -> [Line]? {
        guard !title.isEmpty else { return [] }
        let key = key(title, artist)
        if let hit = cache[key] { return hit }
        guard !loading.contains(key) else { return nil }
        loading.insert(key)
        fetch(title: title, artist: artist) { [weak self] lines in
            DispatchQueue.main.async {
                self?.loading.remove(key)
                self?.cache[key] = lines
                NotificationCenter.default.post(name: .lyricsChanged, object: nil)
            }
        }
        return nil
    }

    /// The line being sung at `position`.
    static func current(in lines: [Line], at position: Double) -> String? {
        var result: String?
        for line in lines {
            if line.time > position + 0.15 { break }
            result = line.text
        }
        return result
    }

    // MARK: Lookup

    private func fetch(title: String, artist: String, completion: @escaping ([Line]) -> Void) {
        fetchNetEase(title: title, artist: artist) { [weak self] lines in
            if !lines.isEmpty { completion(lines); return }
            guard let self else { completion([]); return }
            self.fetchLRCLib(title: title, artist: artist, completion: completion)
        }
    }

    private func json(_ url: URL, headers: [String: String] = [:], completion: @escaping (Any?) -> Void) {
        var request = URLRequest(url: url)
        request.setValue("OmniHub/1.1 (macOS)", forHTTPHeaderField: "User-Agent")
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        session.dataTask(with: request) { data, _, _ in
            completion(data.flatMap { try? JSONSerialization.jsonObject(with: $0) })
        }.resume()
    }

    private func url(_ base: String, _ query: [String: String]) -> URL? {
        var components = URLComponents(string: base)
        components?.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) }
        return components?.url
    }

    private static func normalized(_ text: String) -> String {
        text.lowercased().filter { !$0.isWhitespace && !$0.isPunctuation }
    }

    private func fetchNetEase(title: String, artist: String, completion: @escaping ([Line]) -> Void) {
        let headers = ["Referer": "https://music.163.com"]
        guard let search = url("https://music.163.com/api/search/get",
                               ["s": "\(title) \(artist)", "type": "1", "limit": "5"]) else {
            completion([]); return
        }
        json(search, headers: headers) { [weak self] object in
            guard let self,
                  let songs = ((object as? [String: Any])?["result"] as? [String: Any])?["songs"] as? [[String: Any]],
                  !songs.isEmpty else { completion([]); return }
            // Prefer an exact title match; never take a different song.
            let wanted = Self.normalized(title)
            guard let song = songs.first(where: { Self.normalized($0["name"] as? String ?? "") == wanted }),
                  let id = song["id"] as? NSNumber,
                  let lyric = self.url("https://music.163.com/api/song/lyric", ["id": id.stringValue, "lv": "1"])
            else { completion([]); return }
            self.json(lyric, headers: headers) { object in
                let text = ((object as? [String: Any])?["lrc"] as? [String: Any])?["lyric"] as? String ?? ""
                completion(Self.parseLRC(text))
            }
        }
    }

    private func fetchLRCLib(title: String, artist: String, completion: @escaping ([Line]) -> Void) {
        guard let search = url("https://lrclib.net/api/search",
                               ["track_name": title, "artist_name": artist]) else { completion([]); return }
        json(search) { object in
            let hits = object as? [[String: Any]] ?? []
            let synced = hits.compactMap { $0["syncedLyrics"] as? String }.first { !$0.isEmpty } ?? ""
            completion(Self.parseLRC(synced))
        }
    }

    /// "[01:23.45]text" lines (several time tags per line allowed).
    static func parseLRC(_ text: String) -> [Line] {
        var out: [Line] = []
        let credits = ["作词", "作曲", "编曲", "制作", "监制", "混音", "母带", "录音", "出品", "和声", "吉他", "贝斯", "鼓", "弦乐"]
        for raw in text.split(whereSeparator: \.isNewline) {
            var rest = Substring(raw)
            var times: [Double] = []
            while rest.hasPrefix("["), let close = rest.firstIndex(of: "]") {
                let tag = rest[rest.index(after: rest.startIndex)..<close]
                let parts = tag.split(separator: ":")
                if parts.count == 2, let minutes = Double(parts[0]), let seconds = Double(parts[1]) {
                    times.append(minutes * 60 + seconds)
                }
                rest = rest[rest.index(after: close)...]
            }
            let line = rest.trimmingCharacters(in: .whitespaces)
            guard !times.isEmpty, !line.isEmpty else { continue }
            // Credit lines ("作词 : …") are not lyrics.
            if credits.contains(where: { line.hasPrefix($0) }) && (line.contains(":") || line.contains("：")) { continue }
            for time in times { out.append(Line(time: time, text: line)) }
        }
        return out.sorted { $0.time < $1.time }
    }
}
