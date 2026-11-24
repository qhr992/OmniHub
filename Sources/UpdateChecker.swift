import AppKit

extension Notification.Name {
    static let updateStatusChanged = Notification.Name("omnihub.updateStatusChanged")
}

/// Looks for a newer OmniHub on GitHub and offers to install it.
///
/// The releases are read from the repository's Atom feed rather than the
/// REST API: the API allows 60 requests an hour per IP address without a
/// token, which a shared office address uses up, while the feed has no such
/// limit. Each entry carries the tag (`v1.8.3`), the notes, and — written
/// by the release — the SHA-256 of the DMG, whose name and address follow
/// from the tag.
///
/// Installing: the DMG is downloaded, its SHA-256 checked, the app copied
/// out of it and checked (bundle id, version, a valid signature by the same
/// certificate as the running copy). On restart a small shell waits for
/// this process to end, swaps the app in place and opens it. If any of that
/// is not possible (the app's folder is not writable, a check fails), the
/// DMG is opened instead so it can be dragged over by hand.
final class UpdateChecker: NSObject {
    static let shared = UpdateChecker()

    static let autoKey = "update.auto"
    private static let feed = URL(string: "https://github.com/qhr992/OmniHub/releases.atom")!
    private static let downloads = "https://github.com/qhr992/OmniHub/releases/download"
    private static let checkEvery: TimeInterval = 6 * 3600
    private static let retryEvery: TimeInterval = 3600
    private static let firstCheckDelay: TimeInterval = 20
    private static let requestTimeout: TimeInterval = 20

    struct Release: Equatable {
        let version: String
        let page: URL
        let dmg: URL
        let sha256: String?
        /// What's new, in the interface language where the notes have it.
        let notes: [String]
    }

    enum Status: Equatable {
        case idle, checking, upToDate, failed(String)
        case available(Release)
        case downloading(Release, Double?)
        case ready(Release)
    }

    private(set) var status: Status = .idle {
        didSet { NotificationCenter.default.post(name: .updateStatusChanged, object: nil) }
    }
    private var timer: Timer?
    private var progressWatch: NSKeyValueObservation?
    private var staged: URL?
    /// When the feed last answered (not persisted: each launch checks).
    private var lastAnswer: Date?
    /// Versions already offered by this run, so the prompt comes once.
    private var offered: Set<String> = []

    /// The version this copy reports; `debug.updateAsVersion` pretends to
    /// be an older one (test hook).
    static var currentVersion: String {
        UserDefaults.standard.string(forKey: "debug.updateAsVersion")
            ?? (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0")
    }

    /// Automatic checks: shortly after every launch, then every six hours
    /// (a failed check is retried within the hour). Nothing to click: a
    /// newer version is offered by itself, and stays one click away on the
    /// Update buttons (card, menu bar menu, Settings) after "Later".
    func start() {
        // Left by builds up to 1.8.4, which checked once a day.
        for key in ["update.lastCheck", "update.skipped"] { UserDefaults.standard.removeObject(forKey: key) }
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.firstCheckDelay) { [weak self] in self?.checkIfDue() }
        let timer = Timer(timeInterval: Self.retryEvery, repeats: true) { [weak self] _ in self?.checkIfDue() }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func checkIfDue() {
        guard Prefs.bool(Self.autoKey, true) else { return }
        if let lastAnswer, Date().timeIntervalSince(lastAnswer) < Self.checkEvery { return }
        check(userInitiated: false)
    }

    /// Asks the feed. A check started by hand always reports back; an
    /// automatic one speaks up only for a newer version not yet offered.
    func check(userInitiated: Bool) {
        switch status {
        case .checking, .downloading: return
        case .ready(let release):
            if userInitiated { offerRestart(release) }
            return
        default: break
        }
        status = .checking
        fetchLatest { [weak self] result in
            guard let self else { return }
            // Only an answer counts as a check: after a failure (github.com
            // is often out of reach) the hourly timer tries again.
            if case .success = result { self.lastAnswer = Date() }
            switch result {
            case .failure(let error):
                self.status = .failed(error.localizedDescription)
                if userInitiated { self.alert(L("Could not check for updates"), error.localizedDescription) }
            case .success(let release):
                guard let release, Self.compare(release.version, Self.currentVersion) == .orderedDescending else {
                    self.status = .upToDate
                    if userInitiated {
                        self.alert(L("OmniHub is up to date"), L("You have the latest version, %@.", Self.currentVersion))
                    }
                    return
                }
                self.status = .available(release)
                if userInitiated || !self.offered.contains(release.version) {
                    self.offered.insert(release.version)
                    self.offer(release)
                }
            }
        }
    }

    // MARK: Feed

    func fetchLatest(_ completion: @escaping (Result<Release?, Error>) -> Void) {
        var request = URLRequest(url: Self.feed, timeoutInterval: Self.requestTimeout)
        request.setValue("OmniHub/\(Self.currentVersion)", forHTTPHeaderField: "User-Agent")
        URLSession.shared.dataTask(with: request) { data, response, error in
            let result: Result<Release?, Error>
            if let error {
                result = .failure(error)
            } else if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                result = .failure(Self.error(L("The update server answered with HTTP %ld.", http.statusCode)))
            } else {
                result = Result { try Self.parse(feed: data ?? Data()) }
            }
            DispatchQueue.main.async { completion(result) }
        }.resume()
    }

