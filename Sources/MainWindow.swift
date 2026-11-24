import AppKit

extension Notification.Name {
    /// The main window opened or closed (OmniHub shows a Dock icon while it is open).
    static let mainWindowChanged = Notification.Name("omnihub.mainWindowChanged")
}

/// OmniHub as an ordinary window: every page down the left, the chosen one
/// on the right. A left click on the menu bar icon or the Dock icon opens
/// it. The pages are the card's own views, so a page is shown in one place
/// at a time: opening it here takes it from the card (which folds), and a
/// page the card borrows comes back when the card lets go of it.
final class MainWindow: NSWindow, NSWindowDelegate {
    typealias Page = FloatingDockPanel.Page

    private static var shared: MainWindow?
    static let pages: [Page] = [.home, .activity, .tasks, .terminal, .shelf, .clipboard, .settings]
    private static let pageKey = "main.page"
    private static let sidebarWidth: CGFloat = 216

    private let sidebar: SidebarList
    private let titleLabel = NSTextField(labelWithString: "")
    private let host = MainHostView()
    private let placeholder = NSTextField(labelWithString: L("Open in the dock card"))
    private(set) var page: Page = .home
    /// Where Back leads from Settings: the page shown before it.
    private var beforeSettings: Page = .home
    private let backButton = BackButton()
    private let side = NSVisualEffectView()
    private let edge = NSView()
    /// Layout with the page list, and Settings' own (list hidden, Back shown).
    private var withList: [NSLayoutConstraint] = []
    private var settingsOnly: [NSLayoutConstraint] = []
    private weak var shown: NSView?
    /// Home here is its own view (the card keeps its compact one).
    private lazy var home = MainHomeView()
    private var scroll: NSScrollView?

    // MARK: Opening

    static var isOpen: Bool { shared?.isVisible == true }

    /// Opens `target` (Settings on `settingsTab`). With `toggle`, a second
    /// call for the page already in front closes the window (hotkeys).
    static func open(_ target: Page, toggle: Bool = false, settingsTab: Int? = nil) {
        let window = instance()
        if toggle, settingsTab == nil, window.isVisible, window.isKeyWindow, window.page == target {
            window.close()
            return
        }
        window.show(target)
        if let settingsTab { FloatingDockPanel.settings.select(tab: settingsTab) }
    }

    /// The menu bar icon's left click and the Dock icon: open on the page
    /// last shown, or close when already in front.
    static func toggle() {
        if let window = shared, window.isVisible, window.isKeyWindow {
            window.close()
            return
        }
        open(Page(rawValue: Prefs.string(pageKey)) ?? .home)
    }

    @discardableResult
    private static func instance() -> MainWindow {
        if let shared { return shared }
        let window = MainWindow()
        shared = window
        return window
    }

    // MARK: Building

