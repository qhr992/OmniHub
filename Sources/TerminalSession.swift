import AppKit
import Darwin

/// A port forward of one connection.
final class PortForward {
    let id = UUID().uuidString
    /// "L" local → server side, "R" server → local side, "D" SOCKS proxy.
    let kind: String
    let bind: String
    let listenPort: Int
    let targetHost: String
    let targetPort: Int
    /// Proxy the forward's own connection goes through ("" = shares the tab's connection).
    let proxyID: String
    var state = "Starting…"
    var active = false
    var process: Process?

    init(kind: String, bind: String, listenPort: Int, targetHost: String, targetPort: Int, proxyID: String) {
        self.kind = kind
        self.bind = bind
        self.listenPort = listenPort
        self.targetHost = targetHost
        self.targetPort = targetPort
        self.proxyID = proxyID
    }

    /// ["-L", "127.0.0.1:8080:10.0.0.5:80"]
    var spec: [String] {
        let listen = bind.isEmpty ? "\(listenPort)" : "\(bind):\(listenPort)"
        return kind == "D" ? ["-D", listen] : ["-\(kind)", "\(listen):\(targetHost):\(targetPort)"]
    }

    var summary: String {
        let listen = "\(bind.isEmpty ? "127.0.0.1" : bind):\(listenPort)"
        switch kind {
        case "D": return "SOCKS  local \(listen)"
        case "R": return "server \(listen) → \(targetHost):\(targetPort) (local side)"
        default: return "local \(listen) → \(targetHost):\(targetPort) (server side)"
        }
    }
}

/// One tab: a PTY, the screen model fed by it, and the view showing it.
/// The process behind it is a login shell, or ssh / Telnet to a remote host.
final class TerminalSession {
    enum Link { case local, connecting, connected, closed }

    let id = UUID()
    let number: Int
    let target: RemoteTarget?
    let scrollView = NSScrollView()
    private let textView = TerminalTextView(frame: NSRect(x: 0, y: 0, width: 780, height: 380))
    private lazy var cursor = TerminalCursor(textView: textView)
    private let buffer = TerminalBuffer()
    private var masterFD: Int32 = -1
    private var childPID: pid_t = 0
    private var readSource: DispatchSourceRead?
    private var renderedLengths: [Int] = []
    private var lastCursorRow = 0
    private var checkTimer: Timer?
    private var generation = 0

    private(set) var link = Link.local
    private(set) var forwards: [PortForward] = []

    // Automation after the connection is up.
    private var steps: [AutoStep] = []
    private var collectingForSteps = false
    private var awaitingPrompt = false
    /// 0 = not logging in, 1 = waiting for the user-name prompt, 2 = password.
    private var telnetLogin = 0
    private var stepBuffer = ""
    private var stepDeadline: Timer?
    private(set) var stepsDone = 0

    /// A local shell exited (`exit`, Ctrl+D): the tab goes away.
    var onExit: (() -> Void)?
    var onTitleChange: (() -> Void)?
    var onLinkChange: (() -> Void)?
    var onForwardsChange: (() -> Void)?
    /// Keyboard shortcut pressed while the terminal has focus.
    var onAction: ((TerminalAction) -> Bool)?

    /// Tab label: profile / host for remote tabs; else what the shell set
    /// as window title, else "zsh N".
    var title: String {
        if let target { return target.title }
        let custom = buffer.title.trimmingCharacters(in: .whitespaces)
        return custom.isEmpty ? "\(shellName) \(number)" : custom
    }

    private var shellName = "zsh"
    var isAlive: Bool { masterFD >= 0 }
    var text: String { textView.string }
    var focusView: NSView { textView }

    static var fontSize: CGFloat { CGFloat(min(max(Prefs.double("terminal.fontSize", 12), 8), 28)) }
    static var monospacedFont: NSFont {
        NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
    }

    init(number: Int, target: RemoteTarget? = nil) {
        self.number = number
        self.target = target
        buildView()
        spawn()
    }

