import Foundation

extension Notification.Name {
    static let lyricsChanged = Notification.Name("omnihub.lyricsChanged")
}

/// Time-synced lyrics for the current track, looked up online by title and
/// artist: NetEase Cloud Music first (best coverage for Chinese songs), then
/// LRCLIB. Results are cached for the session; a miss is cached too.
///
/// Players decorate titles ("像鱼 (Live)", "如果累了就回故乡 (去山野里走一趟)"),
/// so a title also matches without its brackets and a trailing " - …"; the
/// artist must match too, because a cover with the same title has other timing,
/// and so must the length: a remix or DJ version under the same name
/// ("孤城(空灵鼓版梦幻DJ)", 278 s, vs "孤城", 227 s) would run out of step.
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

    private func key(_ title: String, _ artist: String, _ duration: Double) -> String {
        "\(title)\u{1F}\(artist)\u{1F}\(Int(duration.rounded()))"
    }

    /// Cached lines, or nil while unknown (a lookup is started). An empty
    /// array means "looked, none found".
    /// `duration`: the playing track's length in seconds (0 when unknown).
    func lines(title: String, artist: String, duration: Double = 0) -> [Line]? {
        guard !title.isEmpty else { return [] }
        let key = key(title, artist, duration)
        if let hit = cache[key] { return hit }
        guard !loading.contains(key) else { return nil }
        loading.insert(key)
        fetch(title: title, artist: artist, duration: duration) { [weak self] lines in
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

    private func fetch(title: String, artist: String, duration: Double, completion: @escaping ([Line]) -> Void) {
        fetchNetEase(title: title, artist: artist, duration: duration) { [weak self] lines in
            if !lines.isEmpty { completion(lines); return }
            guard let self else { completion([]); return }
            self.fetchLRCLib(title: title, artist: artist, duration: duration, completion: completion)
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

    /// The titles to search with: as the player says it, then without decorations.
    private static func searchTitles(_ title: String) -> [String] {
        let plain = LyricsMatch.undecorated(title)
        return plain.isEmpty || plain == title ? [title] : [title, plain]
    }

    /// Runs `step` for each title until one finds lines.
    private func firstHit(_ titles: [String], _ step: @escaping (String, @escaping ([Line]) -> Void) -> Void,
                          completion: @escaping ([Line]) -> Void) {
        guard let title = titles.first else { completion([]); return }
        step(title) { [weak self] lines in
            if !lines.isEmpty { completion(lines); return }
            guard let self else { completion([]); return }
            self.firstHit(Array(titles.dropFirst()), step, completion: completion)
        }
    }

    private func fetchNetEase(title: String, artist: String, duration: Double, completion: @escaping ([Line]) -> Void) {
        firstHit(Self.searchTitles(title), { [weak self] query, done in
            self?.fetchNetEase(query: query, title: title, artist: artist, duration: duration, completion: done) ?? done([])
        }, completion: completion)
    }

    private func fetchNetEase(query: String, title: String, artist: String, duration: Double,
                              completion: @escaping ([Line]) -> Void) {
        let headers = ["Referer": "https://music.163.com"]
        guard let search = url("https://music.163.com/api/search/get",
                               ["s": "\(query) \(artist)", "type": "1", "limit": "10"]) else {
            completion([]); return
        }
        json(search, headers: headers) { [weak self] object in
            guard let self,
                  let songs = ((object as? [String: Any])?["result"] as? [String: Any])?["songs"] as? [[String: Any]],
                  !songs.isEmpty else { completion([]); return }
            // Same title and same artist; never another song or someone's cover.
            let song = LyricsMatch.best(songs, title: title, artist: artist, duration: duration,
                                        name: { $0["name"] as? String ?? "" },
                                        artists: { ($0["artists"] as? [[String: Any]] ?? []).compactMap { $0["name"] as? String } },
                                        length: { (($0["duration"] as? NSNumber)?.doubleValue ?? 0) / 1000 })
            guard let id = song?["id"] as? NSNumber,
                  let lyric = self.url("https://music.163.com/api/song/lyric", ["id": id.stringValue, "lv": "1"])
            else { completion([]); return }
            self.json(lyric, headers: headers) { object in
                let text = ((object as? [String: Any])?["lrc"] as? [String: Any])?["lyric"] as? String ?? ""
                completion(Self.parseLRC(text))
            }
        }
    }

    private func fetchLRCLib(title: String, artist: String, duration: Double, completion: @escaping ([Line]) -> Void) {
        firstHit(Self.searchTitles(title), { [weak self] query, done in
            guard let self, let search = self.url("https://lrclib.net/api/search",
                                                  ["track_name": query, "artist_name": artist]) else { done([]); return }
            self.json(search) { object in
                let hits = (object as? [[String: Any]] ?? []).filter { !(($0["syncedLyrics"] as? String) ?? "").isEmpty }
                let hit = LyricsMatch.best(hits, title: title, artist: artist, duration: duration,
                                           name: { $0["trackName"] as? String ?? "" },
                                           artists: { [$0["artistName"] as? String ?? ""] },
                                           length: { ($0["duration"] as? NSNumber)?.doubleValue ?? 0 })
                done(Self.parseLRC(hit?["syncedLyrics"] as? String ?? ""))
            }
        }, completion: completion)
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

/// Whether an online search result is the track that is playing.
enum LyricsMatch {
    /// Lowercased, without spaces and punctuation: "G.E.M. 邓紫棋" → "gem邓紫棋".
    static func folded(_ text: String) -> String {
        text.lowercased().filter { !$0.isWhitespace && !$0.isPunctuation && !$0.isSymbol }
    }

    /// Drops bracketed parts ("(Live)", "（去山野里走一趟）", "[Explicit]", "【DJ版】")
    /// and a trailing " - Remastered" style suffix.
    static func undecorated(_ text: String) -> String {
        var out = ""
        var depth = 0
        for character in text {
            switch character {
            case "(", "[", "（", "【", "《": depth += 1
            case ")", "]", "）", "】", "》": depth = max(0, depth - 1)
            default: if depth == 0 { out.append(character) }
            }
        }
        for separator in [" - ", " – ", " — "] {
            if let range = out.range(of: separator) { out = String(out[..<range.lowerBound]) }
        }
        return out.trimmingCharacters(in: .whitespaces)
    }

    /// Same title, or the same once decorations are dropped on both sides.
    /// No containment: one song's name can be the start of another's.
    static func title(_ candidate: String, matches wanted: String) -> Bool {
        let a = folded(candidate), b = folded(wanted)
        guard !a.isEmpty, !b.isEmpty else { return false }
        if a == b { return true }
        let plainA = folded(undecorated(candidate)), plainB = folded(undecorated(wanted))
        return !plainA.isEmpty && plainA == plainB
    }

    /// Some artist of the result is one of the playing track's artists
    /// ("A / B", "A、B", "A&B", "A feat. B"). An unknown artist matches anything.
    static func artists(_ candidates: [String], match wanted: String) -> Bool {
        let people = names(wanted)
        guard !people.isEmpty else { return true }
        let found = candidates.flatMap(names)
        return found.contains { name in
            people.contains { $0 == name || (min($0.count, name.count) >= 2 && ($0.contains(name) || name.contains($0))) }
        }
    }

    /// Versions without vocals; skipped unless that is what is playing.
    static let instrumentalWords = ["伴奏", "纯音乐", "instrumental", "karaoke", "off vocal", "inst."]

    static func isInstrumental(_ title: String) -> Bool {
        let lower = title.lowercased()
        return instrumentalWords.contains { lower.contains($0) }
    }

    /// Lengths of one recording on two services differ by a second or two
    /// (trimmed silence); another version of the song is off by much more.
    static func sameLength(_ candidate: Double, _ wanted: Double) -> Bool {
        guard candidate > 0, wanted > 0 else { return true }   // unknown: cannot tell
        return abs(candidate - wanted) <= max(4, wanted * 0.02)
    }

    /// The result that is the playing track: same title, artist and length
    /// (`duration` 0 = unknown), the exact title first, then the plain one
    /// before other versions ("像鱼" before "像鱼（DJ版）"), and no
    /// instrumental unless the playing title is one.
    static func best<T>(_ results: [T], title wanted: String, artist: String, duration: Double = 0,
                        name: (T) -> String, artists: (T) -> [String], length: (T) -> Double = { _ in 0 }) -> T? {
        let wantsInstrumental = isInstrumental(wanted)
        let matching = results.filter { result in
            let candidate = name(result)
            return title(candidate, matches: wanted) && self.artists(artists(result), match: artist)
                && (wantsInstrumental || !isInstrumental(candidate))
                && sameLength(length(result), duration)
        }
        // Exact title, then a plain one ("像鱼"), then another version ("像鱼（DJ版）").
        func rank(_ result: T) -> Int {
            let candidate = name(result)
            if folded(candidate) == folded(wanted) { return 0 }
            return folded(undecorated(candidate)) == folded(candidate) ? 1 : 2
        }
        return matching.enumerated().min { (rank($0.element), $0.offset) < (rank($1.element), $1.offset) }?.element
    }

    private static func names(_ text: String) -> [String] {
        var parts = [text]
        for separator in ["/", "、", "&", "，", ",", ";", " x ", " X ", " feat. ", " feat ", " ft. ", " with "] {
            parts = parts.flatMap { $0.components(separatedBy: separator) }
        }
        return parts.map(folded).filter { !$0.isEmpty }
    }
}