    private init() {
        sidebar = SidebarList(items: Self.pages.map { page in
            SidebarList.Item(title: page.englishTitle, symbol: page.symbol, tint: page.tint)
        })
        super.init(contentRect: NSRect(x: 0, y: 0, width: 1080, height: 700),
                   styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                   backing: .buffered, defer: false)
        title = "OmniHub"
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        isReleasedWhenClosed = false
        appearance = NSAppearance(named: .darkAqua)
        minSize = NSSize(width: 860, height: 540)
        delegate = self
        buildContent()
        center()
        setFrameAutosaveName("OmniHub.MainWindow")
        sidebar.onPick = { [weak self] index in self?.show(Self.pages[index], activate: false) }
        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(pageReleased), name: .dockPageReleased, object: nil)
        center.addObserver(self, selector: #selector(relayout), name: .mediaChanged, object: nil)
        center.addObserver(self, selector: #selector(relayout), name: .tasksChanged, object: nil)
    }

    private func buildContent() {
        let root = NSView()
        root.wantsLayer = true
        root.layer?.backgroundColor = NSColor(srgbRed: 0.098, green: 0.102, blue: 0.122, alpha: 1).cgColor

        // Sidebar: frosted, under the traffic lights.
        side.material = .sidebar
        side.blendingMode = .behindWindow
        side.state = .followsWindowActiveState
        edge.wantsLayer = true
        edge.layer?.backgroundColor = NSColor(white: 1, alpha: 0.07).cgColor
        let brand = NSTextField(labelWithString: "OmniHub")
        brand.font = .systemFont(ofSize: 11, weight: .semibold)
        brand.textColor = NSColor(white: 1, alpha: 0.38)

        titleLabel.font = .systemFont(ofSize: 22, weight: .bold)
        titleLabel.textColor = .white
        placeholder.font = .systemFont(ofSize: 13)
        placeholder.textColor = .tertiaryLabelColor
        host.wantsLayer = true
        host.onChange = { [weak self] in self?.syncPlaceholder() }

        backButton.target = self
        backButton.action = #selector(goBack)
        // The page list above the content, so it can slide away over it.
        for view in [host, side, edge, titleLabel, backButton] as [NSView] {
            view.wantsLayer = true
            view.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(view)
        }
        for view in [brand, sidebar] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            side.addSubview(view)
        }
        placeholder.translatesAutoresizingMaskIntoConstraints = false
        host.addSubview(placeholder)
        NSLayoutConstraint.activate([
            side.topAnchor.constraint(equalTo: root.topAnchor),
            side.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            side.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            side.widthAnchor.constraint(equalToConstant: Self.sidebarWidth),
            edge.topAnchor.constraint(equalTo: root.topAnchor),
            edge.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            edge.leadingAnchor.constraint(equalTo: side.trailingAnchor),
            edge.widthAnchor.constraint(equalToConstant: 1),

            sidebar.topAnchor.constraint(equalTo: side.topAnchor, constant: 52),
            sidebar.leadingAnchor.constraint(equalTo: side.leadingAnchor, constant: 10),
            sidebar.trailingAnchor.constraint(equalTo: side.trailingAnchor, constant: -10),
            brand.leadingAnchor.constraint(equalTo: side.leadingAnchor, constant: 20),
            brand.bottomAnchor.constraint(equalTo: side.bottomAnchor, constant: -16),

            titleLabel.topAnchor.constraint(equalTo: root.topAnchor, constant: 12),
            // Back sits right of the traffic lights, level with the title.
            backButton.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 84),
            backButton.centerYAnchor.constraint(equalTo: titleLabel.centerYAnchor),
            host.topAnchor.constraint(equalTo: root.topAnchor, constant: 58),
            host.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -24),
            host.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -20),
            placeholder.centerXAnchor.constraint(equalTo: host.centerXAnchor),
            placeholder.centerYAnchor.constraint(equalTo: host.centerYAnchor)
        ])
        withList = [
            titleLabel.leadingAnchor.constraint(equalTo: edge.trailingAnchor, constant: 28),
            host.leadingAnchor.constraint(equalTo: edge.trailingAnchor, constant: 24)
        ]
        settingsOnly = [
            titleLabel.leadingAnchor.constraint(equalTo: backButton.trailingAnchor, constant: 14),
            host.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 20)
        ]
        NSLayoutConstraint.activate(withList)
        contentView = root
    }

    /// Settings takes the whole window: the page list goes, Back comes.
    private func applyMode(animated: Bool) {
        let settings = page == .settings
        let changed = side.isHidden != settings
        NSLayoutConstraint.deactivate(settings ? withList : settingsOnly)
        NSLayoutConstraint.activate(settings ? settingsOnly : withList)
        backButton.isHidden = !settings
        guard animated, changed else {
            side.isHidden = settings
            edge.isHidden = settings
            return
        }
        // The list stays up while it slides away, and is shown before it slides back.
        side.isHidden = false
        edge.isHidden = false
        contentView?.layoutSubtreeIfNeeded()
        MainWindowMotion.slideList([side.layer, edge.layer], width: Self.sidebarWidth + 1, out: settings) { [weak self] in
            guard let self, self.page == .settings || !settings else { return }
            self.side.isHidden = self.page == .settings
            self.edge.isHidden = self.page == .settings
        }
    }

    /// The page arriving: from the right into Settings, from the left back
    /// out of it, fading up between other pages.
    private func animateArrival(from old: Page) {
        let kind: MainWindowMotion.Kind = page == .settings ? .enterSettings
            : old == .settings ? .leaveSettings : .switchPage
        let travel = MainWindowMotion.travel
        switch kind {
        case .enterSettings:
            MainWindowMotion.arrive(host.layer, dx: travel, dy: 0, duration: MainWindowMotion.settingsDuration)
            MainWindowMotion.arrive(backButton.layer, dx: -10, dy: 0, duration: 0.3, delay: 0.08)
        case .leaveSettings:
            MainWindowMotion.arrive(host.layer, dx: -travel, dy: 0, duration: MainWindowMotion.settingsDuration)
        case .switchPage:
            MainWindowMotion.arrive(host.layer, dx: 0, dy: -8, duration: MainWindowMotion.pageDuration)
        }
        MainWindowMotion.crossfade(titleLabel.layer)
    }

    /// Back from Settings to the page shown before it (⌘[ too).
    @objc private func goBack() {
        guard page == .settings else { return }
        show(beforeSettings, activate: false)
    }

    // MARK: Pages

    private func show(_ target: Page, activate: Bool = true) {
        if target == .settings, page != .settings { beforeSettings = page }
        let old = page
        // Motion only for a change the person sees.
        let animated = isVisible && !FloatingDockPanel.headless && old != target
        page = target
        Prefs.set(Self.pageKey, target.rawValue)
        sidebar.select(Self.pages.firstIndex(of: target) ?? 0)
        titleLabel.stringValue = target.title
        // Home greets instead of a title.
        titleLabel.isHidden = target == .home
        applyMode(animated: animated)
        install()
        if animated { animateArrival(from: old) }
        guard activate, !FloatingDockPanel.headless else { return }
        let wasOpen = isVisible
        // An ordinary window: a Dock icon and ⌘-Tab while it is open.
        if NSApp.activationPolicy() != .regular { NSApp.setActivationPolicy(.regular) }
        FocusKeeper.activateSelf()
        makeKeyAndOrderFront(nil)
        if !wasOpen { NotificationCenter.default.post(name: .mainWindowChanged, object: self) }
        if let responder = (shown as? DockPage)?.initialResponder { makeFirstResponder(responder) }
    }

    /// Puts the current page's view into the window, taking it from the card.
    private func install() {
        let view = page == .home ? home : FloatingDockPanel.pageView(for: page)
        if view !== shown || !view.isDescendant(of: host) {
            if let old = shown, old !== view, old.isDescendant(of: host) {
                (old as? DockPage)?.pageDidDisappear()
                old.removeFromSuperview()
            }
            scroll?.removeFromSuperview()
            scroll = nil
            if page != .home { FloatingDockPanel.release(view) }
            view.removeFromSuperview()
            view.translatesAutoresizingMaskIntoConstraints = false
            switch page {
            case .home, .activity: embedScrolling(view)
            default: pin(view)
            }
            shown = view
            (view as? DockPage)?.pageWillAppear()
        }
        syncPlaceholder()
        relayout()
    }

    /// "Open in the dock card" only while the card has borrowed the page.
    private func syncPlaceholder() {
        placeholder.isHidden = shown.map { $0.isDescendant(of: host) } ?? true
    }

    /// Pages with their own scrolling fill the area.
    private func pin(_ view: NSView) {
        host.addSubview(view)
        NSLayoutConstraint.activate([
            view.topAnchor.constraint(equalTo: host.topAnchor),
            view.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: host.trailingAnchor),
            view.bottomAnchor.constraint(equalTo: host.bottomAnchor)
        ])
    }

    /// Home and Activity are as tall as their content: they scroll here.
    private func embedScrolling(_ view: NSView) {
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        scroll.translatesAutoresizingMaskIntoConstraints = false
        let document = FlippedView()
        document.translatesAutoresizingMaskIntoConstraints = false
        scroll.documentView = document
        document.addSubview(view)
        host.addSubview(scroll)
        let clip = scroll.contentView
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: host.topAnchor),
            scroll.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: host.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: host.bottomAnchor),
            document.topAnchor.constraint(equalTo: clip.topAnchor),
            document.leadingAnchor.constraint(equalTo: clip.leadingAnchor),
            document.widthAnchor.constraint(equalTo: clip.widthAnchor),
            view.topAnchor.constraint(equalTo: document.topAnchor),
            view.leadingAnchor.constraint(equalTo: document.leadingAnchor),
            document.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: 12)
        ])
        self.scroll = scroll
    }

    /// Home and Activity take the area's width.
    @objc private func relayout() {
        guard let shown, shown.isDescendant(of: host) else { return }
        contentView?.layoutSubtreeIfNeeded()
        let width = max(400, host.bounds.width)
        switch page {
        case .home: home.setWidth(width)
        case .activity: FloatingDockPanel.activityView.setWidth(width)
        default: break
        }
    }

    /// The card let a page go: show ours again if it was the one it borrowed.
    @objc private func pageReleased() {
        guard isVisible, let shown, shown.superview == nil else { return }
        install()
    }

    // MARK: NSWindowDelegate

    func windowDidResize(_ notification: Notification) { relayout() }

    func windowDidBecomeKey(_ notification: Notification) {
        // Coming back from the card: take the page back if it borrowed it.
        if let shown, !shown.isDescendant(of: host) { install() }
    }

    func windowWillClose(_ notification: Notification) {
        if let shown, shown.isDescendant(of: host) {
            (shown as? DockPage)?.pageDidDisappear()
            shown.removeFromSuperview()
        }
        scroll?.removeFromSuperview()
        scroll = nil
        shown = nil
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: .mainWindowChanged, object: self)
            FocusKeeper.restore()
        }
    }

    // MARK: Test hooks

    static var debugState: String {
        guard let shared else { return "main = (nil)" }
        let view = shared.shown
        return "main visible=\(shared.isVisible) page=\(shared.page.rawValue) frame=\(shared.frame) "
            + "shown=\(view.map { "\(type(of: $0))" } ?? "-") inWindow=\(view?.isDescendant(of: shared.host) ?? false) "
            + "pageSize=\(view.map { "\($0.frame.size)" } ?? "-") host=\(shared.host.bounds.size)"
    }

    /// The window laid out at its size, without putting it on screen.
    static func debugOpen(_ target: Page, size: NSSize = NSSize(width: 1080, height: 700)) -> MainWindow {
        let window = instance()
        window.setContentSize(size)
        window.show(target, activate: false)
        window.contentView?.layoutSubtreeIfNeeded()
        window.relayout()
        window.contentView?.layoutSubtreeIfNeeded()
        return window
    }

    var debugSidebar: SidebarList { sidebar }
    var debugListShown: Bool { !side.isHidden }
    var debugBackShown: Bool { !backButton.isHidden }
    func debugBack() { backButton.performClick(nil) }
    var debugHost: NSView { host }
    var debugShown: NSView? { shown }
    var debugHome: MainHomeView { home }
    var debugPlaceholderShown: Bool { !placeholder.isHidden }
    static var debugWindow: MainWindow? { shared }
    func debugPick(_ target: Page) {
        guard let index = Self.pages.firstIndex(of: target) else { return }
        sidebar.rows[index].performClick(nil)
    }
}