    private func buildView() {
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = false
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude,
                                  height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.lineFragmentPadding = 0
        textView.drawsBackground = false
        textView.font = Self.monospacedFont
        textView.textColor = .textColor
        textView.textContainerInset = NSSize(width: 10, height: 8)
        textView.usesFindBar = true
        textView.isIncrementalSearchingEnabled = true
        textView.onInput = { [weak self] data in self?.write(data) }
        textView.onAction = { [weak self] action in self?.perform(action) ?? false }
        // The first prompt may be drawn before the view is on the (dark) card.
        textView.onAppearanceChange = { [weak self] in self?.render() }
        textView.onFocusChange = { [weak self] in self?.cursor.focusChanged() }

        scrollView.documentView = textView
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false
    }

    /// Shortcuts the tab handles itself; the rest go to the page.
    private func perform(_ action: TerminalAction) -> Bool {
        switch action {
        case .clear: write(Data([0x0C])); return true               // Ctrl+L
        case .copy:
            if textView.selectedRange().length > 0 { textView.copy(nil) }
            return true
        case .paste: textView.paste(nil); return true
        case .selectAll: textView.selectAll(nil); return true
        case .find:
            let item = NSMenuItem()
            item.tag = NSTextFinder.Action.showFindInterface.rawValue
            textView.performTextFinderAction(item)
            return true
        case .scrollToTop: textView.scrollToBeginningOfDocument(nil); return true
        case .scrollToBottom: textView.scrollToEndOfDocument(nil); return true
        case .pageUp: textView.scrollPageUp(nil); return true
        case .pageDown: textView.scrollPageDown(nil); return true
        default: return onAction?(action) ?? false
        }
    }

    // MARK: PTY

    private func spawn() {
        var arguments: [String]
        var extra: [String: String] = [:]
        if let target {
            (arguments, extra) = target.launch()
            link = .connecting
        } else {
            let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
            let shellPath = FileManager.default.fileExists(atPath: shell) ? shell : "/bin/zsh"
            shellName = (shellPath as NSString).lastPathComponent
            arguments = [shellPath, "-il"]
        }

        // A Finder-launched app has no TERM and a "C" locale; give the child
        // a sane interactive environment. Pagers are disabled because this
        // view has no alternate screen.
        var environment = ProcessInfo.processInfo.environment
        environment["TERM"] = "xterm-256color"
        environment["PAGER"] = "cat"
        environment["GIT_PAGER"] = "cat"
        if environment["LANG"] == nil {
            let chinese = Locale.preferredLanguages.first?.hasPrefix("zh") ?? false
            environment["LANG"] = chinese ? "zh_CN.UTF-8" : "en_US.UTF-8"
        }
        environment.merge(extra) { _, new in new }

        // Everything the child needs is prepared before the fork, so the
        // child only performs chdir + execve.
        var argv: [UnsafeMutablePointer<CChar>?] = arguments.map { strdup($0) } + [nil]
        var envp: [UnsafeMutablePointer<CChar>?] = environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
        let cHome = strdup(NSHomeDirectory())!
        defer {
            for pointer in argv + envp { free(pointer) }
            free(cHome)
        }

        var size = winsize(ws_row: UInt16(max(buffer.visibleRows, 5)), ws_col: UInt16(max(buffer.columns, 20)),
                           ws_xpixel: 0, ws_ypixel: 0)
        var master: Int32 = 0

        // forkpty does setsid + TIOCSCTTY + dup2 onto 0/1/2 for us.
        let pid = forkpty(&master, nil, nil, &size)
        if pid == 0 {
            chdir(cHome)
            execve(argv[0], &argv, &envp)
            _exit(127)
        }
        guard pid > 0 else {
            notice("Could not start the process.")
            link = target == nil ? .local : .closed
            return
        }

        masterFD = master
        childPID = pid
        generation += 1
        let mine = generation

        let source = DispatchSource.makeReadSource(fileDescriptor: master, queue: .main)
        source.setEventHandler { [weak self] in
            guard let self, self.generation == mine else { return }
            self.drainOutput()
        }
        source.setCancelHandler {
            Darwin.close(master)
            var status: Int32 = 0
            waitpid(pid, &status, WNOHANG)
        }
        source.resume()
        readSource = source

        guard let target else { return }
        onLinkChange?()
        if target.isSSH {
            watchForConnection()
        } else {
            // Telnet has no handshake to wait for.
            link = .connected
            onLinkChange?()
            stepBuffer = ""
            if let profile = target.profile, !profile.loginUser.isEmpty || !profile.secretID.isEmpty {
                // No user name = the server asks only for a password.
                telnetLogin = profile.loginUser.isEmpty ? 2 : 1
                collectingForSteps = true
            } else {
                beginSteps(after: 0.5)
            }
        }
    }

