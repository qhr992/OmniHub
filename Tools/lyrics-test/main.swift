import Foundation

// Matching rules for online lyrics (offline), and with `--live` real lookups
// against NetEase / LRCLIB for a few tracks as players report them.
//
//   swiftc -O -o build/lyrics-test Sources/LyricsProvider.swift Tools/lyrics-test/main.swift
//   ./build/lyrics-test [--live]

var failures = 0

func check(_ name: String, _ ok: Bool, _ detail: String = "") {
    if !ok { failures += 1 }
    print((ok ? "PASS  " : "FAIL  ") + name + (ok || detail.isEmpty ? "" : "  — \(detail)"))
}

func offline() {
    check("decorations are dropped: brackets of every kind and a trailing \" - …\"",
          LyricsMatch.undecorated("如果累了就回故乡 (去山野里走一趟)") == "如果累了就回故乡"
          && LyricsMatch.undecorated("像鱼（Live）") == "像鱼"
          && LyricsMatch.undecorated("Song [Explicit] - 2011 Remaster") == "Song"
          && LyricsMatch.undecorated("【DJ版】晴天") == "晴天")
    check("a decorated title matches the plain one, both ways",
          LyricsMatch.title("像鱼", matches: "像鱼 (Live)")
          && LyricsMatch.title("如果累了就回故乡(微醺版)", matches: "如果累了就回故乡 (去山野里走一趟)"))
    check("spacing, case and punctuation do not matter",
          LyricsMatch.title("Good Things Fall Apart", matches: "good things fall apart!"))
    check("a different title never matches, not even one that starts the same",
          !LyricsMatch.title("晴天", matches: "晴天娃娃") && !LyricsMatch.title("自由", matches: "自由的你"))
    check("the artist must match: a cover by someone else is rejected",
          !LyricsMatch.artists(["马洪旺"], match: "苏栖") && LyricsMatch.artists(["苏栖"], match: "苏栖"))
    check("artist names compare loosely (spacing, dots) and per person in a list",
          LyricsMatch.artists(["G.E.M. 邓紫棋"], match: "G.E.M.邓紫棋")
          && LyricsMatch.artists(["周杰伦", "费玉清"], match: "费玉清 / 周杰伦")
          && LyricsMatch.artists(["Le Youth"], match: "Le Youth & Someone")
          && LyricsMatch.artists(["酷酷里/小咩羊"], match: "小咩羊"))
    check("an unknown artist matches anything", LyricsMatch.artists(["任何人"], match: ""))
    let results = [("像鱼 (伴奏)", "王贰浪"), ("像鱼（DJ阳少版）", "王贰浪"), ("像鱼", "马某"), ("像鱼", "王贰浪")]
    let pick = LyricsMatch.best(results, title: "像鱼 (Live)", artist: "王贰浪", name: { $0.0 }, artists: { [$0.1] })
    check("the best result skips instrumentals and covers, and prefers the plain title over a DJ version",
          pick?.0 == "像鱼" && pick?.1 == "王贰浪", "\(String(describing: pick))")
    let exact = LyricsMatch.best([("像鱼", "王贰浪"), ("像鱼 (Live)", "王贰浪")], title: "像鱼 (Live)", artist: "王贰浪",
                                 name: { $0.0 }, artists: { [$0.1] })
    check("… and an exact title over a plain one", exact?.0 == "像鱼 (Live)", "\(String(describing: exact))")
    check("an instrumental is taken when that is what plays",
          LyricsMatch.best([("像鱼 (伴奏)", "王贰浪")], title: "像鱼 (伴奏)", artist: "王贰浪",
                           name: { $0.0 }, artists: { [$0.1] }) != nil)
    check("LRC parsing keeps lyrics and drops credit lines",
          LyricsProvider.parseLRC("[00:01.00]作词 : 某人\n[00:05.50]第一行\n[00:09.00]第二行").map(\.text) == ["第一行", "第二行"])
}

/// Real lookups through LyricsProvider (network). Each entry: title and artist
/// as the player reports them, and whether lyrics should be found.
func live() {
    let cases: [(String, String, Bool, String)] = [
        ("自由的你", "G.E.M.邓紫棋", true, "plain title (QQ Music)"),
        ("像鱼 (Live)", "王贰浪", true, "decorated title"),
        ("Chills", "Le Youth", true, "English title (NetEase)"),
        ("如果累了就回故乡 (去山野里走一趟)", "苏栖", false, "汽水音乐 cover found nowhere: no one else's lyrics"),
    ]
    for (title, artist, expected, note) in cases {
        var result: [LyricsProvider.Line]?
        let deadline = Date().addingTimeInterval(25)
        while Date() < deadline {
            result = LyricsProvider.shared.lines(title: title, artist: artist)
            if result != nil { break }
            RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        }
        let count = result?.count ?? -1
        check("live: \(title) / \(artist) → \(expected ? "lyrics" : "none") (\(note))",
              expected ? count > 0 : count == 0, "lines \(count)")
        if let first = result?.first(where: { $0.time > 10 }) { print("      e.g. \(first.text)") }
    }
}

offline()
if CommandLine.arguments.contains("--live") { live() }
print(failures == 0 ? "lyrics test: all passed" : "lyrics test: \(failures) failed")
exit(failures == 0 ? 0 : 1)