    /// The newest release in the feed (entries are newest first).
    static func parse(feed data: Data) throws -> Release? {
        let document = try XMLDocument(data: data)
        let entries = try document.nodes(forXPath: "//*[local-name()='entry']")
        for entry in entries {
            func value(_ name: String) -> String? {
                (try? entry.nodes(forXPath: "*[local-name()='\(name)']"))?.first?.stringValue
            }
            guard let id = value("id"), let tag = id.split(separator: "/").last,
                  tag.hasPrefix("v"), case let version = String(tag.dropFirst()),
                  version.range(of: #"^\d+(\.\d+)*$"#, options: .regularExpression) != nil,
                  let page = URL(string: "https://github.com/qhr992/OmniHub/releases/tag/\(tag)"),
                  let dmg = URL(string: "\(downloads)/\(tag)/OmniHub-\(version).dmg") else { continue }
            let html = value("content") ?? ""
            return Release(version: version, page: page, dmg: dmg, sha256: sha256(in: html), notes: notes(in: html))
        }
        return nil
    }

    /// The first list of the notes ("What's new"), one line per point, in
    /// Chinese or English as the interface is (the notes carry both).
    static func notes(in html: String) -> [String] {
        guard let list = html.range(of: #"(?s)<ul>.*?</ul>"#, options: .regularExpression) else { return [] }
        let items = matches(#"<li>(.*?)</li>"#, in: String(html[list])).map(plainText)
        let chinese = AppLanguage.current == .chinese
        let picked = items.filter { item in
            (item.range(of: #"\p{Han}"#, options: .regularExpression) != nil) == chinese
        }
        return picked.isEmpty ? items : picked
    }

    static func sha256(in html: String) -> String? {
        guard let start = html.range(of: "SHA-256") else { return nil }
        return matches(#"\b([0-9a-f]{64})\b"#, in: String(html[start.upperBound...])).first
    }

    private static func matches(_ pattern: String, in text: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]) else { return [] }
        let range = NSRange(text.startIndex..., in: text)
        return regex.matches(in: text, range: range).compactMap { match in
            Range(match.range(at: 1), in: text).map { String(text[$0]) }
        }
    }

    private static func plainText(_ html: String) -> String {
        var text = html.replacingOccurrences(of: #"<[^>]+>"#, with: "", options: .regularExpression)
        for (entity, character) in [("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""), ("&#39;", "'"), ("&amp;", "&")] {
            text = text.replacingOccurrences(of: entity, with: character)
        }
        return text.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
    }

    /// Compares dotted versions number by number ("1.10" > "1.9").
    static func compare(_ a: String, _ b: String) -> ComparisonResult {
        func parts(_ version: String) -> [Int] {
            version.trimmingCharacters(in: CharacterSet(charactersIn: "vV")).split(separator: ".").map { Int($0) ?? 0 }
        }
        let (x, y) = (parts(a), parts(b))
        for index in 0..<max(x.count, y.count) {
            let (left, right) = (index < x.count ? x[index] : 0, index < y.count ? y[index] : 0)
            if left != right { return left < right ? .orderedAscending : .orderedDescending }
        }
        return .orderedSame
    }

    static func error(_ text: String) -> NSError {
        NSError(domain: "OmniHub.update", code: 1, userInfo: [NSLocalizedDescriptionKey: text])
    }

    // MARK: Asking

    private func offer(_ release: Release) {
        let alert = NSAlert()
        alert.messageText = L("OmniHub %@ is available", release.version)
        let notes = release.notes.prefix(6).map { "• " + $0 }.joined(separator: "\n")
        alert.informativeText = L("You have %@.", Self.currentVersion) + (notes.isEmpty ? "" : "\n\n" + notes)
        alert.addButton(withTitle: L("Download and Install"))
        alert.addButton(withTitle: L("Later"))
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn { download(release) }
    }

    private func offerRestart(_ release: Release) {
        let alert = NSAlert()
        alert.messageText = L("OmniHub %@ is ready to install", release.version)
        let terminalOpen = (FloatingDockPanel.terminalIfCreated?.openSessionCount ?? 0) > 0
        alert.informativeText = L("OmniHub restarts to finish.") + (terminalOpen ? " " + L("Open terminal tabs will be closed.") : "")
        alert.addButton(withTitle: L("Restart Now"))
        alert.addButton(withTitle: L("Later"))
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn { installAndRestart() }
    }

    private func alert(_ title: String, _ text: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = text
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    // MARK: Download and install

    func download(_ release: Release, completion: ((Result<URL, Error>) -> Void)? = nil) {
        status = .downloading(release, nil)
        Toast.show(L("Downloading OmniHub %@…", release.version), duration: 2)
        let task = URLSession.shared.downloadTask(with: release.dmg) { [weak self] file, response, error in
            let result: Result<URL, Error> = Result {
                if let error { throw error }
                if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                    throw Self.error(L("The update server answered with HTTP %ld.", http.statusCode))
                }
                guard let file else { throw Self.error(L("The download is empty.")) }
                return try Self.prepare(downloaded: file, release: release)
            }
            DispatchQueue.main.async { self?.downloaded(release, result, completion: completion) }
        }
        progressWatch = task.progress.observe(\.fractionCompleted) { [weak self] progress, _ in
            DispatchQueue.main.async {
                // Whole percents only: every change redraws Settings.
                guard let self, case .downloading(_, let shown) = self.status,
                      shown.map({ Int($0 * 100) }) != Int(progress.fractionCompleted * 100) else { return }
                self.status = .downloading(release, progress.fractionCompleted)
            }
        }
        task.resume()
    }

    private func downloaded(_ release: Release, _ result: Result<URL, Error>, completion: ((Result<URL, Error>) -> Void)?) {
        progressWatch = nil
        if let completion { completion(result) } else { finish(release, result) }
    }

    private func finish(_ release: Release, _ result: Result<URL, Error>) {
        switch result {
        case .success(let dmg):
            do {
                staged = try Self.stage(dmg: dmg, release: release)
                status = .ready(release)
                offerRestart(release)
            } catch {
                // Cannot swap it in ourselves: hand over the DMG.
                status = .available(release)
                NSWorkspace.shared.open(dmg)
                alert(L("Install OmniHub %@ by hand", release.version),
                      error.localizedDescription + "\n\n" + L("In the window that opened, drag OmniHub onto Applications, then reopen it."))
            }
        case .failure(let error):
            // Still on offer: the Update buttons stay for another try.
            status = .available(release)
            let alert = NSAlert()
            alert.messageText = L("Could not download the update")
            alert.informativeText = error.localizedDescription
            alert.addButton(withTitle: L("Open Release Page"))
            alert.addButton(withTitle: L("Cancel"))
            NSApp.activate(ignoringOtherApps: true)
            if alert.runModal() == .alertFirstButtonReturn { NSWorkspace.shared.open(release.page) }
        }
    }

    /// Moves the download to ~/Downloads and checks its SHA-256.
    static func prepare(downloaded file: URL, release: Release) throws -> URL {
        let folder = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let target = folder.appendingPathComponent("OmniHub-\(release.version).dmg")
        try? FileManager.default.removeItem(at: target)
        try FileManager.default.moveItem(at: file, to: target)
        if let expected = release.sha256 {
            let actual = try run("/usr/bin/shasum", ["-a", "256", target.path]).split(separator: " ").first.map(String.init)
            guard actual == expected else {
                try? FileManager.default.removeItem(at: target)
                throw error(L("The download does not match its published checksum, so it was deleted."))
            }
        }
        return target
    }

    /// Copies the app out of the DMG and checks it can replace this copy.
    static func stage(dmg: URL, release: Release) throws -> URL {
        let current = Bundle.main.bundleURL
        guard FileManager.default.isWritableFile(atPath: current.deletingLastPathComponent().path),
              FileManager.default.isWritableFile(atPath: current.path) else {
            throw error(L("OmniHub cannot write to %@.", current.deletingLastPathComponent().path))
        }
        let work = FileManager.default.temporaryDirectory.appendingPathComponent("omnihub-update-\(release.version)")
        let mount = work.appendingPathComponent("mount")
        let app = work.appendingPathComponent("OmniHub.app")
        try? FileManager.default.removeItem(at: work)
        try FileManager.default.createDirectory(at: mount, withIntermediateDirectories: true)
        _ = try run("/usr/bin/hdiutil", ["attach", "-nobrowse", "-readonly", "-noverify", "-mountpoint", mount.path, dmg.path])
        defer { _ = try? run("/usr/bin/hdiutil", ["detach", "-quiet", mount.path]) }
        _ = try run("/usr/bin/ditto", [mount.appendingPathComponent("OmniHub.app").path, app.path])
        try verify(app: app, version: release.version)
        return app
    }

    /// Same bundle id, the promised version, a valid signature, and the
    /// same signing certificate as the running copy.
    static func verify(app: URL, version: String) throws {
        let info = Bundle(url: app)?.infoDictionary ?? [:]
        guard info["CFBundleIdentifier"] as? String == Bundle.main.bundleIdentifier,
              info["CFBundleShortVersionString"] as? String == version else {
            throw error(L("The downloaded app is not OmniHub %@.", version))
        }
        _ = try run("/usr/bin/codesign", ["--verify", "--deep", "--strict", app.path])
        guard let theirs = signingCertificate(of: app), theirs == signingCertificate(of: Bundle.main.bundleURL) else {
            throw error(L("The downloaded app is not signed like this copy of OmniHub."))
        }
    }

    private static func signingCertificate(of app: URL) -> Data? {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(app as CFURL, [], &code) == errSecSuccess, let code else { return nil }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let certificates = (info as? [String: Any])?[kSecCodeInfoCertificates as String] as? [SecCertificate],
              let leaf = certificates.first else { return nil }
        return SecCertificateCopyData(leaf) as Data
    }

    /// Restart: a shell waits for this process to end, swaps the staged
    /// app in (putting the old one back if that fails) and opens it.
    private func installAndRestart() {
        guard let staged else { return }
        let target = Bundle.main.bundlePath
        let script = """
        while kill -0 "$3" 2>/dev/null; do sleep 0.2; done
        rm -rf "$2.old"
        if mv "$2" "$2.old" && /usr/bin/ditto "$1" "$2"; then rm -rf "$2.old" "$(dirname "$1")"
        else rm -rf "$2"; mv "$2.old" "$2"; fi
        /usr/bin/open "$2"
        """
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = ["-c", script, "omnihub-update", staged.path, target, String(ProcessInfo.processInfo.processIdentifier)]
        do {
            try task.run()
        } catch {
            alert(L("Could not restart: %@", error.localizedDescription), "")
            return
        }
        NSApp.terminate(nil)
    }

    /// Runs a tool and returns its output; a non-zero exit is an error.
    @discardableResult
    static func run(_ tool: String, _ arguments: [String]) throws -> String {
        let task = Process()
        let pipe = Pipe()
        task.executableURL = URL(fileURLWithPath: tool)
        task.arguments = arguments
        task.standardOutput = pipe
        task.standardError = pipe
        try task.run()
        let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        task.waitUntilExit()
        guard task.terminationStatus == 0 else {
            throw error("\((tool as NSString).lastPathComponent): \(output.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
        return output
    }

    /// One line for Settings.
    var statusText: String {
        switch status {
        case .idle: return L("Current version %@", Self.currentVersion)
        case .checking: return L("Checking…")
        case .upToDate: return L("Up to date (%@)", Self.currentVersion)
        case .failed(let reason): return L("Check failed: %@", reason)
        case .available(let release): return L("Version %@ is available", release.version)
        case .downloading(let release, let fraction):
            return fraction.map { L("Downloading %@… %ld%%", release.version, Int($0 * 100)) }
                ?? L("Downloading %@…", release.version)
        case .ready(let release): return L("Version %@ is ready: restart to install", release.version)
        }
    }

    /// The Update buttons: install what was found (the click is the
    /// consent, so no second question), restart into a downloaded one, or
    /// — with nothing found yet — check and report.
    func updateNow() {
        switch status {
        case .available(let release): download(release)
        case .ready(let release): offerRestart(release)
        case .downloading: break
        default: check(userInitiated: true)
        }
    }

    /// The Update buttons' title; nil while there is nothing newer.
    var actionTitle: String? {
        switch status {
        case .available(let release): return L("Update to %@", release.version)
        case .downloading(let release, let fraction):
            return fraction.map { L("Downloading %@… %ld%%", release.version, Int($0 * 100)) }
                ?? L("Downloading %@…", release.version)
        case .ready: return L("Restart to Update")
        default: return nil
        }
    }

    /// Test hook: pretend a check found `release` (or nothing).
    func debugFound(_ release: Release?) { status = release.map { .available($0) } ?? .upToDate }

    /// False while downloading (the button then only shows progress).
    var canAct: Bool {
        if case .downloading = status { return false }
        return true
    }
}