    /// Polls the control socket until the login has gone through.
    private func watchForConnection() {
        checkTimer?.invalidate()
        guard let target else { return }
        let mine = generation
        let timer = Timer(timeInterval: 0.8, repeats: true) { [weak self] timer in
            guard let self, self.generation == mine, self.link == .connecting else { timer.invalidate(); return }
            Subprocess.run(target.muxArguments(["-O", "check", target.host])) { [weak self] result in
                guard let self, self.generation == mine, self.link == .connecting, result.ok else { return }
                self.link = .connected
                self.checkTimer?.invalidate()
                self.onLinkChange?()
                self.beginSteps(after: 0.4)
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        checkTimer = timer
    }

    private func drainOutput() {
        var chunk = [UInt8](repeating: 0, count: 16384)
        let count = Darwin.read(masterFD, &chunk, chunk.count)
        guard count > 0 else {
            // EOF / EIO: the process exited.
            if count == 0 || errno != EAGAIN { processDidExit() }
            return
        }
        let before = buffer.title
        let bytes = Array(chunk[0..<count])
        buffer.feed(bytes)
        render()
        if buffer.title != before { onTitleChange?() }
        if collectingForSteps {
            stepBuffer += String(decoding: bytes, as: UTF8.self)
            if stepBuffer.count > 8000 { stepBuffer = String(stepBuffer.suffix(4000)) }
            if telnetLogin > 0 { advanceTelnetLogin() } else { advanceSteps() }
        }
    }

    /// Telnet has no login of its own: the profile's user name and vault
    /// password are typed at the server's "login:" / "Password:" prompts.
    private func advanceTelnetLogin() {
        guard let profile = target?.profile else { telnetLogin = 0; return }
        let seen = stepBuffer.lowercased()
        if telnetLogin == 1 {
            guard ["login:", "username:", "user:"].contains(where: { seen.contains($0) }) else { return }
            write(Data((profile.loginUser + "\r").utf8))
            stepBuffer = ""
            telnetLogin = profile.secretID.isEmpty ? 0 : 2
        } else if telnetLogin == 2 {
            guard seen.contains("password:") else { return }
            if let secret = Vault.secret(for: profile.secretID) { write(Data((secret + "\r").utf8)) }
            stepBuffer = ""
            telnetLogin = 0
        }
        if telnetLogin == 0 {
            collectingForSteps = false
            beginSteps(after: 0.8)
        }
    }

    private func processDidExit() {
        readSource?.cancel()
        readSource = nil
        masterFD = -1
        childPID = 0
        checkTimer?.invalidate()
        cancelSteps()
        guard target != nil else { onExit?(); return }
        // A remote tab stays, so the reason is still on screen.
        link = .closed
        dropMuxForwards()
        notice("Connection closed. Use Reconnect at the top right to log in again.")
        onLinkChange?()
    }

    private func stopProcess() {
        generation += 1
        checkTimer?.invalidate()
        cancelSteps()
        if childPID > 0 { kill(childPID, SIGHUP) }
        readSource?.cancel()
        readSource = nil
        masterFD = -1
        childPID = 0
        if let path = target?.controlPath, !path.isEmpty { try? FileManager.default.removeItem(atPath: path) }
    }

    /// Ends the process (closing its tab, quitting the app).
    func terminate() {
        stopProcess()
        for forward in forwards { forward.process?.terminate() }
        forwards.removeAll()
    }

    /// Drops the connection and logs in again in the same tab.
    func reconnect() {
        guard target != nil else { return }
        stopProcess()
        dropMuxForwards()
        notice("Reconnecting…")
        spawn()
        updateWindowSize(force: true)
    }

    /// A line from OmniHub itself, shown in the terminal.
    private func notice(_ text: String) {
        buffer.feed(Array("\r\n[OmniHub] \(text)\r\n".utf8))
        render()
    }

    // MARK: Automation

    /// Runs the profile's commands once the login has gone through.
    private func beginSteps(after delay: TimeInterval) {
        guard let all = target?.profile?.steps.filter({ !$0.send.isEmpty }), !all.isEmpty else { return }
        let mine = generation
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, self.generation == mine, self.isAlive else { return }
            self.steps = all
            self.stepsDone = 0
            self.runNextStep()
        }
    }

    private func cancelSteps() {
        steps = []
        telnetLogin = 0
        awaitingPrompt = false
        collectingForSteps = false
        stepDeadline?.invalidate()
        stepDeadline = nil
    }

    /// Types the next command. If it comes with an answer, output is then
    /// watched for the prompt.
    private func runNextStep() {
        guard let step = steps.first, isAlive else { cancelSteps(); return }
        stepBuffer = ""
        write(Data((step.send + "\r").utf8))
        guard step.answers else {
            finishStep()
            return
        }
        awaitingPrompt = true
        collectingForSteps = true
        let timer = Timer(timeInterval: 60, repeats: false) { [weak self] _ in
            guard let self, self.awaitingPrompt else { return }
            self.cancelSteps()
            self.notice("No prompt appeared within 60 s; automation stopped.")
        }
        RunLoop.main.add(timer, forMode: .common)
        stepDeadline = timer
    }

    /// Called as output arrives: answers once the prompt is on screen.
    private func advanceSteps() {
        guard awaitingPrompt, let step = steps.first else { return }
        // The first line is the shell echoing the command back; a prompt
        // word inside the command itself must not count.
        guard let lineEnd = stepBuffer.firstIndex(where: { $0 == "\n" || $0 == "\r" }) else { return }
        let output = stepBuffer[lineEnd...].lowercased()
        let wanted = step.expect.isEmpty ? ["password", "passphrase", "密码", "(yes/no"] : [step.expect.lowercased()]
        guard wanted.contains(where: { output.contains($0) }) else { return }
        awaitingPrompt = false
        stepDeadline?.invalidate()
        stepDeadline = nil
        var answer = step.reply
        if !step.secretID.isEmpty {
            guard let secret = Vault.secret(for: step.secretID) else {
                cancelSteps()
                notice("The vault entry for this step is missing; automation stopped.")
                return
            }
            answer = secret
        }
        // A moment for the program to finish switching the terminal to
        // no-echo input — it discards anything typed before that.
        let mine = generation
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            guard let self, self.generation == mine, self.isAlive else { return }
            self.write(Data((answer + "\r").utf8))
            self.finishStep()
        }
    }

