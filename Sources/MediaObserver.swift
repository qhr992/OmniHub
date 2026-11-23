import AppKit

/// Now-playing detection through the private MediaRemote framework.
///
/// Since macOS 15.4 `mediaremoted` only answers Apple-signed processes, so a
/// direct call from this app returns nothing. The primary path therefore runs
/// `/usr/bin/perl` with a small bridge dylib (see Sources/MediaBridge) that
/// streams JSON lines; the direct in-process call is kept as a fallback for
/// older systems. No Automation/AppleScript permission is involved.
final class MediaObserver {
    static let shared = MediaObserver()

    struct NowPlaying {
        var title: String = ""
        var artist: String = ""
        var album: String = ""
        var isPlaying: Bool = false
        var bundleID: String?
        var appName: String = ""
        var artwork: NSImage?
        var duration: Double = 0
        /// MediaRemote modes: shuffle 1 off / 2 albums / 3 tracks; repeat
        /// 1 off / 2 one / 3 all; 0 = the player does not say.
        var shuffleMode = 0
        var repeatMode = 0
        /// nil when the player does not publish a like state.
        var liked: Bool?
        /// PID of the app that owns the item (menus live there).
        var pid: pid_t = 0
        /// MediaRemote commands the player accepts; nil = not reported.
        var commands: Set<Int>?
        /// Shown while another app holds the system's Now Playing (music
        /// before video, or it plays and that one does not). A browser or
        /// video player takes no commands from other apps then.
        var isFollowed = false
        /// A music app (not a browser or video player): shown first when
        /// music and a video play together, and takes commands addressed to
        /// it even without holding Now Playing.
        var isMusic = false
        /// Who holds the system's Now Playing (system commands reach only
        /// that app), and the other players playing at the same time.
        var nowPlayingPID: pid_t = 0
        var othersPlaying: [pid_t] = []
        /// Playback position `elapsed` as of `anchor`; -1 when unknown.
        var elapsed: Double = -1
        var anchor = Date()

        var hasContent: Bool { !title.isEmpty || !artist.isEmpty }

        /// Extrapolated playback position in seconds, nil when unknown.
        func position(at date: Date = Date()) -> Double? {
            guard elapsed >= 0 else { return nil }
            var value = elapsed
            if isPlaying { value += date.timeIntervalSince(anchor) }
            if duration > 0 { value = min(value, duration) }
            return max(0, value)
        }
    }

    private(set) var current: NowPlaying?
    /// "bridge", "direct" or "none" (diagnostics).
    private(set) var source = "none"

    private var lastSignature = ""

    // Bridge
    private var bridge: Process?
    private var bridgeInput: FileHandle?
    private var lineBuffer = Data()
    private var restartCount = 0
    private var artworkKey = ""
    private var artworkImage: NSImage?
    private var artworkURL: URL { Store.url("nowplaying-artwork") }

    // Direct fallback
    private var timer: Timer?
    private var handle: UnsafeMutableRawPointer?
    private typealias GetInfoFn = @convention(c) (DispatchQueue, @escaping @convention(block) (NSDictionary?) -> Void) -> Void
    private typealias GetPIDFn = @convention(c) (DispatchQueue, @escaping @convention(block) (Int32) -> Void) -> Void
    private typealias SendCommandFn = @convention(c) (Int32, CFDictionary?) -> Bool
    private lazy var getInfo: GetInfoFn? = symbol("MRMediaRemoteGetNowPlayingInfo", as: GetInfoFn.self)
    private lazy var getPID: GetPIDFn? = symbol("MRMediaRemoteGetNowPlayingApplicationPID", as: GetPIDFn.self)
    private lazy var sendCommand: SendCommandFn? = symbol("MRMediaRemoteSendCommand", as: SendCommandFn.self)
    private typealias SetElapsedFn = @convention(c) (Double) -> Void
    private lazy var setElapsed: SetElapsedFn? = symbol("MRMediaRemoteSetElapsedTime", as: SetElapsedFn.self)
    private let queue = DispatchQueue(label: "omnihub.mediaremote", qos: .utility)

