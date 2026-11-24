import AppKit

/// Checks of the update checker (`OmniHub --update-selftest [dir]`; with a
/// directory, a picture of the card showing the Update icon is saved there).
///
/// Version comparison and feed parsing run on fixed input; then the real
/// feed is read, the newest DMG downloaded, its checksum checked and the
/// app inside copied out and verified exactly as before an install — only
/// the swap itself is left out. The downloaded DMG and the copy are
/// deleted afterwards.
enum UpdateSelfTest {
    private static var failures = 0

    private static func check(_ name: String, _ ok: Bool, _ detail: String = "") {
        if !ok { failures += 1 }
        print("\(ok ? "PASS" : "FAIL")  \(name)\(ok || detail.isEmpty ? "" : "  — \(detail)")")
    }

    static func run() {
        comparison()
        parsing()
        buttons()
        live()
        print(failures == 0 ? "RESULT: all passed" : "RESULT: \(failures) failed")
        exit(failures == 0 ? 0 : 1)
    }

    private static func comparison() {
        let cases: [(String, String, ComparisonResult)] = [
            ("1.8.3", "1.8.1", .orderedDescending), ("1.8.1", "1.8.3", .orderedAscending),
            ("1.10", "1.9", .orderedDescending), ("1.8", "1.8.0", .orderedSame), ("v2.0", "1.99.9", .orderedDescending)]
        let wrong = cases.filter { UpdateChecker.compare($0.0, $0.1) != $0.2 }
        check("versions compare number by number", wrong.isEmpty, "\(wrong)")
    }

    private static func parsing() {
        let sum = String(repeating: "ab", count: 32)
        let content = """
        <p>macOS 14</p><h2>What's new</h2><ul>\n<li><p><strong>New thing.</strong> It works &amp; is fast.</p></li>\
        <li><p><strong>新东西</strong>：好用。</p></li></ul><ol><li>Install step</li></ol>\
        <p>SHA-256 (<code>OmniHub-1.9.0.dmg</code>): <code>\(sum)</code></p>
        """
        let escaped = content.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
        let feed = """
        <?xml version="1.0" encoding="UTF-8"?>
        <feed xmlns="http://www.w3.org/2005/Atom">
          <entry><id>tag:github.com,2008:Repository/1/v1.9.0</id><title>OmniHub 1.9.0</title>
            <content type="html">\(escaped)</content></entry>
          <entry><id>tag:github.com,2008:Repository/1/v1.8.3</id><content type="html"></content></entry>
        </feed>
        """
        do {
            let release = try UpdateChecker.parse(feed: Data(feed.utf8))
            check("the newest entry is taken", release?.version == "1.9.0", "\(String(describing: release?.version))")
            check("the DMG address follows from the tag",
                  release?.dmg.absoluteString == "https://github.com/qhr992/OmniHub/releases/download/v1.9.0/OmniHub-1.9.0.dmg",
                  release?.dmg.absoluteString ?? "-")
            check("the checksum is read from the notes", release?.sha256 == sum, release?.sha256 ?? "-")
            check("notes: the English points of What's new, as plain text",
                  release?.notes == ["New thing. It works & is fast."], "\(release?.notes ?? [])")
        } catch {
            check("the feed parses", false, "\(error)")
        }
    }

    /// The Update buttons appear only while something newer is out.
    private static func buttons() {
        FloatingDockPanel.headless = true
        let position = (Prefs.double("dock.posX", 0.5), Prefs.double("dock.posY", 0))
        defer {
            Prefs.set("dock.posX", position.0)
            Prefs.set("dock.posY", position.1)
        }
        _ = FloatingDockPanel.debugCardSize(page: .home, x: 0.5, y: 0)
        let checker = UpdateChecker.shared
        checker.debugFound(nil)
        check("nothing newer: no Update button", checker.actionTitle == nil
              && !FloatingDockPanel.debugNav.trailing.contains { $0.hasPrefix("Update") }, "\(FloatingDockPanel.debugNav)")
        let release = UpdateChecker.Release(version: "9.9.9", page: URL(string: "https://example.invalid")!,
                                            dmg: URL(string: "https://example.invalid/x.dmg")!, sha256: nil, notes: [])
        checker.debugFound(release)
        check("newer found: the card shows Update to 9.9.9",
              FloatingDockPanel.debugNav.trailing.first == "Update to 9.9.9", "\(FloatingDockPanel.debugNav)")
        if let index = CommandLine.arguments.firstIndex(of: "--update-selftest"),
           index + 1 < CommandLine.arguments.count {
            _ = FloatingDockPanel.snapshot(to: URL(fileURLWithPath: CommandLine.arguments[index + 1])
                .appendingPathComponent("update-button.png"))
        }
        checker.debugFound(nil)
        check("and hides it again", FloatingDockPanel.debugNav.trailing.first != "Update to 9.9.9")
    }

    /// The real feed, download and checks.
    private static func live() {
        var fetched: Result<UpdateChecker.Release?, Error>?
        UpdateChecker.shared.fetchLatest { fetched = $0 }
        wait { fetched != nil }
        guard case .success(let found)? = fetched, let release = found else {
            check("the release feed is read", false, "\(String(describing: fetched))")
            return
        }
        check("the release feed is read: newest is \(release.version), checksum \(release.sha256 == nil ? "missing" : "published")",
              release.sha256 != nil)
        check("the notes have points", !release.notes.isEmpty, "\(release.notes)")

        var downloaded: Result<URL, Error>?
        UpdateChecker.shared.download(release) { downloaded = $0 }
        wait(seconds: 180) { downloaded != nil }
        guard case .success(let dmg)? = downloaded else {
            check("the DMG downloads and matches its checksum", false, "\(String(describing: downloaded))")
            return
        }
        check("the DMG downloads and matches its checksum", true)
        do {
            let app = try UpdateChecker.stage(dmg: dmg, release: release)
            check("the app in it is OmniHub \(release.version), validly signed with the same certificate", true)
            try? FileManager.default.removeItem(at: app.deletingLastPathComponent())
        } catch {
            check("the app in it passes the install checks", false, error.localizedDescription)
        }
        try? FileManager.default.removeItem(at: dmg)

        let tampered = UpdateChecker.Release(version: release.version, page: release.page, dmg: release.dmg,
                                             sha256: String(repeating: "0", count: 64), notes: [])
        var refused: Result<URL, Error>?
        UpdateChecker.shared.download(tampered) { refused = $0 }
        wait(seconds: 180) { refused != nil }
        if case .failure? = refused { check("a download that does not match the checksum is refused", true) }
        else { check("a download that does not match the checksum is refused", false, "\(String(describing: refused))") }
    }

    private static func wait(seconds: TimeInterval = 30, until done: () -> Bool) {
        let deadline = Date().addingTimeInterval(seconds)
        while !done(), Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.1)) }
    }
}