    private func finishStep() {
        guard !steps.isEmpty else { return }
        steps.removeFirst()
        stepsDone += 1
        collectingForSteps = false
        guard !steps.isEmpty else { return }
        let mine = generation
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            guard let self, self.generation == mine else { return }
            self.runNextStep()
        }
    }

    // MARK: Port forwards

    func addForward(kind: String, bind: String, listenPort: Int, targetHost: String, targetPort: Int, proxyID: String) {
        guard let target, target.isSSH else { return }
        let forward = PortForward(kind: kind, bind: bind, listenPort: listenPort, targetHost: targetHost,
                                  targetPort: targetPort, proxyID: proxyID)
        forwards.append(forward)
        onForwardsChange?()

        if proxyID.isEmpty {
            // Rides on the tab's own connection.
            Subprocess.run(target.muxArguments(["-O", "forward"] + forward.spec + [target.host])) { [weak self] result in
                forward.active = result.ok
                forward.state = result.ok ? "Active" : "Failed: \(result.message)"
                self?.onForwardsChange?()
            }
            return
        }
        guard let (arguments, environment) = target.standaloneForwardArguments(spec: forward.spec, proxyID: proxyID) else {
            forward.state = "Failed: forwarding through a proxy needs a saved connection"
            onForwardsChange?()
            return
        }
        forward.process = Subprocess.run(arguments, environment: environment) { [weak self] result in
            forward.process = nil
            forward.active = false
            if self?.forwards.contains(where: { $0 === forward }) == true {
                forward.state = "Stopped: \(result.message)"
                self?.onForwardsChange?()
            }
        }
        // No news after a moment means the tunnel is up.
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in
            guard forward.process?.isRunning == true else { return }
            forward.active = true
            forward.state = "Active (via proxy)"
            self?.onForwardsChange?()
        }
    }

    func removeForward(_ id: String) {
        guard let index = forwards.firstIndex(where: { $0.id == id }), let target else { return }
        let forward = forwards.remove(at: index)
        if let process = forward.process {
            process.terminate()
        } else if forward.active {
            Subprocess.run(target.muxArguments(["-O", "cancel"] + forward.spec + [target.host])) { _ in }
        }
        onForwardsChange?()
    }

    /// Forwards carried by the tab's connection end with it.
    private func dropMuxForwards() {
        let before = forwards.count
        forwards.removeAll { $0.proxyID.isEmpty }
        if forwards.count != before { onForwardsChange?() }
    }

    // MARK: Rendering

    private func render() {
        guard let storage = textView.textStorage else { return }
        let cursorRow = buffer.row
        var from = min(buffer.consumeDirty(), cursorRow, lastCursorRow)
        from = max(0, min(from, renderedLengths.count))

        // UTF-16 offset where line `from` starts; when from > 0 the newline
        // before it is rewritten as well.
        var offset = 0
        for index in 0..<from { offset += renderedLengths[index] + 1 }
        if from > 0 { offset -= 1 }

        var text = from > 0 ? "\n" : ""
        var lengths: [Int] = []
        var cursorRange: NSRange?
        for index in from..<buffer.lines.count {
            let lineStart = offset + text.utf16.count
            let line: String
            if index == cursorRow {
                let rendered = buffer.cursorLine()
                line = rendered.text
                cursorRange = NSRange(location: lineStart + rendered.cursor.location,
                                      length: rendered.cursor.length)
            } else {
                line = buffer.text(ofLine: index)
            }
            lengths.append(line.utf16.count)
            text += line
            if index < buffer.lines.count - 1 { text += "\n" }
        }

        let attributes: [NSAttributedString.Key: Any] = [
            .font: Self.monospacedFont,
            .foregroundColor: NSColor.textColor
        ]
        let range = NSRange(location: min(offset, storage.length),
                            length: max(0, storage.length - offset))
        storage.beginEditing()
        storage.replaceCharacters(in: range, with: NSAttributedString(string: text, attributes: attributes))
        storage.endEditing()
        cursor.move(to: cursorRange)

        renderedLengths.removeSubrange(from...)
        renderedLengths.append(contentsOf: lengths)
        lastCursorRow = cursorRow
        textView.scrollToEndOfDocument(nil)
    }

    /// Test hooks: the cursor cell's background as drawn (sRGB); start a
    /// new breathing cycle; tell the cursor the focus changed.
    var debugCursorColor: NSColor? { cursor.currentColor }
    func debugRestartCursor() { cursor.move(to: cursor.range) }
    func debugCursorFocusChanged() { cursor.focusChanged() }

    /// The font size changed: redraw everything and tell the shell the new
    /// number of columns.
    func fontDidChange() {
        textView.font = Self.monospacedFont
        renderedLengths = []
        lastCursorRow = 0
        render()
        updateWindowSize(force: true)
    }

    func write(_ data: Data) {
        guard masterFD >= 0 else { return }
        data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            _ = Darwin.write(masterFD, base, raw.count)
        }
    }

    /// Tells the shell how many columns and rows fit the view.
    func updateWindowSize(force: Bool = false) {
        guard scrollView.contentSize.width > 0 else { return }
        let font = Self.monospacedFont
        let charWidth = ("W" as NSString).size(withAttributes: [.font: font]).width
        let lineHeight = NSLayoutManager().defaultLineHeight(for: font)
        let inset = textView.textContainerInset
        let cols = max(20, Int((scrollView.contentSize.width - inset.width * 2 - 16) / max(charWidth, 1)))
        let rows = max(5, Int((scrollView.contentSize.height - inset.height * 2) / max(lineHeight, 1)))
        guard force || cols != buffer.columns || rows != buffer.visibleRows else { return }
        buffer.columns = cols
        buffer.visibleRows = rows
        guard masterFD >= 0 else { return }
        var size = winsize(ws_row: UInt16(rows), ws_col: UInt16(cols), ws_xpixel: 0, ws_ypixel: 0)
        _ = ioctl(masterFD, UInt(TIOCSWINSZ), &size)
    }
}