    var apiAvailable: Bool { source != "none" }

    func start() {
        guard bridge == nil, timer == nil else { return }
        if !startBridge() { startDirect() }
    }

    func stop() {
        bridge?.terminationHandler = nil
        bridge?.terminate()
        bridge = nil
    }

    // MARK: Bridge (perl + MediaBridge.dylib)

    private func startBridge() -> Bool {
        guard let resources = Bundle.main.resourceURL else { return false }
        let script = resources.appendingPathComponent("bridge.pl")
        let dylib = resources.appendingPathComponent("MediaBridge.dylib")
        let perl = "/usr/bin/perl"
        let fm = FileManager.default
        guard fm.fileExists(atPath: script.path), fm.fileExists(atPath: dylib.path),
              fm.isExecutableFile(atPath: perl) else { return false }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: perl)
        process.arguments = [script.path, dylib.path]
        var environment = ProcessInfo.processInfo.environment
        environment["OMNIHUB_ARTWORK_PATH"] = artworkURL.path
        process.environment = environment

        let output = Pipe()
        let input = Pipe()
        process.standardOutput = output
        process.standardInput = input
        process.standardError = FileHandle.nullDevice

        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            DispatchQueue.main.async { self?.consume(data) }
        }
        process.terminationHandler = { [weak self] _ in
            output.fileHandleForReading.readabilityHandler = nil
            DispatchQueue.main.async { self?.bridgeDidExit() }
        }

        do { try process.run() } catch { return false }
        bridge = process
        bridgeInput = input.fileHandleForWriting
        source = "bridge"
        return true
    }

    private func bridgeDidExit() {
        bridge = nil
        bridgeInput = nil
        restartCount += 1
        if restartCount <= 5 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
                guard let self, self.bridge == nil, self.timer == nil else { return }
                if !self.startBridge() { self.startDirect() }
            }
        } else {
            startDirect()
        }
    }

    private func consume(_ data: Data) {
        lineBuffer.append(data)
        while let newline = lineBuffer.firstIndex(of: 0x0A) {
            let line = lineBuffer.subdata(in: lineBuffer.startIndex..<newline)
            lineBuffer.removeSubrange(lineBuffer.startIndex...newline)
            guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { continue }
            apply(object)
        }
    }

    private func apply(_ object: [String: Any]) {
        var next = NowPlaying()
        next.title = object["title"] as? String ?? ""
        next.artist = object["artist"] as? String ?? ""
        next.album = object["album"] as? String ?? ""
        next.isPlaying = (object["playing"] as? NSNumber)?.boolValue ?? false
        next.duration = (object["duration"] as? NSNumber)?.doubleValue ?? 0
        next.elapsed = (object["elapsed"] as? NSNumber)?.doubleValue ?? -1
        if let stamp = (object["timestamp"] as? NSNumber)?.doubleValue, stamp > 0 {
            next.anchor = Date(timeIntervalSince1970: stamp)
        }
        next.shuffleMode = (object["shuffle"] as? NSNumber)?.intValue ?? 0
        next.repeatMode = (object["repeat"] as? NSNumber)?.intValue ?? 0
        let liked = (object["liked"] as? NSNumber)?.intValue ?? -1
        next.liked = liked < 0 ? nil : liked == 1
        next.commands = (object["commands"] as? [NSNumber]).map { Set($0.map(\.intValue)) }
        next.isFollowed = (object["followed"] as? NSNumber)?.boolValue ?? false
        next.isMusic = (object["music"] as? NSNumber)?.boolValue ?? false
        next.nowPlayingPID = (object["nowPlaying"] as? NSNumber)?.int32Value ?? 0
        next.othersPlaying = (object["othersPlaying"] as? [NSNumber])?.map(\.int32Value) ?? []

        let key = object["artwork"] as? String ?? ""
        if key.isEmpty {
            artworkKey = ""
            artworkImage = nil
        } else if key != artworkKey {
            artworkKey = key
            artworkImage = (try? Data(contentsOf: artworkURL)).flatMap { NSImage(data: $0) }
        }
        next.artwork = artworkImage

        if let pid = (object["pid"] as? NSNumber)?.int32Value, pid > 0,
           let app = Self.owningApp(of: pid) {
            next.bundleID = app.bundleIdentifier
            next.appName = app.localizedName ?? ""
            next.pid = app.processIdentifier
        }
        fillFromMenu(&next)
        commit(next, extraSignature: key)
    }

    /// The now-playing PID is often a helper (browser renderer, XPC service);
    /// walk up to the first regular app so a click lands on a real window.
    private static func owningApp(of pid: pid_t) -> NSRunningApplication? {
        var current = pid
        var fallback: NSRunningApplication?
        for _ in 0..<6 {
            if let app = NSRunningApplication(processIdentifier: current) {
                if app.activationPolicy == .regular { return app }
                if fallback == nil { fallback = app }
            }
            guard let parent = parentPID(of: current), parent > 1 else { break }
            current = parent
        }
        return fallback
    }

    private static func parentPID(of pid: pid_t) -> pid_t? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0 else { return nil }
        return info.kp_eproc.e_ppid
    }

    // MARK: Direct fallback

    private func startDirect() {
        guard timer == nil else { return }
        loadFramework()
        guard getInfo != nil else { source = "none"; return }
        source = "direct"
        refreshDirect()
        let timer = Timer(timeInterval: 2.0, repeats: true) { [weak self] _ in self?.refreshDirect() }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func loadFramework() {
        guard handle == nil else { return }
        handle = dlopen("/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote", RTLD_LAZY)
    }

    private func symbol<T>(_ name: String, as type: T.Type) -> T? {
        loadFramework()
        guard let handle, let sym = dlsym(handle, name) else { return nil }
        return unsafeBitCast(sym, to: T.self)
    }

    private func refreshDirect() {
        guard let getInfo else { return }
        getInfo(queue) { [weak self] info in
            guard let self else { return }
            var next = NowPlaying()
            if let info {
                next.title = (info["kMRMediaRemoteNowPlayingInfoTitle"] as? String) ?? ""
                next.artist = (info["kMRMediaRemoteNowPlayingInfoArtist"] as? String) ?? ""
                next.album = (info["kMRMediaRemoteNowPlayingInfoAlbum"] as? String) ?? ""
                next.isPlaying = (info["kMRMediaRemoteNowPlayingInfoPlaybackRate"] as? Double ?? 0) > 0
                next.shuffleMode = info["kMRMediaRemoteNowPlayingInfoShuffleMode"] as? Int ?? 0
                next.repeatMode = info["kMRMediaRemoteNowPlayingInfoRepeatMode"] as? Int ?? 0
                next.liked = info["kMRMediaRemoteNowPlayingInfoIsLiked"] as? Bool
                if let data = info["kMRMediaRemoteNowPlayingInfoArtworkData"] as? Data {
                    next.artwork = NSImage(data: data)
                }
            }
            guard let getPID = self.getPID else {
                DispatchQueue.main.async { self.commit(next, extraSignature: "") }
                return
            }
            getPID(self.queue) { pid in
                DispatchQueue.main.async {
                    if pid > 0, let app = Self.owningApp(of: pid) {
                        next.bundleID = app.bundleIdentifier
                        next.appName = app.localizedName ?? ""
                    }
                    self.commit(next, extraSignature: next.artwork == nil ? "" : "art")
                }
            }
        }
    }

    // MARK: State

    /// How long an empty update may last before the player is taken away.
    /// Players republish their state when the play mode changes and
    /// sometimes send an empty one in between.
    static let emptyGrace: TimeInterval = 3
    private var emptySince: Date?

    // MARK: Held item

    /// True while the player has cleared what it publishes but is still
    /// running: the last song stays on screen. NetEase does this when shuffle
    /// is switched and stays silent until the next song, while it keeps playing.
    private(set) var isHolding = false
    private var holdTimer: Timer?
    static let holdCheckInterval: TimeInterval = 2

    private func startHolding() {
        isHolding = true
        refreshHeld()
        guard holdTimer == nil else { return }
        let timer = Timer(timeInterval: Self.holdCheckInterval, repeats: true) { [weak self] _ in self?.refreshHeld() }
        RunLoop.main.add(timer, forMode: .common)
        holdTimer = timer
    }

    private func stopHolding() {
        isHolding = false
        holdTimer?.invalidate()
        holdTimer = nil
    }

    /// Play / pause of a held item follows the player's audio output.
    private func refreshHeld() {
        guard isHolding, var item = current else { stopHolding(); return }
        guard PlayerActivity.isRunning(item.pid) else {
            stopHolding()
            current = nil
            lastSignature = ""
            NotificationCenter.default.post(name: .mediaChanged, object: nil)
            return
        }
        let playing = PlayerActivity.isProducingAudio(item.pid)
        guard playing != item.isPlaying else { return }
        let now = Date()
        if let position = item.position(at: now) { item.elapsed = position }
        item.anchor = now
        item.isPlaying = playing
        current = item
        NotificationCenter.default.post(name: .mediaChanged, object: nil)
    }

    private func commit(_ next: NowPlaying, extraSignature: String) {
        if !next.hasContent, let shown = current, shown.pid > 0, next.pid == shown.pid,
           PlayerActivity.isRunning(shown.pid) {
            emptySince = nil
            startHolding()
            return
        }
        // Nothing shown yet (e.g. OmniHub started after the player cleared its
        // info) but the player is audibly playing: show it under its own name
        // so play / pause / next still work.
        if !next.hasContent, current == nil, next.pid > 0, !next.appName.isEmpty,
           PlayerActivity.isProducingAudio(next.pid) {
            var placeholder = next
            placeholder.title = next.appName
            placeholder.isPlaying = true
            placeholder.elapsed = -1
            current = placeholder
            lastSignature = ""
            emptySince = nil
            NotificationCenter.default.post(name: .mediaChanged, object: nil)
            startHolding()
            return
        }
        stopHolding()
        if !next.hasContent, current != nil {
            // Keep showing what was playing for a moment; hide it only if
            // the player stays silent.
            let since = emptySince ?? Date()
            emptySince = since
            if Date().timeIntervalSince(since) < Self.emptyGrace {
                DispatchQueue.main.asyncAfter(deadline: .now() + Self.emptyGrace + 0.1) { [weak self] in
                    guard let self, let since = self.emptySince,
                          Date().timeIntervalSince(since) >= Self.emptyGrace else { return }
                    self.emptySince = nil
                    self.current = nil
                    self.lastSignature = ""
                    NotificationCenter.default.post(name: .mediaChanged, object: nil)
                }
                return
            }
        }
        emptySince = nil
        let signature = "\(next.title)|\(next.artist)|\(next.isPlaying)|\(next.appName)|\(extraSignature)"
            + "|\(next.shuffleMode)|\(next.repeatMode)|\(next.liked.map { "\($0)" } ?? "-")"
            + "|\(next.othersPlaying)|\(next.isFollowed)"
        current = next.hasContent ? next : nil
        guard signature != lastSignature else { return }
        lastSignature = signature
        NotificationCenter.default.post(name: .mediaChanged, object: nil)
    }

    /// Test hook: feed one bridge line as if the bridge had printed it.
    func debugApply(_ object: [String: Any]) { apply(object) }

    /// Test hook: pretend this is playing.
    func debugInject(_ fake: NowPlaying?) {
        current = fake
        NotificationCenter.default.post(name: .mediaChanged, object: nil)
    }

    // MARK: Commands

    private func send(_ name: String, code: Int32, options: [String: Any]? = nil) {
        if let bridgeInput, bridge?.isRunning == true {
            try? bridgeInput.write(contentsOf: Data((name + "\n").utf8))
            return
        }
        // Bridge-only notes (code < 0, e.g. "pin") have no MediaRemote command.
        guard code >= 0, let sendCommand else { return }
        _ = sendCommand(code, options.map { $0 as CFDictionary })
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in self?.refreshDirect() }
    }

    /// Why playback commands cannot reach the shown player, if they cannot.
    static func followedReason(_ item: NowPlaying?) -> String? {
        guard let item, item.isFollowed, !item.isMusic else { return nil }
        let app = item.appName.isEmpty ? L("This player") : item.appName
        return L("%1$@ takes no playback commands from other apps while another player holds Now Playing. Open %1$@ to control it.", app)
    }

    /// Commands for a followed player go nowhere (or to the wrong app):
    /// say so instead of sending.
    private func blockedByFollow() -> Bool {
        guard let reason = Self.followedReason(current) else { return false }
        NotificationCenter.default.post(name: Self.controlUnavailable, object: reason)
        return true
    }

    /// Play / pause by priority: the shown player (music before video) is
    /// paused first; pressed again while another player still plays, that
    /// one is paused; with nothing playing the shown player plays.
    func togglePlayPause() {
        guard let item = current else { send("toggle", code: 2); return }
        if item.isPlaying {
            transport(.pause, on: item)
        } else if let other = item.othersPlaying.first {
            pauseOther(other, shown: item)
        } else {
            transport(.play, on: item)
        }
    }

    func nextTrack() {
        guard let item = current else { send("next", code: 4); return }
        transport(.next, on: item)
    }

    func previousTrack() {
        guard let item = current else { send("prev", code: 5); return }
        transport(.previous, on: item)
    }

    /// System commands reach only the app holding Now Playing; a music app
    /// without it is driven through its menu, anything else says why not.
    private func transport(_ action: PlayerMenu.Transport, on item: NowPlaying) {
        if !item.isFollowed {
            switch action {
            case .play: send("play", code: 0)
            case .pause: send("pause", code: 1)
            case .toggle: send("toggle", code: 2)
            case .next: send("next", code: 4)
            case .previous: send("prev", code: 5)
            }
            // A held item gets no report back: look at the audio output instead.
            if isHolding {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in self?.refreshHeld() }
            }
            return
        }
        if blockedByFollow() { return }
        let app = item.appName.isEmpty ? L("The player") : item.appName
        guard PlayerMenu.isTrusted else {
            unavailable(L("%@ does not hold Now Playing. Allow Accessibility (Settings → General) so OmniHub can use its menu.", app))
            return
        }
        let scan = menuEntries(for: item, rescan: true)
        guard let entry = PlayerMenu.transportTarget(scan.entries, action), PlayerMenu.press(entry, in: scan) else {
            unavailable(L("%@ does not hold Now Playing and has no menu item for this.", app))
            return
        }
        debugTransportHook?(entry.title)
        send("pin", code: -1)
    }

    /// The shown player is paused but another one still plays.
    private func pauseOther(_ pid: pid_t, shown item: NowPlaying) {
        if pid == item.nowPlayingPID {
            send("pause", code: 1)
            return
        }
        func name(_ pid: pid_t) -> String { Self.owningApp(of: pid)?.localizedName ?? L("The other player") }
        let holder = item.nowPlayingPID > 0 ? name(item.nowPlayingPID) : L("another app")
        NotificationCenter.default.post(name: Self.controlUnavailable,
                                        object: L("%@ can't be paused from OmniHub while %@ holds Now Playing. Pause it in its own window.", name(pid), holder))
    }

    /// Test hook: the menu item a transport command pressed.
    var debugTransportHook: ((String) -> Void)?

    /// The three play modes offered by the player button.
    enum PlayMode: String { case order, repeatOne, shuffle }

    static func playMode(of item: NowPlaying) -> PlayMode {
        if item.shuffleMode > 1 { return .shuffle }
        if item.repeatMode == 2 { return .repeatOne }
        return .order
    }

    // MARK: Play mode and like

    /// MediaRemote command numbers.
    static let commandLike = 21, commandRepeat = 25, commandShuffle = 26

    /// How a control reaches the player.
    enum Route: Equatable {
        /// MediaRemote: the player registered the command.
        case remote
        /// The player's own menu bar (Accessibility).
        case menu
        /// Neither; the text says why.
        case unavailable(String)
    }

    enum Control { case playMode, like }

    /// Menu items of the current player, rescanned when the item changes.
    private var menuScan = PlayerMenu.Scan.empty
    private var menuKey = ""

    private func menuEntries(for item: NowPlaying, rescan: Bool = false) -> PlayerMenu.Scan {
        // Trust is part of the key: a scan made before Accessibility was
        // granted is empty and must not outlive the grant.
        let key = "\(PlayerMenu.isTrusted)|\(item.pid)|\(item.title)|\(item.artist)"
        if rescan || key != menuKey {
            menuKey = key
            menuScan = PlayerMenu.scan(pid: item.pid)
        }
        return menuScan
    }

    /// Players that publish nothing about mode / like through MediaRemote
    /// may still show it in their menus (check marks, "Unlike").
    private func fillFromMenu(_ item: inout NowPlaying) {
        guard let commands = item.commands, item.pid > 0, PlayerMenu.isTrusted else { return }
        let needsMode = !commands.contains(Self.commandShuffle) && !commands.contains(Self.commandRepeat)
        let needsLike = !commands.contains(Self.commandLike)
        guard needsMode || needsLike else { return }
        let entries = menuEntries(for: item).entries
        if needsMode, item.shuffleMode == 0, item.repeatMode == 0 {
            if let mode = PlayerMenu.currentMode(entries) {
                (item.shuffleMode, item.repeatMode) = Self.modes(for: mode)
            } else if !PlayerMenu.modes(in: entries).isEmpty, let mode = Self.rememberedMode(for: item.bundleID) {
                // The menu shows no state (NetEase): use the mode last set from here.
                (item.shuffleMode, item.repeatMode) = Self.modes(for: mode)
            }
        }
        if needsLike, item.liked == nil { item.liked = PlayerMenu.likedState(entries) }
    }

    func route(_ control: Control, for item: NowPlaying? = nil) -> Route {
        guard let item = item ?? current else { return .unavailable(L("Nothing is playing")) }
        if let reason = Self.followedReason(item) { return .unavailable(reason) }
        let codes = control == .like ? [Self.commandLike] : [Self.commandShuffle, Self.commandRepeat]
        // Not reported (direct fallback, older bridge): just try.
        guard let commands = item.commands else { return .remote }
        if codes.contains(where: commands.contains) { return .remote }
        let app = item.appName.isEmpty ? L("This player") : item.appName
        guard PlayerMenu.isTrusted else {
            return .unavailable(L("%@ takes only play / pause from other apps. Allow Accessibility (Settings → General) to use its menu instead.", app))
        }
        let entries = menuEntries(for: item).entries
        let found = control == .like
            ? entries.contains { PlayerMenu.isLike($0.title) || PlayerMenu.isUnlike($0.title) }
            : entries.contains { PlayerMenu.mode(of: $0.title) != nil }
        return found ? .menu : .unavailable(L("%@ does not accept this from other apps and has no menu item for it.", app))
    }

    /// Players whose menu items carry no check mark (NetEase) cannot be read
    /// back: OmniHub remembers the mode it last set there, per player.
    static func rememberedMode(for bundleID: String?) -> PlayMode? {
        guard let bundleID, let raw = UserDefaults.standard.string(forKey: "player.mode." + bundleID) else { return nil }
        return PlayMode(rawValue: raw)
    }

    static func remember(_ mode: PlayMode, for bundleID: String?) {
        guard let bundleID else { return }
        UserDefaults.standard.set(mode.rawValue, forKey: "player.mode." + bundleID)
    }

    /// MediaRemote shuffle / repeat values of a mode.
    static func modes(for mode: PlayMode) -> (shuffle: Int, repeat: Int) {
        switch mode {
        case .order: return (1, 3)
        case .repeatOne: return (1, 2)
        case .shuffle: return (3, 3)
        }
    }

    static func nextMode(after mode: PlayMode) -> PlayMode {
        switch mode {
        case .order: return .repeatOne
        case .repeatOne: return .shuffle
        case .shuffle: return .order
        }
    }

    /// Posted with the reason when a control cannot reach the player.
    static let controlUnavailable = Notification.Name("omnihub.mediaControlUnavailable")

    /// The next mode the player offers: order → repeat one → shuffle →
    /// order, skipping modes it has no way to reach (a player with only a
    /// Shuffle toggle goes order ↔ shuffle).
    static func nextMode(after mode: PlayMode, offered: Set<PlayMode>) -> PlayMode {
        var candidate = nextMode(after: mode)
        for _ in 0..<3 {
            if candidate == .order || offered.contains(candidate) { return candidate }
            candidate = nextMode(after: candidate)
        }
        return .order
    }

    /// Order (repeat all) → repeat one → shuffle → order.
    func cyclePlayMode() {
        guard var playing = current else { return }
        var next = Self.nextMode(after: Self.playMode(of: playing))
        if route(.playMode, for: playing) == .menu {
            let offered = PlayerMenu.modes(in: menuEntries(for: playing, rescan: true).entries)
            next = Self.nextMode(after: Self.playMode(of: playing), offered: offered)
        }
        switch route(.playMode, for: playing) {
        case .remote:
            let (shuffle, repeatMode) = Self.modes(for: next)
            if playing.commands?.contains(Self.commandShuffle) != false {
                send("shuffle \(shuffle)", code: 26, options: ["kMRMediaRemoteOptionShuffleMode": shuffle])
            }
            if playing.commands?.contains(Self.commandRepeat) != false {
                send("repeat \(repeatMode)", code: 25, options: ["kMRMediaRemoteOptionRepeatMode": repeatMode])
            }
        case .menu:
            let scan = menuEntries(for: playing, rescan: true)
            guard let target = PlayerMenu.modeTarget(scan.entries, next: next), PlayerMenu.press(target, in: scan) else {
                unavailable(L("Could not find the %@ item in the player's menu.", next.rawValue))
                return
            }
            if PlayerMenu.currentMode(scan.entries) == nil { Self.remember(next, for: playing.bundleID) }
            refreshMenuSoon()
        case .unavailable(let reason):
            unavailable(reason)
            return
        }
        // Show the choice at once; the player's own report follows (and
        // replaces it with what really happened).
        (playing.shuffleMode, playing.repeatMode) = Self.modes(for: next)
        current = playing
        NotificationCenter.default.post(name: .mediaChanged, object: nil)
    }

    func toggleLike() {
        guard var playing = current else { return }
        let like = !(playing.liked ?? false)
        switch route(.like, for: playing) {
        case .remote:
            send(like ? "like" : "unlike", code: 21, options: ["kMRMediaRemoteOptionIsNegative": !like])
        case .menu:
            let scan = menuEntries(for: playing, rescan: true)
            guard let target = PlayerMenu.likeTarget(scan.entries, liked: playing.liked),
                  PlayerMenu.press(target, in: scan) else {
                unavailable(L("Could not find a Like item in the player's menu."))
                return
            }
            refreshMenuSoon()
        case .unavailable(let reason):
            unavailable(reason)
            return
        }
        playing.liked = like
        current = playing
        NotificationCenter.default.post(name: .mediaChanged, object: nil)
    }

    private func unavailable(_ reason: String) {
        if !PlayerMenu.isTrusted { PlayerMenu.promptForTrust() }
        NotificationCenter.default.post(name: Self.controlUnavailable, object: reason)
    }

    /// Reads the menus again once the player has reacted.
    private func refreshMenuSoon() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self, var item = self.current else { return }
            _ = self.menuEntries(for: item, rescan: true)
            item.shuffleMode = 0; item.repeatMode = 0; item.liked = nil
            self.fillFromMenu(&item)
            self.current = item
            NotificationCenter.default.post(name: .mediaChanged, object: nil)
        }
    }

    /// Diagnostics: what the player accepts and which route each control takes.
    var controlReport: [String] {
        guard let item = current else { return ["controls = (nothing playing)"] }
        func describe(_ route: Route) -> String {
            switch route {
            case .remote: return "MediaRemote"
            case .menu: return "player menu"
            case .unavailable(let reason): return "unavailable — " + reason
            }
        }
        var lines = ["player = \(item.appName) pid=\(item.pid) bundle=\(item.bundleID ?? "-")",
                     "commands = " + (item.commands.map { $0.sorted().map(String.init).joined(separator: ",") } ?? "not reported")
                        + "  (21 like, 25 repeat, 26 shuffle)",
                     "playMode → " + describe(route(.playMode, for: item)),
                     "like → " + describe(route(.like, for: item)),
                     "accessibility = \(PlayerMenu.isTrusted)"]
        let scan = menuEntries(for: item, rescan: true)
        for entry in scan.entries {
            lines.append("  menu: " + (entry.path + [entry.title]).joined(separator: " › ")
                         + (entry.checked ? "  ✓" : "") + (entry.enabled ? "" : "  (disabled)"))
        }
        for menu in scan.menus {
            lines.append("  menu \(menu.path): " + menu.titles.joined(separator: " | "))
        }
        return lines
    }

    /// Jumps forwards / backwards in the current item (seconds).
    func seek(by delta: Double) {
        if blockedByFollow() { return }
        guard let position = current?.position() else { return }
        seek(to: position + delta)
    }

    /// Replaces sending a seek (selftests).
    var debugSeekHook: ((Double) -> Void)?

    /// Jumps to a position in the current item (seconds from the start).
    func seek(to seconds: Double) {
        if blockedByFollow() { return }
        guard var playing = current else { return }
        // 24 = seek to playback position (MRMediaRemoteCommand).
        if let commands = playing.commands, !commands.contains(24) {
            let app = playing.appName.isEmpty ? L("this player") : playing.appName
            NotificationCenter.default.post(name: Self.controlUnavailable, object: L("Seeking is not supported by %@", app))
            return
        }
        var target = max(0, seconds)
        if playing.duration > 0 { target = min(target, playing.duration) }
        if let hook = debugSeekHook {
            hook(target)
        } else if let bridgeInput, bridge?.isRunning == true {
            try? bridgeInput.write(contentsOf: Data(String(format: "seek %.2f\n", target).utf8))
        } else if let setElapsed {
            setElapsed(target)
        } else {
            return
        }
        // Show the new position straight away; the bridge confirms it shortly.
        playing.elapsed = target
        playing.anchor = Date()
        current = playing
        NotificationCenter.default.post(name: .mediaChanged, object: nil)
    }

    /// Brings the app that owns the current track to the front.
    /// Test hook: called instead of switching apps.
    var debugActivateHook: (() -> Void)?

    func activateOwner() {
        if let hook = debugActivateHook { hook(); return }
        guard let bundleID = current?.bundleID else { return }
        let running = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first
        if let running, running.isHidden { running.unhide() }
        // Re-opening the bundle is the one activation route that works even
        // when this (accessory) app is not the active one.
        let url = running?.bundleURL ?? NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
        if let url {
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = true
            NSWorkspace.shared.openApplication(at: url, configuration: configuration)
        } else {
            running?.activate(options: [.activateAllWindows])
        }
    }
}