/// "‹ Back" as a quiet pill: the way out of Settings.
final class BackButton: FocusButton {
    private var hovering = false {
        didSet { if hovering != oldValue { needsDisplay = true } }
    }

    init() {
        super.init(frame: .zero)
        isBordered = false
        title = ""
        image = nil
        let text = NSMutableAttributedString()
        let chevron = NSTextAttachment()
        chevron.image = NSImage(systemSymbolName: "chevron.left", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 11, weight: .bold))
        text.append(NSAttributedString(attachment: chevron))
        text.append(NSAttributedString(string: "  " + L("Back")))
        text.addAttributes([.font: NSFont.systemFont(ofSize: 13, weight: .medium),
                            .foregroundColor: NSColor(white: 1, alpha: 0.9)], range: NSRange(location: 0, length: text.length))
        attributedTitle = text
        setAccessibilityTitle(L("Back"))
        keyEquivalent = "["
        keyEquivalentModifierMask = .command
        toolTip = L("Back") + "  ⌘["
        isHidden = true
        translatesAutoresizingMaskIntoConstraints = false
        heightAnchor.constraint(equalToConstant: 28).isActive = true
        widthAnchor.constraint(equalToConstant: intrinsicContentSize.width + 26).isActive = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }

    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }

    private var shape: NSBezierPath { NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 14, yRadius: 14) }

    override func draw(_ dirtyRect: NSRect) {
        NSColor(white: 1, alpha: isHighlighted ? 0.18 : hovering ? 0.12 : 0.07).setFill()
        shape.fill()
        NSColor(white: 1, alpha: 0.12).setStroke()
        shape.stroke()
        super.draw(dirtyRect)
    }

    override func drawFocusRingMask() { shape.fill() }
    override var focusRingMaskBounds: NSRect { bounds }
}

/// The window's page area: notices when the card takes a page out of it.
final class MainHostView: NSView {
    var onChange: (() -> Void)?

    override func didAddSubview(_ subview: NSView) {
        super.didAddSubview(subview)
        DispatchQueue.main.async { [weak self] in self?.onChange?() }
    }

    override func willRemoveSubview(_ subview: NSView) {
        super.willRemoveSubview(subview)
        DispatchQueue.main.async { [weak self] in self?.onChange?() }
    }
}

extension FloatingDockPanel.Page {
    /// The English name (a key for the interface strings).
    var englishTitle: String {
        switch self {
        case .home: return "Home"
        case .activity: return "Activity"
        case .terminal: return "Terminal"
        case .clipboard: return "Clipboard"
        case .shelf: return "Shelf"
        case .tasks: return "Agenda"
        case .settings: return "Settings"
        }
    }

    /// The page's colour in the main window's list.
    var tint: NSColor {
        typealias Tint = SettingsSection.Tint
        switch self {
        case .home: return Tint.blue
        case .activity: return Tint.green
        case .tasks: return Tint.red
        case .terminal: return Tint.orange
        case .shelf: return Tint.yellow
        case .clipboard: return Tint.teal
        case .settings: return Tint.gray
        }
    }
}