// MARK: - Input view

final class TerminalTextView: NSTextView {
    var onInput: ((Data) -> Void)?
    var onAction: ((TerminalAction) -> Bool)?
    var onAppearanceChange: (() -> Void)?
    /// The view gained or lost the keyboard (its own focus, or its window's).
    var onFocusChange: (() -> Void)?
    private var keyObservers: [NSObjectProtocol] = []

    override var acceptsFirstResponder: Bool { true }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        onAppearanceChange?()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        keyObservers.forEach(NotificationCenter.default.removeObserver)
        keyObservers = []
        if let window {
            keyObservers = [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification].map { name in
                NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                    self?.focusChanged()
                }
            }
        }
        focusChanged()
    }

    /// Reported once the responder change has settled.
    private func focusChanged() {
        DispatchQueue.main.async { [weak self] in self?.onFocusChange?() }
    }

    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        TerminalFocus.refresh()
        focusChanged()
        return accepted
    }

    override func resignFirstResponder() -> Bool {
        let accepted = super.resignFirstResponder()
        TerminalFocus.refresh()
        focusChanged()
        return accepted
    }

    /// Runs the shortcut bound to this key press, if there is one.
    private func runShortcut(_ event: NSEvent) -> Bool {
        guard let action = TerminalKeymap.shared.action(for: event) else { return false }
        return onAction?(action) ?? false
    }

    override func keyDown(with event: NSEvent) {
        if runShortcut(event) { return }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags.contains(.command) { super.keyDown(with: event); return }
        let option = flags.contains(.option)

        switch event.keyCode {
        case 36, 76: send([0x0D]); return                       // Return / Enter
        case 51: send(option ? [0x17] : [0x7F]); return         // Delete (⌥ = word)
        case 117: send("\u{1B}[3~"); return                     // Forward delete
        case 48: send(flags.contains(.shift) ? "\u{1B}[Z" : "\t"); return
        case 123: send(option ? "\u{1B}b" : "\u{1B}[D"); return
        case 124: send(option ? "\u{1B}f" : "\u{1B}[C"); return
        case 125: send("\u{1B}[B"); return
        case 126: send("\u{1B}[A"); return
        case 115: send("\u{1B}[H"); return                      // Home
        case 119: send("\u{1B}[F"); return                      // End
        case 116, 121: return                                   // Page Up / Down
        default: break
        }

        // Control combinations arrive as the control character itself
        // (Ctrl+C = 0x03), so they can be written straight to the PTY.
        if let characters = event.characters, !characters.isEmpty {
            send(characters)
        }
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard event.type == .keyDown, window?.firstResponder === self else {
            return super.performKeyEquivalent(with: event)
        }
        if runShortcut(event) { return true }
        return super.performKeyEquivalent(with: event)
    }

    /// Paste goes to the shell, not into the (read-only) text view.
    override func paste(_ sender: Any?) {
        guard let string = NSPasteboard.general.string(forType: .string), !string.isEmpty else { return }
        send(string.replacingOccurrences(of: "\r\n", with: "\r").replacingOccurrences(of: "\n", with: "\r"))
    }

    private func send(_ string: String) { onInput?(Data(string.utf8)) }
    private func send(_ bytes: [UInt8]) { onInput?(Data(bytes)) }
}

/// Keeps the global shortcuts out of a shell's way: while a terminal has
/// the keyboard, keys it needs (control keys, its own bindings) reach it.
enum TerminalFocus {
    private static var observing = false

    static var isTyping: Bool {
        NSApp.windows.contains { $0.isKeyWindow && $0.firstResponder is TerminalTextView }
    }

    static func refresh() {
        startObserving()
        // Responder and key changes settle after the call that reports them.
        DispatchQueue.main.async { HotKeyCenter.shared.setTerminalTyping(isTyping) }
    }

    private static func startObserving() {
        guard !observing else { return }
        observing = true
        for name in [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification] {
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { _ in refresh() }
        }
    }
}
