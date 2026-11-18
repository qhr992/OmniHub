import AppKit

/// Terminal page of the dock card. Each tab is its own shell or remote login.
///
/// Row 1: tabs · ＋ · Connections · Downloads ……… Settings.
/// Row 2 (remote tabs only): user@host:port ……… Reconnect · SFTP · Port forwarding.
/// Shortcuts follow macOS's Terminal and live in terminal-keys.json.
final class TerminalPane: NSView, DockPage {
    private var sessions: [TerminalSession] = []
    private var activeIndex = 0
    private var nextNumber = 1

    private let tabBar = NSStackView()
    private let infoBar = NSView()
    private let statusDot = NSView()
    private let infoLabel = NSTextField(labelWithString: "")
    private let container = NSView()
    private var infoHeight: NSLayoutConstraint!
    private var connectionsButton: NSButton!
    private var transfersButton: NSButton!
    private var forwardButton: NSButton!
    private var sftpButton: NSButton!
    private var reconnectButton: NSButton!

    // Transient drop-downs (one at a time) and the larger overlays.
    private var dropdown: NSView?
    private var scrim: ClickCatcher?
    private var sftpDrawer: SFTPBrowserView?
    private var sftpBottom: NSLayoutConstraint?
    private var settingsView: TerminalSettingsView?
    private var settingsScrim: ClickCatcher?

