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
    private weak var shown: NSView?
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
        let side = NSVisualEffectView()
        side.material = .sidebar
        side.blendingMode = .behindWindow
        side.state = .followsWindowActiveState
        let edge = NSView()
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

        for view in [side, edge, titleLabel, host] as [NSView] {
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
            titleLabel.leadingAnchor.constraint(equalTo: edge.trailingAnchor, constant: 28),
            host.topAnchor.constraint(equalTo: root.topAnchor, constant: 58),
            host.leadingAnchor.constraint(equalTo: edge.trailingAnchor, constant: 24),
            host.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -24),
            host.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -20),
            placeholder.centerXAnchor.constraint(equalTo: host.centerXAnchor),
            placeholder.centerYAnchor.constraint(equalTo: host.centerYAnchor)
        ])
        contentView = root
    }

    // MARK: Pages

    private func show(_ target: Page, activate: Bool = true) {
        page = target
        Prefs.set(Self.pageKey, target.rawValue)
        sidebar.select(Self.pages.firstIndex(of: target) ?? 0)
        titleLabel.stringValue = target.title
        install()
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
        let view = FloatingDockPanel.pageView(for: page)
        if view !== shown || !view.isDescendant(of: host) {
            if let old = shown, old !== view, old.isDescendant(of: host) {
                (old as? DockPage)?.pageDidDisappear()
                old.removeFromSuperview()
            }
            scroll?.removeFromSuperview()
            scroll = nil
            FloatingDockPanel.release(view)
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
        case .home: FloatingDockPanel.layoutHome(width: width)
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
    var debugHost: NSView { host }
    var debugShown: NSView? { shown }
    var debugPlaceholderShown: Bool { !placeholder.isHidden }
    static var debugWindow: MainWindow? { shared }
    func debugPick(_ target: Page) {
        guard let index = Self.pages.firstIndex(of: target) else { return }
        sidebar.rows[index].performClick(nil)
    }
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