    init() {
        super.init(frame: .zero)
        buildContent()
        NotificationCenter.default.addObserver(self, selector: #selector(transfersChanged),
                                               name: .transfersChanged, object: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    // MARK: DockPage

    func preferredSize(horizontal: Bool) -> NSSize { NSSize(width: 800, height: 470) }
    var initialResponder: NSView? { activeSession?.focusView }

    func pageWillAppear() {
        TerminalKeymap.shared.reloadIfChanged()
        if sessions.isEmpty { addTab() }
        DispatchQueue.main.async { [weak self] in self?.activeSession?.updateWindowSize() }
    }

    /// Settings and drop-downs do not outlive the card: coming back to the
    /// terminal shows the terminal.
    func pageDidDisappear() {
        dropdown?.removeFromSuperview()
        dropdown = nil
        scrim?.removeFromSuperview()
        scrim = nil
        guard let settingsView else { return }
        settingsView.commit()
        settingsView.removeFromSuperview()
        self.settingsView = nil
        settingsScrim?.removeFromSuperview()
        settingsScrim = nil
    }

    /// Esc closes whatever is open on top of the terminal first.
    func handleEscape() -> Bool {
        if dropdown != nil { closeDropdown(); return true }
        if settingsView != nil { closeSettings(); return true }
        if sftpDrawer != nil { closeSFTP(); return true }
        return false
    }

    var activeSession: TerminalSession? {
        sessions.indices.contains(activeIndex) ? sessions[activeIndex] : nil
    }

    func terminateAll() { sessions.forEach { $0.terminate() } }

    // MARK: Debug hooks (headless verification)

    var debugText: String { activeSession?.text ?? "(terminal not open)" }
    var debugTabs: String {
        "tabs = \(sessions.count) active = \(activeIndex) titles = \(sessions.map(\.title)) "
            + "links = \(sessions.map { "\($0.link)" }) info = \"\(infoBar.isHidden ? "" : infoLabel.stringValue)\""
    }
    func debugWrite(_ text: String) { activeSession?.write(Data(text.utf8)) }
    func debugPerform(_ action: TerminalAction) { _ = handle(action) }
    func debugConnect(_ line: String) -> Bool {
        guard let target = RemoteTarget(commandLine: line) else { return false }
        addTab(target: target)
        return true
    }
    func debugConnect(profile: ConnectionProfile) { addTab(target: RemoteTarget(profile: profile)) }
    var debugSFTP: SFTPBrowserView? { sftpDrawer }

    // MARK: Build

    private func iconButton(_ symbol: String, _ tooltip: String, _ action: Selector, size: CGFloat = 12) -> NSButton {
        let config = NSImage.SymbolConfiguration(pointSize: size, weight: .medium)
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: tooltip)?.withSymbolConfiguration(config)
        let button = NSButton(image: image ?? NSImage(), target: self, action: action)
        button.isBordered = false
        button.toolTip = tooltip
        button.contentTintColor = NSColor(white: 1, alpha: 0.78)
        button.translatesAutoresizingMaskIntoConstraints = false
        button.widthAnchor.constraint(equalToConstant: 24).isActive = true
        button.heightAnchor.constraint(equalToConstant: 22).isActive = true
        return button
    }

    private func buildContent() {
        tabBar.orientation = .horizontal
        tabBar.spacing = 5
        tabBar.alignment = .centerY
        tabBar.translatesAutoresizingMaskIntoConstraints = false
        tabBar.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        // Tabs that do not fit are clipped rather than pushing the buttons out.
        let tabClip = NSView()
        tabClip.wantsLayer = true
        tabClip.layer?.masksToBounds = true
        tabClip.translatesAutoresizingMaskIntoConstraints = false
        tabClip.addSubview(tabBar)

        let add = iconButton("plus", "New Tab", #selector(addTabClicked))
        connectionsButton = iconButton("server.rack", "Connections", #selector(toggleConnections))
        transfersButton = iconButton("arrow.down.circle", "Recent Downloads", #selector(toggleTransfers), size: 13)
        let gear = iconButton("gearshape", "Terminal Settings: Connections, Vault, Proxies", #selector(toggleSettings), size: 13)
        let actions = NSStackView(views: [add, connectionsButton, transfersButton])
        actions.orientation = .horizontal
        actions.spacing = 2
        actions.translatesAutoresizingMaskIntoConstraints = false

        // ---- row 2: connection info
        statusDot.wantsLayer = true
        statusDot.layer?.cornerRadius = 3.5
        infoLabel.font = .monospacedSystemFont(ofSize: 11, weight: .medium)
        infoLabel.textColor = NSColor(white: 1, alpha: 0.85)
        infoLabel.isSelectable = true
        reconnectButton = iconButton("arrow.clockwise", "Reconnect", #selector(reconnect))
        sftpButton = iconButton("folder", "SFTP: browse the server's files", #selector(toggleSFTP), size: 13)
        forwardButton = iconButton("arrow.left.arrow.right", "Port Forwarding", #selector(toggleForwards))
        let remoteActions = NSStackView(views: [reconnectButton, sftpButton, forwardButton])
        remoteActions.orientation = .horizontal
        remoteActions.spacing = 2
        infoBar.wantsLayer = true
        infoBar.layer?.masksToBounds = true
        for view in [statusDot, infoLabel, remoteActions] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            infoBar.addSubview(view)
        }

        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor(white: 0, alpha: 0.42).cgColor
        container.layer?.cornerRadius = 8
        container.layer?.masksToBounds = true

        for view in [tabClip, actions, gear, infoBar, container] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        infoHeight = infoBar.heightAnchor.constraint(equalToConstant: 0)
        let actionsAfterTabs = actions.leadingAnchor.constraint(equalTo: tabClip.trailingAnchor, constant: 4)
        NSLayoutConstraint.activate([
            tabClip.topAnchor.constraint(equalTo: topAnchor),
            tabClip.leadingAnchor.constraint(equalTo: leadingAnchor),
            tabClip.heightAnchor.constraint(equalToConstant: 24),
            tabBar.leadingAnchor.constraint(equalTo: tabClip.leadingAnchor),
            tabBar.centerYAnchor.constraint(equalTo: tabClip.centerYAnchor),
            tabClip.trailingAnchor.constraint(equalTo: tabBar.trailingAnchor).withPriority(.defaultHigh),
            actionsAfterTabs,
            actions.centerYAnchor.constraint(equalTo: tabClip.centerYAnchor),
            actions.trailingAnchor.constraint(lessThanOrEqualTo: gear.leadingAnchor, constant: -8),
            gear.trailingAnchor.constraint(equalTo: trailingAnchor),
            gear.centerYAnchor.constraint(equalTo: tabClip.centerYAnchor),

            infoBar.topAnchor.constraint(equalTo: tabClip.bottomAnchor, constant: 4),
            infoBar.leadingAnchor.constraint(equalTo: leadingAnchor),
            infoBar.trailingAnchor.constraint(equalTo: trailingAnchor),
            infoHeight,
            statusDot.leadingAnchor.constraint(equalTo: infoBar.leadingAnchor, constant: 4),
            statusDot.centerYAnchor.constraint(equalTo: infoBar.centerYAnchor),
            statusDot.widthAnchor.constraint(equalToConstant: 7),
            statusDot.heightAnchor.constraint(equalToConstant: 7),
            infoLabel.leadingAnchor.constraint(equalTo: statusDot.trailingAnchor, constant: 6),
            infoLabel.centerYAnchor.constraint(equalTo: infoBar.centerYAnchor),
            remoteActions.trailingAnchor.constraint(equalTo: infoBar.trailingAnchor),
            remoteActions.centerYAnchor.constraint(equalTo: infoBar.centerYAnchor),

            container.topAnchor.constraint(equalTo: infoBar.bottomAnchor, constant: 4),
            container.leadingAnchor.constraint(equalTo: leadingAnchor),
            container.trailingAnchor.constraint(equalTo: trailingAnchor),
            container.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
    }

    override func layout() {
        super.layout()
        activeSession?.updateWindowSize()
    }

    // MARK: Tabs

    func addTab(target: RemoteTarget? = nil) {
        let session = TerminalSession(number: nextNumber, target: target)
        if target == nil { nextNumber += 1 }
        session.onExit = { [weak self, weak session] in
            guard let self, let session else { return }
            self.remove(session)
        }
        session.onTitleChange = { [weak self] in self?.rebuildTabBar() }
        session.onLinkChange = { [weak self] in self?.refreshInfoBar() }
        session.onForwardsChange = { [weak self, weak session] in
            guard let self, let session, session === self.activeSession else { return }
            (self.dropdown as? ForwardsView)?.reload()
            self.refreshInfoBar()
        }
        session.onAction = { [weak self] action in self?.handle(action) ?? false }
        sessions.append(session)
        select(sessions.count - 1)
    }

    func closeActiveTab() {
        guard let session = activeSession else { return }
        session.terminate()
        remove(session)
    }

    private func remove(_ session: TerminalSession) {
        guard let index = sessions.firstIndex(where: { $0 === session }) else { return }
        session.scrollView.removeFromSuperview()
        sessions.remove(at: index)
        if sessions.isEmpty {
            // Last tab gone: close the card; the next visit starts fresh.
            nextNumber = 1
            closeSFTP()
            rebuildTabBar()
            refreshInfoBar()
            FloatingDockPanel.closeCard(ifShowing: .terminal)
            return
        }
        select(min(index <= activeIndex ? max(activeIndex - 1, 0) : activeIndex, sessions.count - 1))
    }

    private func select(_ index: Int) {
        guard sessions.indices.contains(index) else { return }
        if index != activeIndex || sftpDrawer?.session !== sessions[index] { closeSFTP() }
        closeDropdown()
        activeIndex = index
        for subview in container.subviews where subview is NSScrollView { subview.removeFromSuperview() }
        let view = sessions[index].scrollView
        container.addSubview(view, positioned: .below, relativeTo: nil)
        NSLayoutConstraint.activate([
            view.topAnchor.constraint(equalTo: container.topAnchor),
            view.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            view.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: container.trailingAnchor)
        ])
        rebuildTabBar()
        refreshInfoBar()
        layoutSubtreeIfNeeded()
        sessions[index].updateWindowSize()
        focusActive()
    }

    func cycle(by delta: Int) {
        guard sessions.count > 1 else { return }
        select((activeIndex + delta + sessions.count) % sessions.count)
    }

    private func focusActive() {
        if let session = activeSession, let window, window.isVisible, window.isKeyWindow {
            window.makeFirstResponder(session.focusView)
        }
    }

    private func rebuildTabBar() {
        for view in tabBar.arrangedSubviews {
            tabBar.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        for (index, session) in sessions.enumerated() {
            let tab = TerminalTabView(title: session.title, selected: index == activeIndex, remote: session.target != nil)
            tab.onSelect = { [weak self] in self?.select(index) }
            tab.onClose = { [weak self, weak session] in
                guard let self, let session else { return }
                session.terminate()
                self.remove(session)
            }
            tabBar.addArrangedSubview(tab)
        }
    }

    /// Row 2: who we are connected to, and the remote tools.
    private func refreshInfoBar() {
        guard let session = activeSession, let target = session.target else {
            infoBar.isHidden = true
            infoHeight.constant = 0
            return
        }
        infoBar.isHidden = false
        infoHeight.constant = 24
        let (color, word): (NSColor, String)
        switch session.link {
        case .connected: (color, word) = (.systemGreen, "")
        case .connecting: (color, word) = (.systemYellow, "  connecting…")
        default: (color, word) = (.systemRed, "  disconnected")
        }
        statusDot.layer?.backgroundColor = color.cgColor
        infoLabel.stringValue = target.display + (target.isSSH ? "" : "  (Telnet)") + word
        // SFTP and forwarding ride on the ssh connection.
        let usable = target.isSSH && session.link == .connected
        sftpButton.isHidden = !target.isSSH
        forwardButton.isHidden = !target.isSSH
        sftpButton.isEnabled = usable
        forwardButton.isEnabled = usable
        let live = session.forwards.filter(\.active).count
        forwardButton.contentTintColor = live > 0 ? .systemGreen : NSColor(white: 1, alpha: 0.78)
        forwardButton.toolTip = live > 0 ? "Port Forwarding (\(live) active)" : "Port Forwarding"
    }

    // MARK: Shortcuts

    /// Actions that concern the page rather than one tab.
    private func handle(_ action: TerminalAction) -> Bool {
        switch action {
        case .newTab: addTab()
        case .closeTab: closeActiveTab()
        case .nextTab: cycle(by: 1)
        case .previousTab: cycle(by: -1)
        case .connections: toggleConnections()
        case .biggerText: changeFont(by: 1)
        case .smallerText: changeFont(by: -1)
        case .defaultText: changeFont(by: nil)
        case .tab1, .tab2, .tab3, .tab4, .tab5, .tab6, .tab7, .tab8, .tab9:
            select((Int(action.rawValue.dropFirst(3)) ?? 1) - 1)
        default: return false
        }
        return true
    }

    private func changeFont(by delta: CGFloat?) {
        let next = delta.map { min(max(TerminalSession.fontSize + $0, 8), 28) } ?? 12
        Prefs.set("terminal.fontSize", Double(next))
        sessions.forEach { $0.fontDidChange() }
    }

    @objc private func addTabClicked() { addTab() }

    @objc private func reconnect() {
        closeSFTP()
        closeDropdown()
        activeSession?.reconnect()
        refreshInfoBar()
    }

    // MARK: Drop-downs

    /// Shows `view` under `anchor`; a click anywhere else closes it.
    private func showDropdown(_ view: NSView, size: NSSize, under anchor: NSView, alignRight: Bool) {
        closeDropdown()
        let catcher = ClickCatcher()
        catcher.onClick = { [weak self] in self?.closeDropdown() }
        catcher.frame = bounds
        catcher.autoresizingMask = [.width, .height]
        addSubview(catcher)
        scrim = catcher

        let anchorFrame = anchor.convert(anchor.bounds, to: self)
        var x = alignRight ? anchorFrame.maxX - size.width : anchorFrame.minX
        x = min(max(0, x), bounds.width - size.width)
        // The page is not flipped: "under" means a smaller y.
        let y = max(0, anchorFrame.minY - 4 - size.height)
        view.frame = NSRect(x: x, y: y, width: size.width, height: min(size.height, anchorFrame.minY - 4))
        view.wantsLayer = true
        view.layer?.cornerRadius = 10
        view.layer?.backgroundColor = NSColor(srgbRed: 0.10, green: 0.10, blue: 0.13, alpha: 0.98).cgColor
        view.layer?.borderWidth = 1
        view.layer?.borderColor = NSColor(white: 1, alpha: 0.14).cgColor
        view.shadow = {
            let shadow = NSShadow()
            shadow.shadowBlurRadius = 14
            shadow.shadowColor = NSColor.black.withAlphaComponent(0.5)
            shadow.shadowOffset = NSSize(width: 0, height: -4)
            return shadow
        }()
        addSubview(view)
        dropdown = view
    }

    private func closeDropdown() {
        guard dropdown != nil else { return }
        dropdown?.removeFromSuperview()
        dropdown = nil
        scrim?.removeFromSuperview()
        scrim = nil
        focusActive()
    }

    @objc private func toggleConnections() {
        if dropdown is ConnectionPickerView { closeDropdown(); return }
        let picker = ConnectionPickerView()
        picker.onConnect = { [weak self] target in
            self?.closeDropdown()
            self?.addTab(target: target)
        }
        picker.onManage = { [weak self] in
            self?.closeDropdown()
            self?.openSettings()
        }
        showDropdown(picker, size: NSSize(width: 380, height: 320), under: connectionsButton, alignRight: false)
        window?.makeFirstResponder(picker.searchField)
    }

    @objc private func toggleTransfers() {
        if dropdown is TransfersView { closeDropdown(); return }
        showDropdown(TransfersView(), size: NSSize(width: 400, height: 300), under: transfersButton, alignRight: false)
    }

    @objc private func toggleForwards() {
        if dropdown is ForwardsView { closeDropdown(); return }
        guard let session = activeSession, session.target?.isSSH == true else { return }
        showDropdown(ForwardsView(session: session), size: NSSize(width: 470, height: 330),
                     under: forwardButton, alignRight: true)
    }

    @objc private func transfersChanged() {
        let running = TransferCenter.shared.items.contains { $0.state == .running }
        transfersButton.contentTintColor = running ? .systemBlue : NSColor(white: 1, alpha: 0.78)
    }

    // MARK: SFTP drawer

    @objc private func toggleSFTP() {
        if sftpDrawer != nil { closeSFTP(); return }
        guard let session = activeSession, session.target?.isSSH == true, session.link == .connected else { return }
        closeDropdown()
        let drawer = SFTPBrowserView(session: session)
        drawer.onClose = { [weak self] in self?.closeSFTP() }
        drawer.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(drawer)
        let height = max(220, container.bounds.height * 0.64)
        // Starts below the terminal and slides up.
        let bottom = drawer.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: height)
        NSLayoutConstraint.activate([
            drawer.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            drawer.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            drawer.heightAnchor.constraint(equalToConstant: height),
            bottom
        ])
        container.layoutSubtreeIfNeeded()
        sftpDrawer = drawer
        sftpBottom = bottom
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.22
            context.allowsImplicitAnimation = true
            bottom.animator().constant = 0
            container.layoutSubtreeIfNeeded()
        }
        drawer.load(".")
    }

    private func closeSFTP() {
        guard let drawer = sftpDrawer else { return }
        sftpDrawer = nil
        sftpBottom = nil
        drawer.removeFromSuperview()
        focusActive()
    }

    // MARK: Settings overlay

    @objc private func toggleSettings() {
        if settingsView != nil { closeSettings() } else { openSettings() }
    }

    func openSettings(tab: Int = 0) {
        closeDropdown()
        if settingsView == nil {
            // A click on the terminal showing around the panel closes it.
            let catcher = ClickCatcher()
            catcher.onClick = { [weak self] in self?.closeSettings() }
            catcher.frame = bounds
            catcher.autoresizingMask = [.width, .height]
            catcher.wantsLayer = true
            catcher.layer?.backgroundColor = NSColor(white: 0, alpha: 0.25).cgColor
            addSubview(catcher)
            settingsScrim = catcher

            let view = TerminalSettingsView()
            view.onClose = { [weak self] in self?.closeSettings() }
            view.frame = bounds.insetBy(dx: 22, dy: 16)
            view.autoresizingMask = [.width, .height]
            addSubview(view)
            settingsView = view
        }
        settingsView?.select(tab: tab)
    }

    private func closeSettings() {
        settingsView?.commit()
        settingsView?.removeFromSuperview()
        settingsView = nil
        settingsScrim?.removeFromSuperview()
        settingsScrim = nil
        focusActive()
    }

    var debugSettings: TerminalSettingsView? { settingsView }
    func debugToggle(_ what: String) {
        switch what {
        case "connections": toggleConnections()
        case "transfers": toggleTransfers()
        case "forwards": toggleForwards()
        case "sftp": toggleSFTP()
        case "settings": toggleSettings()
        default: break
        }
    }
}

extension NSLayoutConstraint {
    func withPriority(_ priority: NSLayoutConstraint.Priority) -> NSLayoutConstraint {
        self.priority = priority
        return self
    }
}

/// Transparent layer under a drop-down: a click on it closes the drop-down.
final class ClickCatcher: NSView {
    var onClick: (() -> Void)?
    override func mouseDown(with event: NSEvent) { onClick?() }
    override func rightMouseDown(with event: NSEvent) { onClick?() }
}

// MARK: - Tab

final class TerminalTabView: NSView {
    var onSelect: (() -> Void)?
    var onClose: (() -> Void)?

    init(title: String, selected: Bool, remote: Bool) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 6
        layer?.backgroundColor = NSColor(white: 1, alpha: selected ? 0.20 : 0.07).cgColor

        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 11, weight: selected ? .semibold : .regular)
        label.textColor = selected ? .white : NSColor(white: 1, alpha: 0.65)
        label.lineBreakMode = .byTruncatingMiddle
        label.translatesAutoresizingMaskIntoConstraints = false

        let icon = NSImageView()
        icon.image = NSImage(systemSymbolName: remote ? "network" : "terminal", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 9.5, weight: .medium))
        icon.contentTintColor = remote ? NSColor(srgbRed: 0.45, green: 0.85, blue: 1.0, alpha: 1) : NSColor(white: 1, alpha: 0.55)
        icon.translatesAutoresizingMaskIntoConstraints = false

        let close = NSButton(image: NSImage(systemSymbolName: "xmark", accessibilityDescription: "Close Tab") ?? NSImage(),
                             target: self, action: #selector(closeTapped))
        close.isBordered = false
        close.imageScaling = .scaleProportionallyDown
        close.contentTintColor = NSColor(white: 1, alpha: 0.5)
        close.toolTip = "Close Tab"
        close.translatesAutoresizingMaskIntoConstraints = false

        addSubview(icon)
        addSubview(label)
        addSubview(close)
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 22),
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 13),
            label.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 4),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            label.widthAnchor.constraint(lessThanOrEqualToConstant: 130),
            close.leadingAnchor.constraint(equalTo: label.trailingAnchor, constant: 6),
            close.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            close.centerYAnchor.constraint(equalTo: centerYAnchor),
            close.widthAnchor.constraint(equalToConstant: 12),
            close.heightAnchor.constraint(equalToConstant: 12)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func mouseDown(with event: NSEvent) { onSelect?() }
    @objc private func closeTapped() { onClose?() }
}
