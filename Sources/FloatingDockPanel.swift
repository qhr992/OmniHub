import AppKit
import Carbon.HIToolbox
import UniformTypeIdentifiers

/// Floating widget (dock).
///
/// The ball: a small round icon that can sit anywhere on screen. While media
/// plays it grows into a pill of user-set length — spinning cover, a line of
/// text (lyric or title, scrolling when too long) and dancing bars.
///
/// The card: touching the ball with the pointer opens a dark card *next to*
/// it (below when the ball is near the top, to the right when it is near the
/// left, and so on), so the ball stays visible and can still be dragged.
/// The card has six pages — Home, Activity, Terminal, Clipboard, Agenda, Settings — reached
/// through the entry icons or the global hotkeys. Hovering always opens Home
/// and folds away when the pointer leaves; a page opened by a click or a
/// hotkey stays until it is closed (× at the top right, Esc, or the hotkey).
final class FloatingDockPanel: NSPanel, EscDismissable {
    private static var shared: FloatingDockPanel?

    private static let iconSize: CGFloat = 40
    private static let gap: CGFloat = 8
    private static let columnWidth: CGFloat = 250

    /// What the card shows.
    enum Page: String, CaseIterable {
        // Entry-icon order: the first five on the left, the last two on the right.
        case home, activity, tasks, terminal, shelf, clipboard, settings

        /// Pinned to the far end of the entry row (bottom of the column).
        var onTrailingSide: Bool { self == .clipboard || self == .settings }

        /// Home and Settings cannot be hidden from the entry row.
        var canHide: Bool { self != .home && self != .settings }

        static func isShown(_ page: Page) -> Bool {
            !page.canHide || Prefs.bool("nav.show.\(page.rawValue)", true)
        }

        var title: String {
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

        /// Position among the entry icons (zoom direction for equal sizes).
        var order: Int { Page.allCases.firstIndex(of: self) ?? 0 }

        var symbol: String {
            switch self {
            case .home: return "house.fill"
            case .activity: return "gauge.with.dots.needle.67percent"
            case .terminal: return "terminal.fill"
            case .clipboard: return "doc.on.clipboard.fill"
            case .shelf: return "tray.full.fill"
            case .tasks: return "checklist"
            case .settings: return "gearshape.fill"
            }
        }
    }
    private var page = Page.home

    // Ball
    private let ball = DockBallView()
    private let disc = SpinningDisc()
    private let compactLabel = MarqueeLabel(frame: .zero)
    private let compactBars = EqualizerView(barCount: 4)

    // Card chrome
    private let cardView = CardView()
    private let backdrop = NSView()
    private let shade = NSView()
    private let nav = NSStackView()
    /// Clipboard and Settings, at the far end of the entry row.
    private let navTrailing = NSStackView()
    private var navButtons: [Page: NSButton] = [:]
    private let pageTitle = NSTextField(labelWithString: "")
    private let holidayLabel = NSTextField(labelWithString: "")
    private let pageHost = FlippedView()
    private var pageWidth: NSLayoutConstraint?
    private var pageHeight: NSLayoutConstraint?
    private weak var shownPage: NSView?

    // Pages
    private let activity = ActivityView()
    private lazy var terminalPane = TerminalPane()
    private lazy var clipboardPane = ClipboardPane()
    private lazy var shelfPane = ShelfPane()
    private lazy var agendaPane = AgendaPane()
    private lazy var settingsPane = SettingsPane()
    private var terminalCreated = false

    // Home page
    private let artworkHolder = NSView()
    private let card = NSStackView()
    private let player = NSStackView()
    private let side = NSStackView()
    private let divider = NSView()
    private let artwork = ClickableImageView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let artistLabel = NSTextField(labelWithString: "")
    private let lyricLabel = NSTextField(labelWithString: "")
    private let cardBars = EqualizerView(barCount: 5)
    private let progress = ProgressBar()
    private let elapsedLabel = NSTextField(labelWithString: "")
    private let durationLabel = NSTextField(labelWithString: "")
    private let playButton = NSButton()
    private var previousButton = NSButton()
    private var nextButton = NSButton()
    private let modeButton = NSButton()
    private let likeButton = NSButton()
    private let tasksBox = NSStackView()
    private let tasksScroll = NSScrollView()
    private var tasksHeight: NSLayoutConstraint!
    private var sideWidth: NSLayoutConstraint!
    /// Test hook: lay the widget out as if music were playing.
    static var debugForceLive = false
    /// Test hook: lets the ball grow into / shrink from the pill headless.
    static var debugAnimateBall = false
    private var dividerWidth: NSLayoutConstraint!
    private var dividerHeight: NSLayoutConstraint!

    private var iconImage: NSImage?
    fileprivate var expanded = false
    /// Opened with a global hotkey: stays in front until it is closed.
    /// Anything opened by hovering or clicking folds away by itself.
    private var heldOpen = false
    /// The card was given the keyboard (entry icon, hotkey, menu).
    private var focused = false
    private var animation = 0
    /// Whether the ball last showed music, to see when music starts / stops.
    private var shownLive: Bool?
    /// Where the ball was when a hover opened the card: the pill may shrink
    /// to a ball under the pointer, so its old area still counts as "on it".
    private var openedFrom: NSRect?
    private var pollTimer: Timer?
    private var awaySince: Date?
    private var dragging = false
    private var reopenAfterDrag = false
    private var lastLyric = ""
    /// Space / ⌘← / ⌘→ … while the pointer rests on the home page.
    private var homeKeys: [HotKey] = []

    // MARK: Lifecycle

    static func toggle() {
        if let existing = shared, existing.isVisible {
            existing.closeCard()
            existing.orderOut(nil)
            Prefs.set("dock.hidden", true)
            return
        }
        show()
    }

    /// Shown at launch unless the user hid it last time.
    static func showAtLaunch() {
        if !Prefs.bool("dock.hidden") { show() }
    }

    static func show() {
        Prefs.set("dock.hidden", false)
        instance().orderFrontRegardless()
    }

    @discardableResult
    private static func instance() -> FloatingDockPanel {
        if let existing = shared { return existing }
        let panel = FloatingDockPanel()
        shared = panel
        panel.applyIcon()
        return panel
    }

    static func reloadIcon() { shared?.applyIcon() }

    /// Headless runs (`--render`): nothing is put on screen or given focus.
    static var headless = false

    /// Opens a page of the card and keeps it open. Calling it again for the
    /// page that is already open closes the card (hotkeys toggle).
    static func open(_ target: Page, toggle: Bool = true, settingsTab: Int? = nil, pinned: Bool = true) {
        let panel = instance()
        if toggle, panel.expanded, panel.heldOpen, panel.page == target, panel.isVisible {
            panel.closeCard()
            return
        }
        if let settingsTab { panel.settingsPane.select(tab: settingsTab) }
        if !headless { panel.orderFrontRegardless() }
        panel.present(target, hold: pinned, focus: !headless)
    }

    /// Closes the card (`ifShowing`: only when that page is the one on show).
    static func closeCard(ifShowing target: Page? = nil) {
        guard let shared, target == nil || shared.page == target else { return }
        shared.closeCard()
    }

    static var terminal: TerminalPane { instance().ensureTerminal() }
    static var terminalIfCreated: TerminalPane? { shared?.terminalCreated == true ? shared?.terminalPane : nil }
    static var clipboard: ClipboardPane { instance().clipboardPane }
    static var shelf: ShelfPane { instance().shelfPane }
    static var debugBallAcceptsFiles: Bool { instance().ball.registeredDraggedTypes.contains(.fileURL) }
    static var agenda: AgendaPane { instance().agendaPane }
    static var settings: SettingsPane { instance().settingsPane }
    static func terminateShells() { terminalIfCreated?.terminateAll() }

    static var debugState: String {
        guard let shared else { return "dock = (nil)" }
        let geometry = shared.geometry()
        return "dock visible=\(shared.isVisible) frame=\(shared.frame) expanded=\(shared.expanded) held=\(shared.heldOpen) "
            + "page=\(shared.page.rawValue) edge=\(shared.nearestEdge.rawValue) "
            + "layout=\(shared.isHorizontal ? "horizontal" : "vertical") "
            + "ball=\(geometry.ball) card=\(geometry.card.map { "\($0)" } ?? "-") "
            + "mediaShown=\(!shared.player.isHidden) taskRows=\(shared.tasksBox.arrangedSubviews.count) "
            + "holiday=\"\(shared.holidayLabel.isHidden ? "" : shared.holidayLabel.stringValue)\" "
            + "pill=\(shared.compactLabel.isHidden ? "bars" : "text") text=\"\(shared.compactLabel.text)\" "
            + "overflow=\(Int(shared.compactLabel.overflow)) homeKeys=\(shared.homeKeys.count)"
    }

    static var debugActivity: [String] { shared?.activity.debugRows ?? [] }

    // Test hooks for the dock self-test.
    static func debugCardSize(page: Page, x: Double, y: Double) -> NSSize {
        let panel = instance()
        Prefs.set("dock.posX", x)
        Prefs.set("dock.posY", y)
        panel.present(page, hold: true, focus: false)
        return panel.geometry().card?.size ?? .zero
    }
    static var debugPage: Page? { shared?.expanded == true ? shared?.page : nil }
    static var debugNav: (leading: [String], trailing: [String]) {
        guard let shared else { return ([], []) }
        func names(_ stack: NSStackView) -> [String] {
            stack.arrangedSubviews.filter { !$0.isHidden }.compactMap { ($0 as? NSButton)?.toolTip }
        }
        return (names(shared.nav), names(shared.navTrailing))
    }
    static func debugHeaderClick() { shared?.headerClicked() }
    /// Presses the progress bar at `from`, drags to `to` (fractions of its
    /// width) and lets go, with real mouse events.
    static func debugDragProgress(from: CGFloat, to: CGFloat) {
        guard let shared, let window = shared.progress.window else { return }
        window.contentView?.layoutSubtreeIfNeeded()
        shared.tickPlayback(force: true)
        let bar = shared.progress
        func point(_ fraction: CGFloat) -> NSPoint {
            bar.convert(NSPoint(x: bar.bounds.width * fraction, y: bar.bounds.midY), to: nil)
        }
        let wasVisible = window.isVisible
        if !wasVisible { window.orderFrontRegardless() }
        defer { if !wasVisible { window.orderOut(nil) } }
        let steps: [(NSEvent.EventType, CGFloat)] = [(.leftMouseDown, from), (.leftMouseDragged, (from + to) / 2),
                                                     (.leftMouseDragged, to), (.leftMouseUp, to)]
        for (type, fraction) in steps {
            if let event = NSEvent.mouseEvent(with: type, location: point(fraction), modifierFlags: [],
                                              timestamp: ProcessInfo.processInfo.systemUptime,
                                              windowNumber: window.windowNumber, context: nil,
                                              eventNumber: 0, clickCount: 1, pressure: 1) {
                window.sendEvent(event)
            }
        }
    }

    /// Test hook: a real click through the window's event dispatch at the
    /// centre of the cover, with the card not key (as after a hover).
    static func debugClickCover() {
        guard let shared, let window = shared.artwork.window else { return }
        window.contentView?.layoutSubtreeIfNeeded()
        let view = shared.artwork
        let center = view.convert(NSPoint(x: view.bounds.midX, y: view.bounds.midY), to: nil)
        // A hidden window drops mouse events: show it for the click.
        let wasVisible = window.isVisible
        if !wasVisible { window.orderFrontRegardless() }
        defer { if !wasVisible { window.orderOut(nil) } }
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            if let event = NSEvent.mouseEvent(with: type, location: center, modifierFlags: [],
                                              timestamp: ProcessInfo.processInfo.systemUptime,
                                              windowNumber: window.windowNumber, context: nil,
                                              eventNumber: 0, clickCount: 1, pressure: 1) {
                window.sendEvent(event)
            }
        }
    }
    static var debugTasks: (rows: Int, height: CGFloat, scrollerShown: Bool) {
        guard let shared else { return (0, 0, false) }
        return (shared.tasksBox.arrangedSubviews.filter { $0 is DockTaskRow }.count, shared.tasksHeight.constant,
                shared.tasksScroll.verticalScroller?.isHidden == false)
    }
    static var debugPlayerButtons: String {
        guard let shared else { return "" }
        return "mode=\(shared.modeButton.toolTip ?? "") like=\(shared.likeButton.toolTip ?? "") shown=\(!shared.player.isHidden)"
    }
    static var level: NSWindow.Level { instance().level }

    /// Opens the home page as a hover would, but keeps it open (demos).
    static func expandForDemo() {
        let panel = instance()
        panel.orderFrontRegardless()
        panel.present(.home, hold: true, focus: false)
    }

    /// Test hook: the page on show.
    static var debugShownPage: NSView? { shared?.shownPage }

    /// Test hook: park the ball at a fraction of the screen (0…1, 0…1).
    static func debugMove(x: Double, y: Double) {
        guard let shared else { return }
        Prefs.set("dock.posX", x)
        Prefs.set("dock.posY", y)
        shared.refresh()
    }

    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: Self.iconSize, height: Self.iconSize),
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered,
                   defer: false)
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        becomesKeyOnlyIfNeeded = true
        // The card is always dark, like a hardware island.
        appearance = NSAppearance(named: .darkAqua)
        migratePosition()
        buildContent()
        applyGeometry()

        let center = NotificationCenter.default
        for name in [Notification.Name.tasksChanged, .mediaChanged, .settingsChanged, .lyricsChanged] {
            center.addObserver(self, selector: #selector(dataChanged), name: name, object: nil)
        }
        center.addObserver(self, selector: #selector(dataChanged),
                           name: NSApplication.didChangeScreenParametersNotification, object: nil)
        center.addObserver(self, selector: #selector(activityChanged), name: .activityChanged, object: nil)
        center.addObserver(forName: MediaObserver.controlUnavailable, object: nil, queue: .main) { [weak self] note in
            self?.showControlNote(note.object as? String ?? "")
        }

        // Polling the pointer (instead of a tracking area) is immune to the
        // synthetic enter/exit events AppKit fires while the window is being
        // resized. The same tick advances the lyric line and the progress bar.
        let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
            self?.pollPointer()
            self?.tickPlayback()
        }
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer
    }

    override var canBecomeKey: Bool { true }

    // MARK: Tab between controls (see TabOrder)

    /// Tab / ⇧Tab are caught here, before the focused control sees them: a
    /// text field built in code has no next key view, and its field editor
    /// then keeps the Tab to itself instead of asking the window.
    override func sendEvent(_ event: NSEvent) {
        if handlesTab(event) { return }
        super.sendEvent(event)
    }

    /// False when Tab belongs to the focused view: the shell, a multi-line
    /// text, or text still being composed in an input method.
    private func handlesTab(_ event: NSEvent) -> Bool {
        guard event.type == .keyDown, event.keyCode == 48,
              event.modifierFlags.intersection([.command, .control, .option]).isEmpty else { return false }
        if let text = firstResponder as? NSTextView, !text.isFieldEditor || text.hasMarkedText() { return false }
        return moveFocus(from: focusedControl, backwards: event.modifierFlags.contains(.shift))
    }

    /// The control that has the keyboard; a text field being edited stands
    /// in for its field editor.
    var focusedControl: NSView? {
        if let editor = firstResponder as? NSTextView, editor.isFieldEditor { return editor.delegate as? NSView }
        return firstResponder as? NSView
    }

    /// Moves the keyboard to the next (previous) control of the page or of
    /// the panel open on top of it. False when there is nowhere to go.
    @discardableResult
    func moveFocus(from view: NSView?, backwards: Bool) -> Bool {
        guard let page = shownPage else { return false }
        let target: NSView?
        if let view, view.isDescendant(of: page) {
            target = TabOrder.next(after: view, backwards: backwards)
        } else {
            let stops = TabOrder.stops(in: TabOrder.topScope(in: page))
            target = backwards ? stops.last : stops.first
        }
        guard let target, makeFirstResponder(target) else { return false }
        target.scrollToVisible(target.bounds)
        return true
    }

    /// A click on the bare top strip: whatever the page has open on top
    /// (terminal settings, a drop-down) closes first; otherwise the card folds.
    private func headerClicked() {
        if let current = shownPage as? DockPage, current.handleEscape() { return }
        closeCard()
    }

    /// Esc: the page gets the first say (it may have a sheet open), then
    /// the card closes.
    func dismissByEscape() {
        if let current = shownPage as? DockPage, current.handleEscape() { return }
        closeCard()
    }

    @objc private func dataChanged() { refresh() }

    /// The activity page grows and shrinks with what it shows.
    @objc private func activityChanged() {
        if expanded, page == .activity, !dragging { applyGeometry() }
    }

    // MARK: Build

    private func buildContent() {
        let root = NSView()
        root.wantsLayer = true

        // ---- ball
        ball.wantsLayer = true
        ball.layer?.backgroundColor = NSColor(white: 0.04, alpha: 0.94).cgColor
        ball.layer?.borderColor = NSColor(white: 1, alpha: 0.10).cgColor
        ball.layer?.masksToBounds = true
        ball.owner = self
        ball.registerForDraggedTypes([.fileURL])
        ball.addSubview(disc)
        ball.addSubview(compactLabel)
        ball.addSubview(compactBars)
        root.addSubview(ball)

        // ---- card: Lan backdrop, dimmed so the text stays readable
        cardView.wantsLayer = true
        cardView.layer?.backgroundColor = NSColor(white: 0.04, alpha: 0.96).cgColor
        cardView.layer?.borderColor = NSColor(white: 1, alpha: 0.10).cgColor
        cardView.layer?.borderWidth = 1
        cardView.layer?.cornerRadius = 20
        cardView.layer?.masksToBounds = true
        backdrop.wantsLayer = true
        backdrop.layer?.contentsGravity = .resizeAspectFill
        backdrop.layer?.masksToBounds = true
        if let image = Artwork.background {
            var rect = NSRect(origin: .zero, size: image.size)
            backdrop.layer?.contents = image.cgImage(forProposedRect: &rect, context: nil, hints: nil)
        }
        backdrop.autoresizingMask = [.width, .height]
        shade.wantsLayer = true
        shade.autoresizingMask = [.width, .height]
        cardView.addSubview(backdrop)
        cardView.addSubview(shade)
        cardView.isHidden = true
        // A click on the card's top strip (not on a control) folds it away;
        // inside the page the keyboard belongs to the page (Esc in a shell).
        cardView.headerHeight = Self.padding + Self.stripHeight + 4
        cardView.onHeaderClick = { [weak self] in self?.headerClicked() }
        root.addSubview(cardView)

        // ---- card chrome: entry icons, title, holiday countdown, close
        nav.spacing = 4
        navTrailing.spacing = 4
        for target in Page.allCases {
            let button = NSButton()
            let config = NSImage.SymbolConfiguration(pointSize: 13, weight: .medium)
            button.image = (NSImage(systemSymbolName: target.symbol, accessibilityDescription: target.title)
                            ?? NSImage(systemSymbolName: "gauge", accessibilityDescription: target.title))?
                .withSymbolConfiguration(config)
            button.imagePosition = .imageOnly
            button.isBordered = false
            button.toolTip = target.title
            button.target = self
            button.action = #selector(navTapped(_:))
            button.tag = Page.allCases.firstIndex(of: target) ?? 0
            button.wantsLayer = true
            button.layer?.cornerRadius = 8
            button.translatesAutoresizingMaskIntoConstraints = false
            button.widthAnchor.constraint(equalToConstant: 32).isActive = true
            button.heightAnchor.constraint(equalToConstant: 28).isActive = true
            (target.onTrailingSide ? navTrailing : nav).addArrangedSubview(button)
            navButtons[target] = button
        }
        pageTitle.font = .systemFont(ofSize: 13, weight: .semibold)
        pageTitle.textColor = .white
        holidayLabel.font = .systemFont(ofSize: 11, weight: .medium)
        holidayLabel.textColor = NSColor(srgbRed: 1.0, green: 0.80, blue: 0.45, alpha: 1)
        holidayLabel.toolTip = "Next public holiday"
        for view in [nav, navTrailing, pageTitle, holidayLabel, pageHost] as [NSView] { cardView.addSubview(view) }

        buildHomePage()
        contentView = root
    }

    private func buildHomePage() {
        artwork.imageScaling = .scaleProportionallyUpOrDown
        artwork.wantsLayer = true
        artwork.layer?.cornerRadius = 10
        artwork.layer?.masksToBounds = true
        artwork.layer?.backgroundColor = NSColor(white: 1, alpha: 0.08).cgColor
        artwork.translatesAutoresizingMaskIntoConstraints = false
        // The cover casts a soft shadow tinted with its own colour. The
        // shadow lives on a holder view because the cover itself is clipped
        // to rounded corners.
        artworkHolder.wantsLayer = true
        artworkHolder.layer?.masksToBounds = false
        artworkHolder.layer?.shadowOpacity = 0.85
        artworkHolder.layer?.shadowRadius = 9
        artworkHolder.layer?.shadowOffset = CGSize(width: 0, height: -5)
        artworkHolder.layer?.shadowColor = NSColor.black.cgColor
        artworkHolder.translatesAutoresizingMaskIntoConstraints = false
        artworkHolder.addSubview(artwork)
        NSLayoutConstraint.activate([
            artworkHolder.widthAnchor.constraint(equalToConstant: 58),
            artworkHolder.heightAnchor.constraint(equalToConstant: 58),
            artwork.topAnchor.constraint(equalTo: artworkHolder.topAnchor),
            artwork.bottomAnchor.constraint(equalTo: artworkHolder.bottomAnchor),
            artwork.leadingAnchor.constraint(equalTo: artworkHolder.leadingAnchor),
            artwork.trailingAnchor.constraint(equalTo: artworkHolder.trailingAnchor)
        ])
        // A click on the cover opens the playing app (a gesture recognizer
        // never fired here: the card is usually not the key window).
        artwork.onClick = { MediaObserver.shared.activateOwner() }
        artwork.toolTip = "Open the app that is playing"

        titleLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        titleLabel.textColor = .white
        artistLabel.font = .systemFont(ofSize: 11)
        artistLabel.textColor = NSColor(white: 1, alpha: 0.6)
        lyricLabel.font = .systemFont(ofSize: 11, weight: .medium)
        lyricLabel.textColor = NSColor(srgbRed: 0.45, green: 0.85, blue: 1.0, alpha: 1)
        for label in [titleLabel, artistLabel, lyricLabel] {
            label.lineBreakMode = .byTruncatingTail
            label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        }
        let titles = ClickableStack(views: [titleLabel, artistLabel, lyricLabel])
        titles.orientation = .vertical
        titles.alignment = .leading
        titles.spacing = 2
        titles.onClick = { MediaObserver.shared.activateOwner() }
        titles.toolTip = "Open the app that is playing"
        titles.setContentHuggingPriority(.defaultLow, for: .horizontal)

        cardBars.translatesAutoresizingMaskIntoConstraints = false
        cardBars.widthAnchor.constraint(equalToConstant: 22).isActive = true
        cardBars.heightAnchor.constraint(equalToConstant: 18).isActive = true

        // Flexible gap keeps the bars pinned to the right edge.
        let gap = NSView()
        gap.setContentHuggingPriority(.init(1), for: .horizontal)
        gap.setContentCompressionResistancePriority(.init(1), for: .horizontal)
        let header = NSStackView(views: [artworkHolder, titles, gap, cardBars])
        header.orientation = .horizontal
        header.alignment = .centerY
        header.spacing = 10

        for label in [elapsedLabel, durationLabel] {
            label.font = .monospacedDigitSystemFont(ofSize: 9, weight: .regular)
            label.textColor = NSColor(white: 1, alpha: 0.5)
        }
        progress.translatesAutoresizingMaskIntoConstraints = false
        // Taller than the 4 pt bar it draws, so it is easy to hit.
        progress.heightAnchor.constraint(equalToConstant: 10).isActive = true
        progress.onScrub = { [weak self] fraction in self?.scrubbed(to: fraction) }
        progress.onSeek = { [weak self] fraction in self?.seek(toFraction: fraction) }
        let timeline = NSStackView(views: [elapsedLabel, progress, durationLabel])
        timeline.orientation = .horizontal
        timeline.alignment = .centerY
        timeline.spacing = 6

        let previous = mediaButton("backward.fill", "Previous", #selector(previousTrack), size: 13)
        configure(playButton, symbol: "play.fill", tooltip: "Play / Pause", action: #selector(togglePlayback), size: 18)
        let next = mediaButton("forward.fill", "Next", #selector(nextTrack), size: 13)
        previousButton = previous
        nextButton = next
        configure(modeButton, symbol: "repeat", tooltip: "Play mode", action: #selector(cyclePlayMode), size: 12)
        configure(likeButton, symbol: "heart", tooltip: "Like", action: #selector(toggleLike), size: 13)
        let controls = NSStackView(views: [modeButton, previous, playButton, next, likeButton])
        controls.orientation = .horizontal
        controls.spacing = 18

        player.orientation = .vertical
        player.alignment = .centerX
        player.spacing = 10
        for view in [header, timeline, controls] { player.addArrangedSubview(view) }
        header.widthAnchor.constraint(equalTo: player.widthAnchor).isActive = true
        timeline.widthAnchor.constraint(equalTo: player.widthAnchor).isActive = true
        player.translatesAutoresizingMaskIntoConstraints = false
        player.widthAnchor.constraint(equalToConstant: Self.columnWidth).isActive = true

        tasksBox.orientation = .vertical
        tasksBox.alignment = .leading
        tasksBox.spacing = 5
        side.orientation = .vertical
        side.alignment = .leading
        side.spacing = 8
        let taskHeader = NSTextField(labelWithString: "To-dos")
        taskHeader.font = .systemFont(ofSize: 10, weight: .semibold)
        taskHeader.textColor = NSColor(white: 1, alpha: 0.45)
        side.addArrangedSubview(taskHeader)
        // The to-dos scroll (trackpad or wheel) once there are more than fit.
        let document = FlippedView()
        document.translatesAutoresizingMaskIntoConstraints = false
        tasksBox.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(tasksBox)
        tasksScroll.documentView = document
        tasksScroll.drawsBackground = false
        tasksScroll.hasVerticalScroller = true
        tasksScroll.autohidesScrollers = true
        tasksScroll.scrollerStyle = .legacy
        tasksScroll.verticalScroller = SlimScroller()
        tasksScroll.translatesAutoresizingMaskIntoConstraints = false
        side.addArrangedSubview(tasksScroll)
        tasksHeight = tasksScroll.heightAnchor.constraint(equalToConstant: 22)
        NSLayoutConstraint.activate([
            tasksHeight,
            tasksScroll.widthAnchor.constraint(equalTo: side.widthAnchor),
            document.topAnchor.constraint(equalTo: tasksScroll.contentView.topAnchor),
            document.leadingAnchor.constraint(equalTo: tasksScroll.contentView.leadingAnchor),
            document.trailingAnchor.constraint(equalTo: tasksScroll.contentView.trailingAnchor),
            tasksBox.topAnchor.constraint(equalTo: document.topAnchor),
            tasksBox.leadingAnchor.constraint(equalTo: document.leadingAnchor),
            tasksBox.trailingAnchor.constraint(equalTo: document.trailingAnchor, constant: -10),
            tasksBox.bottomAnchor.constraint(equalTo: document.bottomAnchor)
        ])
        side.translatesAutoresizingMaskIntoConstraints = false
        sideWidth = side.widthAnchor.constraint(equalToConstant: Self.columnWidth)
        sideWidth.isActive = true

        divider.wantsLayer = true
        divider.layer?.backgroundColor = NSColor(white: 1, alpha: 0.12).cgColor
        divider.translatesAutoresizingMaskIntoConstraints = false
        dividerWidth = divider.widthAnchor.constraint(equalToConstant: 1)
        dividerHeight = divider.heightAnchor.constraint(equalToConstant: 1)

        card.spacing = 16
        for view in [player, divider, side] { card.addArrangedSubview(view) }
    }

    private func configure(_ button: NSButton, symbol: String, tooltip: String, action: Selector, size: CGFloat) {
        let config = NSImage.SymbolConfiguration(pointSize: size, weight: .semibold)
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: tooltip)?
            .withSymbolConfiguration(config)
        button.imagePosition = .imageOnly
        button.isBordered = false
        button.contentTintColor = .white
        button.toolTip = tooltip
        button.target = self
        button.action = action
        button.translatesAutoresizingMaskIntoConstraints = false
        button.widthAnchor.constraint(equalToConstant: 28).isActive = true
        button.heightAnchor.constraint(equalToConstant: 24).isActive = true
    }

    private func mediaButton(_ symbol: String, _ tooltip: String, _ action: Selector, size: CGFloat) -> NSButton {
        let button = NSButton()
        configure(button, symbol: symbol, tooltip: tooltip, action: action, size: size)
        return button
    }

    // MARK: State → views

    /// 0 = spinning cover + bars, 1 = lyrics, 2 = static icon.
    private var mediaStyle: Int { Prefs.int("dock.mediaStyle", 0) }

    private var playing: MediaObserver.NowPlaying? {
        guard let current = MediaObserver.shared.current, current.hasContent else { return nil }
        return current
    }

    private var isLive: Bool {
        mediaStyle != 2 && playing != nil && (playing?.isPlaying == true || Self.debugForceLive)
    }

    /// The pill shows while media plays, except with the home page open:
    /// that page has the player itself, so the pill folds back to a ball.
    private var showsPill: Bool { isLive && !(expanded && page == .home) }

    /// Player length: length of the pill shown while media plays (user setting).
    private var pillWidth: CGFloat {
        CGFloat(min(max(Prefs.int("dock.pillWidth", 300), 84), 800))
    }

    /// Below this the pill only has room for the cover and the bars.
    private var pillShowsText: Bool { pillWidth >= 140 }

    private var collapsedSize: NSSize {
        guard showsPill else { return NSSize(width: Self.iconSize, height: Self.iconSize) }
        return NSSize(width: pillWidth, height: Self.iconSize)
    }

    private func refresh() {
        let media = playing
        let live = isLive
        let liveChanged = shownLive.map { $0 != live } ?? false
        shownLive = live

        // Ball / pill
        disc.image = live ? (media?.artwork ?? iconImage) : iconImage
        disc.isSpinning = live
        compactBars.isAnimating = live
        if !transitioning { applyBallContent() }

        // Player column
        if let media, Prefs.bool("dock.showMedia", true) {
            player.isHidden = false
            titleLabel.stringValue = media.title.isEmpty ? "Unknown track" : media.title
            artistLabel.stringValue = [media.artist, media.appName].filter { !$0.isEmpty }.joined(separator: " · ")
            artwork.image = media.artwork ?? NSImage(systemSymbolName: "music.note", accessibilityDescription: nil)
            artworkHolder.layer?.shadowColor = (media.artwork.flatMap(Self.averageColor) ?? .black).cgColor
            let config = NSImage.SymbolConfiguration(pointSize: 18, weight: .semibold)
            // Pause while anything plays: pressed again it pauses the other player.
            let anyPlaying = media.isPlaying || !media.othersPlaying.isEmpty
            playButton.image = NSImage(systemSymbolName: anyPlaying ? "pause.fill" : "play.fill",
                                       accessibilityDescription: nil)?.withSymbolConfiguration(config)
            cardBars.isAnimating = media.isPlaying
            cardBars.alphaValue = media.isPlaying ? 1 : 0.35
            let mode = MediaObserver.playMode(of: media)
            let modeSymbol = ["order": "repeat", "repeatOne": "repeat.1", "shuffle": "shuffle"][mode.rawValue] ?? "repeat"
            modeButton.image = NSImage(systemSymbolName: modeSymbol, accessibilityDescription: "Play mode")?
                .withSymbolConfiguration(.init(pointSize: 12, weight: .semibold))
            modeButton.toolTip = ["order": "Play mode: in order", "repeatOne": "Play mode: repeat one",
                                  "shuffle": "Play mode: shuffle"][mode.rawValue]
            modeButton.contentTintColor = mode == .order ? NSColor(white: 1, alpha: 0.7) : .white
            let liked = media.liked ?? false
            likeButton.image = NSImage(systemSymbolName: liked ? "heart.fill" : "heart", accessibilityDescription: "Like")?
                .withSymbolConfiguration(.init(pointSize: 13, weight: .semibold))
            likeButton.contentTintColor = liked ? NSColor(srgbRed: 1, green: 0.36, blue: 0.48, alpha: 1) : NSColor(white: 1, alpha: 0.7)
            likeButton.toolTip = liked ? "Unlike" : "Like"
            // Controls the player cannot take are dimmed; the tip says why.
            for (button, control) in [(modeButton, MediaObserver.Control.playMode), (likeButton, .like)] {
                if case .unavailable(let reason) = MediaObserver.shared.route(control, for: media) {
                    button.alphaValue = 0.35
                    button.toolTip = reason
                } else {
                    button.alphaValue = 1
                }
            }
            // A followed player (another app holds Now Playing) takes no commands.
            let followed = MediaObserver.followedReason(media)
            for (button, tip) in [(previousButton, "Previous"), (playButton, "Play / Pause"), (nextButton, "Next")] {
                button.alphaValue = followed == nil ? 1 : 0.35
                button.toolTip = followed ?? tip
            }
            if let note = controlNote, note.until > Date() {
                artistLabel.stringValue = note.text
                artistLabel.textColor = NSColor(srgbRed: 1, green: 0.78, blue: 0.4, alpha: 1)
            } else {
                artistLabel.textColor = NSColor(white: 1, alpha: 0.6)
            }
        } else {
            player.isHidden = true
            cardBars.isAnimating = false
        }

        // To-dos
        for view in tasksBox.arrangedSubviews {
            tasksBox.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        let all = TaskStore.shared.active
        if all.isEmpty {
            let empty = NSTextField(labelWithString: "No to-dos")
            empty.font = .systemFont(ofSize: 12)
            empty.textColor = NSColor(white: 1, alpha: 0.4)
            tasksBox.addArrangedSubview(empty)
        } else {
            for task in all {
                let row = DockTaskRow(task: task)
                row.onOpen = { [weak self] id in self?.openTask(id) }
                row.translatesAutoresizingMaskIntoConstraints = false
                tasksBox.addArrangedSubview(row)
                row.widthAnchor.constraint(equalTo: tasksBox.widthAnchor).isActive = true
            }
        }
        // Up to "Show on Home" rows are visible; the rest scroll.
        let visibleRows = max(1, Prefs.int("dock.taskLimit", 5))
        let rowHeight: CGFloat = 22, spacing = tasksBox.spacing
        let shown = CGFloat(max(1, min(all.count, visibleRows)))
        tasksHeight.constant = shown * rowHeight + (shown - 1) * spacing
        tasksScroll.verticalScroller?.isHidden = all.count <= visibleRows

        holidayLabel.stringValue = Holidays.countdownText()
        tickPlayback(force: true)
        if !dragging {
            if liveChanged, canMorphBall { morphBall() } else { applyGeometry() }
        }
        // "Show dock" switched off in settings takes effect once the card is closed.
        if Prefs.bool("dock.hidden"), !expanded, isVisible { orderOut(nil) }
    }

    /// While the progress bar is dragged the elapsed time follows the pointer.
    private func scrubbed(to fraction: CGFloat) {
        guard let media = playing, media.duration > 0 else { return }
        elapsedLabel.stringValue = Self.clock(Double(fraction) * media.duration)
    }

    /// A click or drag on the progress bar ended: play from there.
    private func seek(toFraction fraction: CGFloat) {
        guard let media = playing, media.duration > 0 else { return }
        MediaObserver.shared.seek(to: Double(fraction) * media.duration)
        tickPlayback(force: true)
    }

    /// Lyric line + progress; cheap enough to run on every poll tick.
    private func tickPlayback(force: Bool = false) {
        guard isVisible || force, let media = playing else {
            if !lastLyric.isEmpty { lastLyric = "" }
            return
        }
        let position = media.position()

        // Lyrics are only looked up when something shows them.
        var line = ""
        if mediaStyle == 1, let position,
           let lines = LyricsProvider.shared.lines(title: media.title, artist: media.artist,
                                                         duration: media.duration) {
            line = LyricsProvider.current(in: lines, at: position) ?? ""
        }
        if line != lastLyric || force {
            lastLyric = line
            let fallback = [media.title, media.artist].filter { !$0.isEmpty }.joined(separator: " — ")
            compactLabel.text = line.isEmpty ? fallback : line
            lyricLabel.stringValue = line
            let wasHidden = lyricLabel.isHidden
            lyricLabel.isHidden = line.isEmpty
            if expanded, page == .home, !dragging, wasHidden != lyricLabel.isHidden, !force { applyGeometry() }
        }

        guard expanded, page == .home else { return }
        progress.isSeekable = position != nil && media.duration > 0
        // While the bar is dragged it shows where the pointer is, not the player.
        if progress.isScrubbing { return }
        if let position, media.duration > 0 {
            progress.fraction = CGFloat(position / media.duration)
            elapsedLabel.stringValue = Self.clock(position)
            durationLabel.stringValue = Self.clock(media.duration)
        } else {
            progress.fraction = 0
            elapsedLabel.stringValue = "--:--"
            durationLabel.stringValue = "--:--"
        }
    }

    /// Average colour of a picture, brightened a little — the tint of the
    /// shadow under the cover.
    private static func averageColor(_ image: NSImage) -> NSColor? {
        var rect = NSRect(origin: .zero, size: image.size)
        guard let cgImage = image.cgImage(forProposedRect: &rect, context: nil, hints: nil) else { return nil }
        var pixel = [UInt8](repeating: 0, count: 4)
        guard let ctx = CGContext(data: &pixel, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        ctx.interpolationQuality = .medium
        ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        let color = NSColor(srgbRed: CGFloat(pixel[0]) / 255, green: CGFloat(pixel[1]) / 255,
                            blue: CGFloat(pixel[2]) / 255, alpha: 1)
        return color.blended(withFraction: 0.25, of: .white) ?? color
    }

    private static func clock(_ seconds: Double) -> String {
        let total = Int(seconds.rounded(.down))
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    // MARK: Icon

    private static var customIconURL: URL { Store.url("dock-icon") }

    /// Copies the chosen image into Application Support so the icon survives
    /// the original file being moved or deleted.
    static func setCustomIcon(from url: URL) -> Bool {
        guard let data = try? Data(contentsOf: url), NSImage(data: data) != nil else { return false }
        do { try data.write(to: customIconURL, options: .atomic) } catch { return false }
        Prefs.set("dock.iconPath", customIconURL.path)
        reloadIcon()
        return true
    }

    static func resetIcon() {
        try? FileManager.default.removeItem(at: customIconURL)
        Prefs.set("dock.iconPath", "")
        reloadIcon()
    }

    static func chooseIcon() {
        NSApp.activate(ignoringOtherApps: true)
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        panel.message = "Choose a dock icon (any image)"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        if !setCustomIcon(from: url) {
            Toast.show("Cannot read this image", duration: 2)
        }
    }

    private func applyIcon() {
        let path = Prefs.string("dock.iconPath")
        var image: NSImage?
        if !path.isEmpty, let data = try? Data(contentsOf: URL(fileURLWithPath: path)) {
            image = NSImage(data: data)
        }
        // Default: Lan's avatar (falls back to the drawn icon
        // when the artwork was not bundled).
        iconImage = image ?? Artwork.avatar ?? Self.defaultIcon()
        refresh()
    }

    /// Round fallback icon: gradient disc, selection brackets, a small card
    /// with the orange pin. Drawn in code so it stays crisp.
    private static func defaultIcon() -> NSImage {
        NSImage(size: NSSize(width: 40, height: 40), flipped: false) { rect in
            let disc = NSBezierPath(ovalIn: rect)
            NSGradient(colors: [NSColor(srgbRed: 0.49, green: 0.30, blue: 1.0, alpha: 1),
                                NSColor(srgbRed: 0.31, green: 0.42, blue: 1.0, alpha: 1),
                                NSColor(srgbRed: 0.09, green: 0.78, blue: 0.88, alpha: 1)])?
                .draw(in: disc, angle: -45)

            let frame = rect.insetBy(dx: 10.5, dy: 10.5)
            let arm: CGFloat = 5
            let brackets = NSBezierPath()
            brackets.lineWidth = 2.4
            brackets.lineCapStyle = .round
            brackets.lineJoinStyle = .round
            for (x, y, dx, dy) in [(frame.minX, frame.maxY, 1.0, -1.0), (frame.maxX, frame.maxY, -1.0, -1.0),
                                   (frame.minX, frame.minY, 1.0, 1.0), (frame.maxX, frame.minY, -1.0, 1.0)] {
                brackets.move(to: NSPoint(x: x + arm * dx, y: y))
                brackets.line(to: NSPoint(x: x, y: y))
                brackets.line(to: NSPoint(x: x, y: y + arm * dy))
            }
            NSColor.white.setStroke()
            brackets.stroke()

            let card = NSRect(x: rect.midX - 5.5, y: rect.midY - 4.2, width: 11, height: 8.4)
            NSColor.white.setFill()
            NSBezierPath(roundedRect: card, xRadius: 2, yRadius: 2).fill()
            NSColor(srgbRed: 1.0, green: 0.55, blue: 0.28, alpha: 1).setFill()
            NSBezierPath(ovalIn: NSRect(x: card.maxX - 2.4, y: card.maxY - 2.4, width: 4.8, height: 4.8)).fill()
            return true
        }
    }

    // MARK: Geometry

    enum Edge: String { case left, right, top, bottom }

    private var dockScreen: NSScreen {
        screen ?? NSScreen.main ?? NSScreen.screens[0]
    }

    /// Older versions stored "edge + offset along it"; carry that over once.
    private func migratePosition() {
        guard UserDefaults.standard.object(forKey: "dock.posX") == nil else { return }
        let offset = min(max(Prefs.double("dock.offset", 0.5), 0), 1)
        let (x, y): (Double, Double)
        switch Prefs.string("dock.edge", "right") {
        case "left": (x, y) = (0, offset)
        case "top": (x, y) = (offset, 1)
        case "bottom": (x, y) = (offset, 0)
        default: (x, y) = (1, offset)
        }
        Prefs.set("dock.posX", x)
        Prefs.set("dock.posY", y)
    }

    /// Where the centre of the round icon sits. Stored as a fraction of the
    /// usable screen area, so it can rest anywhere — not only on an edge.
    private var anchor: NSPoint {
        let visible = dockScreen.visibleFrame
        let half = Self.iconSize / 2 + 8
        let fx = CGFloat(min(max(Prefs.double("dock.posX", 1), 0), 1))
        let fy = CGFloat(min(max(Prefs.double("dock.posY", 0.5), 0), 1))
        return NSPoint(x: visible.minX + half + (visible.width - half * 2) * fx,
                       y: visible.minY + half + (visible.height - half * 2) * fy)
    }

    /// The screen edge the ball is closest to — the card opens on the
    /// opposite side of the ball.
    private var nearestEdge: Edge {
        let visible = dockScreen.visibleFrame
        let point = anchor
        let distances: [(Edge, CGFloat)] = [
            (.top, visible.maxY - point.y), (.bottom, point.y - visible.minY),
            (.left, point.x - visible.minX), (.right, visible.maxX - point.x)
        ]
        return distances.min { $0.1 < $1.1 }?.0 ?? .right
    }

    /// Ball near the top or bottom: entry icons in a row along the top of
    /// the card, home page laid out side by side. Near the left or right:
    /// icons in a column on that side, home page stacked.
    private var isHorizontal: Bool { nearestEdge == .top || nearestEdge == .bottom }

    private static let padding: CGFloat = 14
    private static let stripHeight: CGFloat = 28
    private static let navColumn: CGFloat = 32

    private func pageView(_ target: Page) -> NSView {
        switch target {
        case .home: return card
        case .activity: return activity
        case .terminal: return ensureTerminal()
        case .clipboard: return clipboardPane
        case .shelf: return shelfPane
        case .tasks: return agendaPane
        case .settings: return settingsPane
        }
    }

    @discardableResult
    private func ensureTerminal() -> TerminalPane {
        terminalCreated = true
        return terminalPane
    }

    /// Width of every page's content when the card opens above / below the
    /// ball (and of all but Home and Activity beside it). Settings → Dock.
    static var cardContentWidth: CGFloat {
        CGFloat(min(max(Prefs.int("dock.cardWidth", defaultCardWidth), 480), 1100))
    }
    /// Home above / below the ball: player + divider + to-dos.
    static let defaultCardWidth = Int(columnWidth * 2 + 33)

    /// Puts the current page into the card and returns the size it needs.
    private func installPage() -> NSSize {
        let horizontal = isHorizontal
        let view = pageView(page)
        if shownPage !== view {
            (shownPage as? DockPage)?.pageDidDisappear()
            shownPage?.removeFromSuperview()
            view.translatesAutoresizingMaskIntoConstraints = false
            pageHost.addSubview(view)
            NSLayoutConstraint.activate([
                view.topAnchor.constraint(equalTo: pageHost.topAnchor),
                view.leadingAnchor.constraint(equalTo: pageHost.leadingAnchor)
            ])
            shownPage = view
            pageWidth?.isActive = false
            pageHeight?.isActive = false
            pageWidth = nil
            pageHeight = nil
            (view as? DockPage)?.pageWillAppear()
        }

        switch page {
        case .home:
            card.orientation = horizontal ? .horizontal : .vertical
            card.alignment = horizontal ? .top : .leading
            divider.isHidden = player.isHidden
            dividerWidth.isActive = false
            dividerHeight.isActive = false
            if horizontal {
                // As wide as every other page: the to-do column takes the rest.
                sideWidth.constant = player.isHidden ? Self.cardContentWidth
                    : Self.cardContentWidth - Self.columnWidth - 2 * card.spacing - 1
                dividerWidth.constant = 1
                dividerHeight.constant = max(60, max(player.fittingSize.height, side.fittingSize.height))
            } else {
                sideWidth.constant = Self.columnWidth
                dividerWidth.constant = Self.columnWidth
                dividerHeight.constant = 1
            }
            dividerWidth.isActive = true
            dividerHeight.isActive = true
            card.layoutSubtreeIfNeeded()
            return card.fittingSize
        case .activity:
            activity.setWidth(horizontal ? Self.cardContentWidth : Self.columnWidth + 20)
            activity.layoutSubtreeIfNeeded()
            return activity.fittingSize
        default:
            var size = (view as? DockPage)?.preferredSize(horizontal: horizontal) ?? NSSize(width: 500, height: 360)
            size.width = Self.cardContentWidth
            if pageWidth == nil {
                pageWidth = view.widthAnchor.constraint(equalToConstant: size.width)
                pageHeight = view.heightAnchor.constraint(equalToConstant: size.height)
                pageWidth?.isActive = true
                pageHeight?.isActive = true
            }
            pageWidth?.constant = size.width
            pageHeight?.constant = size.height
            return size
        }
    }

    /// Lays the card's chrome and page out for `content` and returns the
    /// card's size.
    private func layoutCard(content: NSSize) -> NSSize {
        let pad = Self.padding
        let horizontal = isHorizontal
        let navOnRight = nearestEdge == .right
        // The row of entry icons needs this much even under a narrow page.
        let icons = CGFloat(Page.allCases.filter(Page.isShown).count)
        let minWidth: CGFloat = horizontal ? icons * 32 + (icons - 1) * 4 + 170 : 0
        let contentWidth = max(content.width, minWidth)
        let sideNav = horizontal ? 0 : Self.navColumn + 10
        let size = NSSize(width: pad * 2 + sideNav + contentWidth,
                          height: pad + Self.stripHeight + 8 + max(content.height, horizontal ? 0 : icons * 28 + (icons - 1) * 4 + 12) + pad)

        cardView.frame.size = size
        backdrop.frame = NSRect(origin: .zero, size: size)
        shade.frame = backdrop.frame
        // Pages full of controls get a heavier veil than the two glanceable ones.
        shade.layer?.backgroundColor = NSColor(srgbRed: 0.05, green: 0.05, blue: 0.10, alpha: Self.dim(for: page)).cgColor

        for (key, button) in navButtons { button.isHidden = !Page.isShown(key) }
        nav.orientation = horizontal ? .horizontal : .vertical
        navTrailing.orientation = nav.orientation
        let navSize = nav.fittingSize
        let trailingSize = navTrailing.fittingSize
        let contentTop = pad + Self.stripHeight + 8
        var holidayRight = size.width - pad
        if horizontal {
            nav.frame = NSRect(x: pad, y: pad, width: navSize.width, height: Self.stripHeight)
            navTrailing.frame = NSRect(x: size.width - pad - trailingSize.width, y: pad,
                                       width: trailingSize.width, height: Self.stripHeight)
            holidayRight = navTrailing.frame.minX
            pageTitle.isHidden = true
            pageHost.frame = NSRect(x: pad, y: contentTop, width: contentWidth, height: content.height)
        } else {
            pageTitle.isHidden = false
            pageTitle.stringValue = page.title
            pageTitle.sizeToFit()
            let contentX = navOnRight ? pad : pad + sideNav
            pageTitle.frame.origin = NSPoint(x: contentX, y: pad + (Self.stripHeight - pageTitle.frame.height) / 2)
            let navX = navOnRight ? size.width - pad - Self.navColumn : pad
            nav.frame = NSRect(x: navX, y: contentTop, width: Self.navColumn, height: navSize.height)
            // Clipboard and Settings sit at the bottom of the column.
            navTrailing.frame = NSRect(x: navX, y: size.height - pad - trailingSize.height,
                                       width: Self.navColumn, height: trailingSize.height)
            pageHost.frame = NSRect(x: contentX, y: contentTop, width: contentWidth, height: content.height)
        }
        holidayLabel.isHidden = !(page == .home && Prefs.bool("dock.showHoliday", true)) || holidayLabel.stringValue.isEmpty
        holidayLabel.sizeToFit()
        holidayLabel.frame.origin = NSPoint(x: holidayRight - 10 - holidayLabel.frame.width,
                                            y: pad + (Self.stripHeight - holidayLabel.frame.height) / 2)
        // Clicks on the entry icons' row (also the gaps around them) never
        // fold the card.
        cardView.headerExclusions = [nav.frame.insetBy(dx: -6, dy: -6), navTrailing.frame.insetBy(dx: -6, dy: -6)]
        for (key, button) in navButtons {
            let selected = key == page
            button.layer?.backgroundColor = NSColor(white: 1, alpha: selected ? 0.20 : 0).cgColor
            button.contentTintColor = selected ? .white : NSColor(white: 1, alpha: 0.7)
        }
        return size
    }

    /// Screen rectangles for the current state, derived only from the stored
    /// anchor — never from the current frame, so nothing can drift.
    private func geometry() -> (window: NSRect, ball: NSRect, card: NSRect?) {
        let visible = dockScreen.visibleFrame
        let inset: CGFloat = 8
        func clamp(_ rect: NSRect) -> NSRect {
            var rect = rect
            rect.origin.x = max(visible.minX + inset, min(rect.origin.x, visible.maxX - rect.width - inset))
            rect.origin.y = max(visible.minY + inset, min(rect.origin.y, visible.maxY - rect.height - inset))
            return rect
        }
        let point = anchor
        let ballSize = collapsedSize
        let ballRect = clamp(NSRect(x: point.x - ballSize.width / 2, y: point.y - ballSize.height / 2,
                                    width: ballSize.width, height: ballSize.height))
        guard expanded else { return (ballRect, ballRect, nil) }

        let size = layoutCard(content: installPage())
        var cardRect = NSRect(origin: .zero, size: size)
        // The card opens on the side of the ball that faces the screen.
        switch nearestEdge {
        case .top:
            cardRect.origin = NSPoint(x: ballRect.midX - size.width / 2, y: ballRect.minY - Self.gap - size.height)
        case .bottom:
            cardRect.origin = NSPoint(x: ballRect.midX - size.width / 2, y: ballRect.maxY + Self.gap)
        case .left:
            cardRect.origin = NSPoint(x: ballRect.maxX + Self.gap, y: ballRect.midY - size.height / 2)
        case .right:
            cardRect.origin = NSPoint(x: ballRect.minX - Self.gap - size.width, y: ballRect.midY - size.height / 2)
        }
        cardRect = clamp(cardRect)
        return (ballRect.union(cardRect), ballRect, cardRect)
    }

    /// Moves the window and the two views inside it to where they belong.
    private func applyGeometry() {
        // A zoom in flight puts the views back itself when it ends.
        guard !transitioning else { return }
        let (window, ballRect, cardRect) = geometry()
        setFrame(window, display: false)
        ball.frame = ballRect.offsetBy(dx: -window.minX, dy: -window.minY)
        ball.layer?.cornerRadius = Self.iconSize / 2
        applyBallContent()
        layoutBall()
        if let cardRect {
            cardView.frame = cardRect.offsetBy(dx: -window.minX, dy: -window.minY)
            cardView.isHidden = false
        } else {
            cardView.isHidden = true
        }
        contentView?.needsDisplay = true
        displayIfNeeded()
        invalidateShadow()
    }

    /// Pill: cover on the left, bars on the right, text between.
    /// `inset` and `labelRoom` (pill width the text is laid out for) are
    /// set while the ball turns into the pill or back.
    private func layoutBall(inset: CGFloat? = nil, labelRoom: CGFloat? = nil) {
        let size = ball.bounds.size
        let inset = inset ?? (showsPill ? Self.pillCoverInset : 0)
        disc.frame = NSRect(x: inset, y: inset, width: size.height - inset * 2, height: size.height - inset * 2)
        compactBars.frame = NSRect(x: size.width - 30, y: 11, width: 18, height: 18)
        compactLabel.frame = NSRect(x: size.height + 6, y: (size.height - 18) / 2,
                                    width: max(0, (labelRoom ?? size.width) - size.height - 6 - 38), height: 18)
    }

    // MARK: Ball <-> pill
    //
    // The ball stretches into the pill (or the pill draws back into the
    // ball) instead of jumping: when music starts or stops, and when the
    // home page opens or closes while it plays. The cover settles into its
    // inset, and the line of text and the bars fade in once there is room
    // (out before it is gone).

    private static let pillMorphDuration: TimeInterval = 0.42
    private static let pillCoverInset: CGFloat = 4
    /// A ball morph of its own is playing (not one riding along a zoom).
    private var ballMorphing = false

    private var canMorphBall: Bool {
        (!Self.headless || Self.debugAnimateBall) && isVisible && !dragging
            && (!transitioning || ballMorphing)
    }

    private struct BallMorph {
        let stage: NSRect
        let from: NSRect
        let to: NSRect
        let toPill: Bool
        /// The open card, moved along when the ball's size moves it.
        var fromCard: NSRect? = nil
        var toCard: NSRect? = nil
    }

    /// Bars, text and rim as the current state wants them.
    private func applyBallContent() {
        let pill = showsPill
        compactBars.alphaValue = 1
        compactLabel.alphaValue = 1
        compactBars.isHidden = !pill
        compactLabel.isHidden = !(pill && pillShowsText)
        ball.layer?.borderWidth = pill ? 1 : 0
    }

    /// Ease in and out: the size picks up, then settles.
    private static func pillEase(_ t: CGFloat) -> CGFloat {
        t < 0.5 ? 4 * t * t * t : 1 - pow(-2 * t + 2, 3) / 2
    }

    /// Close to the zooms' curve, so a ball riding along keeps pace.
    private static func zoomPace(_ t: CGFloat) -> CGFloat { 1 - pow(1 - t, 5) }

    private static func mix(_ a: NSRect, _ b: NSRect, _ t: CGFloat) -> NSRect {
        NSRect(x: a.minX + (b.minX - a.minX) * t, y: a.minY + (b.minY - a.minY) * t,
               width: a.width + (b.width - a.width) * t, height: a.height + (b.height - a.height) * t)
    }

    /// Ball and its content at eased progress `t` (0...1).
    private func layoutBallMorph(_ morph: BallMorph, at t: CGFloat) {
        ball.frame = Self.mix(morph.from, morph.to, t).offsetBy(dx: -morph.stage.minX, dy: -morph.stage.minY)
        let toward = morph.toPill ? t : 1 - t
        layoutBall(inset: Self.pillCoverInset * toward, labelRoom: max(morph.from.width, morph.to.width))
        let alpha = morph.toPill ? min(1, max(0, (t - 0.35) / 0.65)) : max(0, 1 - t / 0.5)
        compactBars.alphaValue = alpha
        compactLabel.alphaValue = alpha
        if let fromCard = morph.fromCard, let toCard = morph.toCard {
            cardView.frame = Self.mix(fromCard, toCard, t).offsetBy(dx: -morph.stage.minX, dy: -morph.stage.minY)
        }
    }

    /// Bars and text shown (faded by the morph), rim on, first frame placed.
    private func beginBallMorph(_ morph: BallMorph, at t: CGFloat = 0) {
        compactBars.isHidden = false
        compactLabel.isHidden = !pillShowsText
        ball.layer?.borderWidth = 1
        layoutBallMorph(morph, at: t)
    }

    /// Steps a morph until it lands (or a newer transition takes over).
    private func playBallMorph(_ morph: BallMorph, duration: TimeInterval, ease: @escaping (CGFloat) -> CGFloat,
                               generation mine: Int, landed: @escaping () -> Void) {
        let start = CACurrentMediaTime()
        let timer = Timer(timeInterval: 1.0 / 120, repeats: true) { [weak self] timer in
            guard let self, self.animation == mine, self.transitioning else { timer.invalidate(); return }
            let progress = min(1, (CACurrentMediaTime() - start) / duration)
            self.layoutBallMorph(morph, at: ease(CGFloat(progress)))
            self.displayIfNeeded()
            self.invalidateShadow()
            guard progress >= 1 else { return }
            timer.invalidate()
            landed()
        }
        RunLoop.main.add(timer, forMode: .common)
    }

    /// Music started or stopped: the ball takes its new size smoothly.
    private func morphBall() {
        let from = ball.frame.offsetBy(dx: frame.minX, dy: frame.minY)
        let fromCard = expanded && !cardView.isHidden ? cardView.frame.offsetBy(dx: frame.minX, dy: frame.minY) : nil
        let target = geometry()
        guard from.size != target.ball.size else { cancelTransition(); applyGeometry(); return }
        cancelTransition()
        var stage = from.union(target.ball)
        if let fromCard, let toCard = target.card { stage = stage.union(fromCard).union(toCard) }
        let morph = BallMorph(stage: stage, from: from, to: target.ball, toPill: showsPill,
                              fromCard: fromCard, toCard: fromCard == nil ? nil : target.card)
        transitioning = true
        ballMorphing = true
        if morph.fromCard == nil { cardView.isHidden = true }
        setFrame(stage, display: false)
        beginBallMorph(morph)
        displayIfNeeded()
        playBallMorph(morph, duration: Self.pillMorphDuration, ease: Self.pillEase, generation: animation) { [weak self] in
            guard let self else { return }
            self.cancelTransition()
            if !self.dragging { self.applyGeometry() }
        }
    }

    /// A zoom that changes the ball's size (the home page opening or
    /// closing while music plays) takes the ball along.
    private func ridingBall(_ plan: ZoomPlan) -> ZoomPlan {
        let current = ball.frame.offsetBy(dx: frame.minX, dy: frame.minY)
        guard abs(current.width - plan.ballRect.width) > 0.5 else { return plan }
        var plan = plan
        plan.ballFrom = current
        plan.stage = plan.stage.union(current)
        return plan
    }

    private func ballMorph(for plan: ZoomPlan) -> BallMorph? {
        plan.ballFrom.map { BallMorph(stage: plan.stage, from: $0, to: plan.ballRect, toPill: showsPill) }
    }

    /// Test hook: with music playing, the ball's width and whether the
    /// pill's bars show, with `page` open (nil = card closed).
    static func debugBall(page: Page?) -> (width: CGFloat, bars: Bool) {
        let panel = instance()
        if let page { panel.present(page, hold: true, focus: false) } else { panel.closeCard() }
        return (panel.geometry().ball.width, !panel.compactBars.isHidden)
    }

    /// Test hook: music starts, then stops, with the card closed. The ball's
    /// width sampled along each way, the text's opacity half way in, and
    /// the widths of the ball and the pill.
    static func debugPillMorph() -> (grow: [CGFloat], shrink: [CGFloat], midAlpha: CGFloat, ball: CGFloat, pill: CGFloat) {
        let panel = instance()
        panel.cancelTransition()
        panel.closeCard()
        panel.orderFrontRegardless()
        debugAnimateBall = true
        defer { debugAnimateBall = false; panel.orderOut(nil) }
        var song = MediaObserver.NowPlaying()
        song.title = "Morph Song"; song.artist = "Tester"
        func run(playing: Bool) -> (widths: [CGFloat], mid: CGFloat) {
            song.isPlaying = playing
            MediaObserver.shared.debugInject(song)
            panel.refresh()
            var widths: [CGFloat] = [], mid: CGFloat = -1
            let start = Date()
            while Date().timeIntervalSince(start) < pillMorphDuration + 0.2 {
                RunLoop.current.run(until: Date().addingTimeInterval(0.03))
                widths.append(panel.ball.frame.width)
                if mid < 0, Date().timeIntervalSince(start) >= pillMorphDuration * 0.6 { mid = panel.compactLabel.alphaValue }
            }
            return (widths, mid)
        }
        _ = run(playing: false)
        let grow = run(playing: true)
        let shrink = run(playing: false)
        return (grow.widths, shrink.widths, grow.mid, iconSize, panel.pillWidth)
    }

    // MARK: Open / close

    private func present(_ target: Page, hold: Bool, focus: Bool) {
        let canAnimate = !Self.headless && isVisible && !dragging
        // What the card shows now (screen rect + picture), to zoom away from.
        let wasExpanded = expanded && (!cardView.isHidden || transitioning)
        let oldRect = wasExpanded && !cardView.isHidden ? cardView.frame.offsetBy(dx: frame.minX, dy: frame.minY) : nil
        let oldImage = wasExpanded && canAnimate && !transitioning ? cardSnapshot(contentOnly: true) : nil
        let oldPage = page
        if !wasExpanded { openedFrom = ball.frame.offsetBy(dx: frame.minX, dy: frame.minY) }
        cancelTransition()
        page = target
        expanded = true
        heldOpen = hold
        awaySince = nil
        tickPlayback(force: true)
        if !canAnimate {
            applyGeometry()
        } else if !wasExpanded {
            zoomOpen()
        } else if let oldRect, let oldImage, oldPage != target {
            zoomSwitch(from: oldRect, image: oldImage, oldPage: oldPage)
        } else {
            applyGeometry()
        }
        if focus, !Self.headless {
            // Typing needs the keyboard; hand it back when the card closes.
            focused = true
            FocusKeeper.activateSelf()
            makeKeyAndOrderFront(nil)
            if let responder = (shownPage as? DockPage)?.initialResponder { makeFirstResponder(responder) }
        }
        updateHomeKeys()
    }

    // MARK: Zoom transitions
    //
    // The card is pictured (old and new state) and the pictures are scaled
    // around the point that faces the ball, so a bigger page zooms in, a
    // smaller one zooms out, and the card grows out of / falls back into
    // the ball. The live card is shown again once the motion ends.

    private static let zoomEase = CAMediaTimingFunction(controlPoints: 0.16, 1, 0.3, 1)
    private var ghosts: [NSView] = []
    private var transitioning = false

    /// Picture of the card. `contentOnly` leaves out the backdrop and veil,
    /// which a page-to-page morph draws itself (continuously).
    private func cardSnapshot(contentOnly: Bool = false) -> CGImage? {
        // A hidden view draws nothing: show it (the zoom hides it again).
        cardView.isHidden = false
        cardView.layoutSubtreeIfNeeded()
        let bounds = cardView.bounds
        guard bounds.width > 1, bounds.height > 1,
              let rep = cardView.bitmapImageRepForCachingDisplay(in: bounds) else { return nil }
        let background = cardView.layer?.backgroundColor
        if contentOnly {
            backdrop.isHidden = true
            shade.isHidden = true
            cardView.layer?.backgroundColor = NSColor.clear.cgColor
        }
        cardView.cacheDisplay(in: bounds, to: rep)
        if contentOnly {
            backdrop.isHidden = false
            shade.isHidden = false
            cardView.layer?.backgroundColor = background
        }
        return rep.cgImage
    }

    /// Veil over the backdrop: heavier on pages full of controls.
    private static func dim(for page: Page) -> CGFloat {
        (page == .home || page == .activity) ? 0.62 : 0.80
    }

    private func addGhost(_ image: CGImage?, frame rect: NSRect, alpha: CGFloat) -> NSView {
        let ghost = NSView(frame: rect)
        ghost.wantsLayer = true
        ghost.layer?.contents = image
        ghost.layer?.contentsGravity = .resize
        ghost.layer?.cornerRadius = 20
        ghost.layer?.masksToBounds = true
        ghost.alphaValue = alpha
        contentView?.addSubview(ghost)
        ghosts.append(ghost)
        return ghost
    }

    private func cancelTransition() {
        animation += 1
        ghosts.forEach { $0.removeFromSuperview() }
        ghosts = []
        transitioning = false
        cardView.alphaValue = 1
        ballMorphing = false
        applyBallContent()
    }

    private static func scaled(_ rect: NSRect, by scale: CGFloat, about point: NSPoint) -> NSRect {
        NSRect(x: point.x + (rect.minX - point.x) * scale, y: point.y + (rect.minY - point.y) * scale,
               width: rect.width * scale, height: rect.height * scale)
    }

    /// The point of a card nearest the ball's centre.
    private static func anchor(of rect: NSRect, ball: NSRect) -> NSPoint {
        NSPoint(x: min(max(ball.midX, rect.minX), rect.maxX), y: min(max(ball.midY, rect.minY), rect.maxY))
    }

    /// One picture of the card moving from one screen rect to another.
    private struct ZoomPart {
        let image: CGImage?
        let from: NSRect
        let to: NSRect
        let alphaFrom: CGFloat
        let alphaTo: CGFloat
    }

    /// Page to page: one solid card whose frame stretches or shrinks from
    /// the old page's rect to the new one, backdrop and veil drawn the whole
    /// way, while the old page's content fades out and the new one's in.
    private struct Morph {
        let from: NSRect
        let to: NSRect
        let oldContent: CGImage?
        let newContent: CGImage?
        let dimFrom: CGFloat
        let dimTo: CGFloat
        /// Content stays pinned to the top corner on the ball's side.
        let anchorRight: Bool
    }

    /// Everything a zoom needs: the window it plays in and the pictures.
    private struct ZoomPlan {
        var stage: NSRect
        let ballRect: NSRect
        let parts: [ZoomPart]
        var morph: Morph? = nil
        /// Where the ball starts when the zoom also changes its size.
        var ballFrom: NSRect? = nil
    }

    /// The card grows out of the ball.
    private func openPlan() -> ZoomPlan? {
        let (window, ballRect, cardRect) = geometry()
        guard let cardRect, let image = cardSnapshot() else { return nil }
        let center = NSPoint(x: ballRect.midX, y: ballRect.midY)
        let start = Self.scaled(cardRect, by: 0.08, about: center)
        return ZoomPlan(stage: window.union(start), ballRect: ballRect,
                        parts: [ZoomPart(image: image, from: start, to: cardRect, alphaFrom: 0, alphaTo: 1)])
    }

    private func switchPlan(from oldRect: NSRect, image oldImage: CGImage, oldPage: Page) -> ZoomPlan? {
        let (window, ballRect, cardRect) = geometry()
        guard let cardRect, let newImage = cardSnapshot(contentOnly: true) else { return nil }
        let morph = Morph(from: oldRect, to: cardRect, oldContent: oldImage, newContent: newImage,
                          dimFrom: Self.dim(for: oldPage), dimTo: Self.dim(for: page),
                          anchorRight: ballRect.minX >= cardRect.maxX - 1)
        return ZoomPlan(stage: window.union(oldRect), ballRect: ballRect, parts: [], morph: morph)
    }

    /// The card falls back into the ball.
    private func closePlan(from cardRect: NSRect, image: CGImage) -> ZoomPlan {
        let (window, ballRect, _) = geometry()
        let center = NSPoint(x: ballRect.midX, y: ballRect.midY)
        let end = Self.scaled(cardRect, by: 0.08, about: center)
        return ZoomPlan(stage: window.union(cardRect), ballRect: ballRect,
                        parts: [ZoomPart(image: image, from: cardRect, to: end, alphaFrom: 1, alphaTo: 0)])
    }

    /// Puts the window on the plan's stage and the pictures at progress
    /// `t` (0…1); returns the pictures.
    @discardableResult
    private func stageZoom(_ plan: ZoomPlan, at t: CGFloat = 0) -> [NSView] {
        transitioning = true
        cardView.isHidden = true
        setFrame(plan.stage, display: false)
        ball.frame = plan.ballRect.offsetBy(dx: -plan.stage.minX, dy: -plan.stage.minY)
        layoutBall()
        if let ride = ballMorph(for: plan) { beginBallMorph(ride, at: t) }
        func mix(_ a: CGFloat, _ b: CGFloat) -> CGFloat { a + (b - a) * t }
        if let morph = plan.morph {
            let views = makeMorphViews(morph)
            layoutMorph(views, morph, stage: plan.stage, at: t)
            return [views.card]
        }
        return plan.parts.map { part in
            let rect = NSRect(x: mix(part.from.minX, part.to.minX), y: mix(part.from.minY, part.to.minY),
                              width: mix(part.from.width, part.to.width), height: mix(part.from.height, part.to.height))
            return addGhost(part.image, frame: rect.offsetBy(dx: -plan.stage.minX, dy: -plan.stage.minY),
                            alpha: mix(part.alphaFrom, part.alphaTo))
        }
    }

    /// Plays a plan; when it ends the real views come back for the state
    /// reached by then.
    private func runZoom(_ plan: ZoomPlan?, duration: TimeInterval, done: (() -> Void)? = nil) {
        guard let plan = plan.map(ridingBall) else { applyGeometry(); done?(); return }
        let mine = animation
        if let morph = plan.morph {
            runMorph(morph, plan: plan, duration: duration, generation: mine, done: done)
            return
        }
        let ghosts = stageZoom(plan)
        displayIfNeeded()
        if let ride = ballMorph(for: plan) {
            playBallMorph(ride, duration: duration, ease: Self.zoomPace, generation: mine) {}
        }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = duration
            context.timingFunction = Self.zoomEase
            context.allowsImplicitAnimation = true
            for (ghost, part) in zip(ghosts, plan.parts) {
                ghost.animator().frame = part.to.offsetBy(dx: -plan.stage.minX, dy: -plan.stage.minY)
                ghost.animator().alphaValue = part.alphaTo
            }
        }, completionHandler: { [weak self] in
            guard let self, self.animation == mine else { return }
            self.ghosts.forEach { $0.removeFromSuperview() }
            self.ghosts = []
            self.transitioning = false
            done?()
            if !self.dragging { self.applyGeometry() }
        })
    }

    private func zoomOpen() { runZoom(openPlan(), duration: 0.32) }

    private func zoomSwitch(from oldRect: NSRect, image: CGImage, oldPage: Page) {
        runZoom(switchPlan(from: oldRect, image: image, oldPage: oldPage), duration: 0.28)
    }

    // MARK: Morph (page to page)

    private struct MorphViews {
        let card: NSView
        let shade: NSView
        let old: NSView
        let new: NSView
    }

    private func makeMorphViews(_ morph: Morph) -> MorphViews {
        let card = NSView()
        card.wantsLayer = true
        card.layer?.backgroundColor = cardView.layer?.backgroundColor
        card.layer?.borderColor = cardView.layer?.borderColor
        card.layer?.borderWidth = 1
        card.layer?.cornerRadius = 20
        card.layer?.masksToBounds = true
        let back = NSView()
        back.wantsLayer = true
        back.layer?.contents = backdrop.layer?.contents
        back.layer?.contentsGravity = .resizeAspectFill
        back.autoresizingMask = [.width, .height]
        let veil = NSView()
        veil.wantsLayer = true
        veil.layer?.backgroundColor = NSColor(srgbRed: 0.05, green: 0.05, blue: 0.10, alpha: 1).cgColor
        veil.autoresizingMask = [.width, .height]
        func content(_ image: CGImage?, size: NSSize) -> NSView {
            let view = NSView(frame: NSRect(origin: .zero, size: size))
            view.wantsLayer = true
            view.layer?.contents = image
            view.layer?.contentsGravity = .resize
            return view
        }
        let old = content(morph.oldContent, size: morph.from.size)
        let new = content(morph.newContent, size: morph.to.size)
        [back, veil, old, new].forEach(card.addSubview)
        contentView?.addSubview(card)
        ghosts.append(card)
        return MorphViews(card: card, shade: veil, old: old, new: new)
    }

    /// Places the morph at eased progress `t` (0…1).
    private func layoutMorph(_ views: MorphViews, _ morph: Morph, stage: NSRect, at t: CGFloat) {
        func mix(_ a: CGFloat, _ b: CGFloat) -> CGFloat { a + (b - a) * t }
        let rect = NSRect(x: mix(morph.from.minX, morph.to.minX), y: mix(morph.from.minY, morph.to.minY),
                          width: mix(morph.from.width, morph.to.width), height: mix(morph.from.height, morph.to.height))
        views.card.frame = rect.offsetBy(dx: -stage.minX, dy: -stage.minY)
        let size = rect.size
        for view in views.card.subviews.prefix(2) { view.frame = NSRect(origin: .zero, size: size) }
        views.shade.alphaValue = mix(morph.dimFrom, morph.dimTo)
        for view in [views.old, views.new] {
            let w = view.frame.width, h = view.frame.height
            view.frame.origin = NSPoint(x: morph.anchorRight ? size.width - w : 0, y: size.height - h)
        }
        // Old content gone by just past half way; new content in from a
        // fifth of the way: always over the solid card, never see-through.
        views.old.alphaValue = max(0, 1 - t / 0.55)
        views.new.alphaValue = min(1, max(0, (t - 0.2) / 0.6))
    }

    private func runMorph(_ morph: Morph, plan: ZoomPlan, duration: TimeInterval, generation mine: Int,
                          done: (() -> Void)?) {
        stageZoomFrame(plan)
        let ride = ballMorph(for: plan)
        let views = makeMorphViews(morph)
        layoutMorph(views, morph, stage: plan.stage, at: 0)
        displayIfNeeded()
        let start = CACurrentMediaTime()
        let timer = Timer(timeInterval: 1.0 / 120, repeats: true) { [weak self] timer in
            guard let self, self.animation == mine else { timer.invalidate(); return }
            let progress = min(1, (CACurrentMediaTime() - start) / duration)
            // Ease out: quick start, gentle landing.
            let eased = 1 - pow(1 - CGFloat(progress), 3)
            self.layoutMorph(views, morph, stage: plan.stage, at: eased)
            if let ride { self.layoutBallMorph(ride, at: eased) }
            self.displayIfNeeded()
            guard progress >= 1 else { return }
            timer.invalidate()
            self.ghosts.forEach { $0.removeFromSuperview() }
            self.ghosts = []
            self.transitioning = false
            done?()
            if !self.dragging { self.applyGeometry() }
        }
        RunLoop.main.add(timer, forMode: .common)
    }

    /// Window on the plan's stage, real card hidden, ball in place.
    private func stageZoomFrame(_ plan: ZoomPlan) {
        transitioning = true
        cardView.isHidden = true
        setFrame(plan.stage, display: false)
        ball.frame = plan.ballRect.offsetBy(dx: -plan.stage.minX, dy: -plan.stage.minY)
        layoutBall()
        if let ride = ballMorph(for: plan) { beginBallMorph(ride) }
    }

    private func zoomClose(from cardRect: NSRect, image: CGImage) {
        runZoom(closePlan(from: cardRect, image: image), duration: 0.22) { [weak self] in
            if Prefs.bool("dock.hidden"), self?.expanded == false { self?.orderOut(nil) }
        }
    }

    /// Test hook: renders a zoom at a few points of its way into PNGs
    /// (`kind` = open, switch or close; `from` / `to` pages for a switch).
    static func debugZoom(kind: String, from: Page, to: Page, x: Double, y: Double, into directory: URL) -> [String] {
        let panel = instance()
        Prefs.set("dock.posX", x)
        Prefs.set("dock.posY", y)
        panel.cancelTransition()
        var plan: ZoomPlan?
        switch kind {
        case "open":
            panel.closeCard()
            panel.page = to
            panel.expanded = true
            plan = panel.openPlan()
        case "close":
            panel.present(from, hold: true, focus: false)
            panel.applyGeometry()
            let rect = panel.cardView.frame.offsetBy(dx: panel.frame.minX, dy: panel.frame.minY)
            guard let image = panel.cardSnapshot() else { return ["no snapshot"] }
            panel.expanded = false
            (panel.shownPage as? DockPage)?.pageDidDisappear()
            panel.shownPage?.removeFromSuperview()
            panel.shownPage = nil
            panel.page = .home
            plan = panel.closePlan(from: rect, image: image)
        default:
            panel.present(from, hold: true, focus: false)
            panel.applyGeometry()
            let rect = panel.cardView.frame.offsetBy(dx: panel.frame.minX, dy: panel.frame.minY)
            guard let image = panel.cardSnapshot(contentOnly: true) else { return ["no snapshot"] }
            panel.page = to
            plan = panel.switchPlan(from: rect, image: image, oldPage: from)
        }
        guard let plan = plan.map(panel.ridingBall) else { return ["no plan"] }
        var lines: [String] = []
        for t in [0, 0.35, 0.7, 1] as [CGFloat] {
            panel.cancelTransition()
            let ghosts = panel.stageZoom(plan, at: t)
            let name = "zoom-\(kind)-\(from.rawValue)-\(to.rawValue)-\(Int(t * 100)).png"
            snapshot(to: directory.appendingPathComponent(name))
            lines.append("\(name) " + ghosts.map { "[\(Int($0.frame.width))x\(Int($0.frame.height)) a=\(String(format: "%.2f", $0.alphaValue))]" }.joined(separator: " "))
        }
        panel.cancelTransition()
        panel.applyGeometry()
        return lines
    }

    /// The card lost the keyboard (a click somewhere else): unless a hotkey
    /// pinned it, it folds away.
    override func resignKey() {
        super.resignKey()
        guard expanded, !heldOpen, focused else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self, self.expanded, !self.heldOpen, self.focused, !self.isKeyWindow,
                  NSApp.modalWindow == nil else { return }
            self.closeCard()
        }
    }

    private func closeCard() {
        guard expanded else {
            if Prefs.bool("dock.hidden") { orderOut(nil) }
            return
        }
        let hadKeyboard = isKeyWindow
        let canAnimate = !Self.headless && isVisible && !dragging && !cardView.isHidden && !transitioning
        let oldRect = cardView.frame.offsetBy(dx: frame.minX, dy: frame.minY)
        let image = canAnimate ? cardSnapshot() : nil
        cancelTransition()
        expanded = false
        heldOpen = false
        focused = false
        awaySince = nil
        openedFrom = nil
        makeFirstResponder(nil)
        (shownPage as? DockPage)?.pageDidDisappear()
        shownPage?.removeFromSuperview()
        shownPage = nil
        // Hovering always opens the home page.
        page = .home
        updateHomeKeys()
        if let image {
            zoomClose(from: oldRect, image: image)
        } else {
            applyGeometry()
            if Prefs.bool("dock.hidden") { orderOut(nil) }
        }
        if hadKeyboard { FocusKeeper.restore() }
    }

    private func pollPointer() {
        guard isVisible, !dragging else { return }
        let mouse = NSEvent.mouseLocation
        let (window, ballRect, cardRect) = (frame, ball.frame.offsetBy(dx: frame.minX, dy: frame.minY),
                                            expanded ? cardView.frame.offsetBy(dx: frame.minX, dy: frame.minY) : nil)
        // The ball counts too: resting on it while the home page is open is
        // enough for the playback keys.
        updateHomeKeys(pointerOnCard: (cardRect?.contains(mouse) ?? false) || ballRect.contains(mouse))

        if !expanded {
            // Opens only when the pointer actually touches the ball. A
            // pressed button means something is being dragged past it.
            if ballRect.contains(mouse), NSEvent.pressedMouseButtons == 0 {
                present(.home, hold: false, focus: false)
            }
            return
        }
        // Pinned by a hotkey, or in use with the keyboard: stays.
        guard !heldOpen, !(focused && isKeyWindow), animationIdle else { return }
        // A small margin (and the strip between ball and card) keeps it
        // from flickering shut on the way across.
        let stay = openedFrom.map { window.union($0) } ?? window
        if stay.insetBy(dx: -10, dy: -10).contains(mouse) {
            awaySince = nil
            return
        }
        if awaySince == nil { awaySince = Date() }
        if let awaySince, Date().timeIntervalSince(awaySince) >= 0.4 { closeCard() }
    }

    private var animationIdle: Bool { !transitioning }

    // MARK: Home page keys

    /// While the pointer rests on the home page: Space = play / pause,
    /// ⌘→ / ⌘← = forward / back 5 s, ⇧⌘→ / ⇧⌘← = next / previous.
    private func updateHomeKeys(pointerOnCard: Bool = false) {
        let wanted = expanded && page == .home && pointerOnCard && playing != nil && isVisible
        if !wanted {
            if !homeKeys.isEmpty { homeKeys = [] }
            return
        }
        guard homeKeys.isEmpty else { return }
        let cmd = UInt32(cmdKey), shift = UInt32(shiftKey)
        let bindings: [(Int, UInt32, () -> Void)] = [
            (kVK_Space, 0, { MediaObserver.shared.togglePlayPause() }),
            (kVK_RightArrow, cmd, { MediaObserver.shared.seek(by: 5) }),
            (kVK_LeftArrow, cmd, { MediaObserver.shared.seek(by: -5) }),
            (kVK_RightArrow, cmd | shift, { MediaObserver.shared.nextTrack() }),
            (kVK_LeftArrow, cmd | shift, { MediaObserver.shared.previousTrack() })
        ]
        homeKeys = bindings.compactMap { HotKey(keyCode: UInt32($0.0), carbonModifiers: $0.1, action: $0.2) }
    }

    // MARK: Ball: files dropped on it go to the Shelf

    fileprivate func filesDropped(_ urls: [URL]) {
        ShelfPane.add(urls)
        showShelfAfterDrop()
    }

    /// Settings key: after a drop the Shelf comes to the front and stays
    /// open until closed, like a page opened with a hotkey (default on).
    static let shelfKeepOpenKey = "shelf.keepOpenOnDrop"

    /// Shows where dropped files went. Kept in front unless switched off in
    /// settings; then it folds away like a hover-opened card.
    private func showShelfAfterDrop() {
        let keep = Prefs.bool(Self.shelfKeepOpenKey, true)
        if keep, !Self.headless { orderFrontRegardless() }
        present(.shelf, hold: keep, focus: false)
    }

    /// Test hook: the card after a drop (page shown, kept open).
    static func debugShowShelfAfterDrop() -> (page: Page?, held: Bool) {
        let panel = instance()
        panel.closeCard()
        panel.showShelfAfterDrop()
        return (debugPage, panel.heldOpen)
    }

    // MARK: Ball: drag, click, menu

    fileprivate func ballDragBegan() {
        dragging = true
        reopenAfterDrag = expanded && (heldOpen || focused)
        let midMorph = ballMorphing
        cancelTransition()
        if expanded || midMorph {
            // Only the ball travels; the card comes back where it lands.
            cardView.isHidden = true
            let ballOnScreen = ball.frame.offsetBy(dx: frame.minX, dy: frame.minY)
            setFrame(ballOnScreen, display: true)
            ball.frame.origin = .zero
        }
    }

    fileprivate func ballDragged(to origin: NSPoint) {
        setFrameOrigin(origin)
    }

    /// Stays wherever it is dropped (kept fully on screen).
    fileprivate func ballDragEnded() {
        dragging = false
        let visible = dockScreen.visibleFrame
        let half = Self.iconSize / 2 + 8
        let fx = (frame.midX - visible.minX - half) / max(visible.width - half * 2, 1)
        let fy = (frame.midY - visible.minY - half) / max(visible.height - half * 2, 1)
        Prefs.set("dock.posX", Double(min(max(fx, 0), 1)))
        Prefs.set("dock.posY", Double(min(max(fy, 0), 1)))
        if reopenAfterDrag {
            applyGeometry()
        } else {
            expanded = false
            closeCardAfterDrag()
        }
    }

    private func closeCardAfterDrag() {
        (shownPage as? DockPage)?.pageDidDisappear()
        shownPage?.removeFromSuperview()
        shownPage = nil
        heldOpen = false
        focused = false
        page = .home
        applyGeometry()
    }

    /// A plain click on the ball closes a card that was pinned open.
    fileprivate func ballClicked() {
        if expanded, heldOpen || focused { closeCard() }
    }

    fileprivate func ballMenu(with event: NSEvent) {
        let menu = NSMenu()
        menu.addItem(withTitle: "Dock Icon…", action: #selector(menuChooseIcon), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Default Icon", action: #selector(menuResetIcon), keyEquivalent: "").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Agenda", action: #selector(menuOpenTasks), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Settings…", action: #selector(menuSettings), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Hide Dock", action: #selector(menuHide), keyEquivalent: "").target = self
        NSMenu.popUpContextMenu(menu, with: event, for: ball)
    }

    @objc private func menuChooseIcon() { Self.chooseIcon() }
    @objc private func menuResetIcon() { Self.resetIcon() }
    @objc private func menuOpenTasks() { Self.open(.tasks, toggle: false, pinned: false) }
    @objc private func menuSettings() { Self.open(.settings, toggle: false, settingsTab: 5, pinned: false) }
    @objc private func menuHide() { Self.toggle() }

    /// Entry icons: the card switches to that page.
    @objc private func navTapped(_ sender: NSButton) {
        guard sender.tag < Page.allCases.count else { return }
        let target = Page.allCases[sender.tag]
        // A page reached by clicking is not pinned: it goes away when the
        // card loses the keyboard. A hotkey pins only the page it opened;
        // clicking over to another page ends that.
        present(target, hold: heldOpen && target == page, focus: true)
    }

    /// Test hook: an entry icon clicked (through its action).
    static func debugTapNav(_ target: Page) {
        guard let shared, let button = shared.navButtons[target], let action = button.action else { return }
        NSApp.sendAction(action, to: button.target, from: button)
    }

    /// Test hook: whether the card is pinned open.
    static var debugHeld: Bool { shared?.heldOpen ?? false }


    @objc private func togglePlayback() { MediaObserver.shared.togglePlayPause() }
    @objc private func cyclePlayMode() { MediaObserver.shared.cyclePlayMode() }

    /// Short message shown in place of the artist line for a few seconds
    /// when a control cannot reach the player.
    private var controlNote: (text: String, until: Date)?

    private func showControlNote(_ reason: String) {
        let app = MediaObserver.shared.current?.appName ?? ""
        let name = app.isEmpty ? "this player" : app
        let text = reason.contains("Accessibility") ? "Allow Accessibility to control \(name)"
            : reason.contains("Now Playing") ? "Open \(name) to control it" : "Not supported by \(name)"
        controlNote = (text, Date().addingTimeInterval(4))
        artistLabel.toolTip = reason
        refresh()
        DispatchQueue.main.asyncAfter(deadline: .now() + 4.1) { [weak self] in
            self?.controlNote = nil
            self?.artistLabel.toolTip = nil
            self?.refresh()
        }
    }
    @objc private func toggleLike() { MediaObserver.shared.toggleLike() }

    /// Home page to-do (double-click): the Agenda opens on that to-do.
    private func openTask(_ id: UUID) {
        present(.tasks, hold: heldOpen && page == .tasks, focus: true)
        agendaPane.focus(taskID: id)
    }

    static func debugOpenTask(_ id: UUID) { instance().openTask(id) }
    @objc private func nextTrack() { MediaObserver.shared.nextTrack() }
    @objc private func previousTrack() { MediaObserver.shared.previousTrack() }
    @objc private func openMediaOwner() { MediaObserver.shared.activateOwner() }

    // MARK: Headless verification

    /// Builds the widget without putting it on screen and renders one state
    /// into a PNG.
    static func debugRender(to url: URL, x: Double, y: Double, expanded: Bool, page: String) -> String {
        let panel = instance()
        Prefs.set("dock.posX", x)
        Prefs.set("dock.posY", y)
        if expanded {
            panel.present(Page(rawValue: page) ?? .home, hold: true, focus: false)
            panel.cardView.alphaValue = 1
        } else {
            panel.closeCard()
        }
        panel.refresh()
        return snapshot(to: url)
    }

    /// Renders whatever the widget shows right now.
    @discardableResult
    static func snapshot(to url: URL) -> String {
        guard let shared, let view = shared.contentView else { return "no dock" }
        view.layoutSubtreeIfNeeded()
        view.display()
        if let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
            view.cacheDisplay(in: view.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: url)
        }
        return debugState
    }
}

// MARK: - Card

/// The card's frame. Clicks on the bare top strip are reported.
final class CardView: NSView {
    var headerHeight: CGFloat = 40
    /// Parts of the header that do not count (the entry icons).
    var headerExclusions: [NSRect] = []
    var onHeaderClick: (() -> Void)?

    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if point.y <= headerHeight, !headerExclusions.contains(where: { $0.contains(point) }) {
            onHeaderClick?()
        } else {
            super.mouseDown(with: event)
        }
    }
}

// MARK: - Ball

/// The round icon / pill. Dragging moves the whole widget; a click and a
/// right-click are passed on to the panel.
final class DockBallView: NSView {
    weak var owner: FloatingDockPanel?
    private var grab = NSPoint.zero
    private var moved = false

    override func mouseDown(with event: NSEvent) {
        grab = convert(event.locationInWindow, from: nil)
        moved = false
    }

    override func mouseDragged(with event: NSEvent) {
        if !moved {
            moved = true
            owner?.ballDragBegan()
        }
        let mouse = NSEvent.mouseLocation
        owner?.ballDragged(to: NSPoint(x: mouse.x - grab.x, y: mouse.y - grab.y))
    }

    override func mouseUp(with event: NSEvent) {
        if moved { owner?.ballDragEnded() } else { owner?.ballClicked() }
        moved = false
    }

    override func rightMouseDown(with event: NSEvent) { owner?.ballMenu(with: event) }

    // Files dragged onto the ball go to the Shelf.
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard !ShelfRowView.isDraggingOut, !ShelfPane.fileURLs(sender).isEmpty else { return [] }
        dropHighlight(true)
        return .copy
    }

    override func draggingExited(_ sender: NSDraggingInfo?) { dropHighlight(false) }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        dropHighlight(false)
        let urls = ShelfPane.fileURLs(sender)
        guard !urls.isEmpty else { return false }
        owner?.filesDropped(urls)
        return true
    }

    private var savedBorder: (CGColor?, CGFloat) = (nil, 0)
    private func dropHighlight(_ on: Bool) {
        if on {
            savedBorder = (layer?.borderColor, layer?.borderWidth ?? 0)
            layer?.borderColor = NSColor(srgbRed: 0.45, green: 0.85, blue: 1.0, alpha: 1).cgColor
            layer?.borderWidth = 3
        } else {
            layer?.borderColor = savedBorder.0
            layer?.borderWidth = savedBorder.1
        }
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .openHand)
    }
}

// MARK: - Spinning cover

/// Round image that turns like a record while music plays.
final class SpinningDisc: NSView {
    private let disc = CALayer()

    var image: NSImage? {
        didSet {
            // A CGImage is the one content type every layer path accepts.
            var rect = NSRect(origin: .zero, size: image?.size ?? .zero)
            disc.contents = image?.cgImage(forProposedRect: &rect, context: nil, hints: nil) ?? image
        }
    }

    var isSpinning = false {
        didSet { if oldValue != isSpinning { updateAnimation() } }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        disc.contentsGravity = .resizeAspectFill
        disc.masksToBounds = true
        layer?.addSublayer(disc)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        updateGeometry()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        updateGeometry()
    }

    private func updateGeometry() {
        // A sublayer (not the view's own layer) so it rotates about its centre.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        disc.bounds = CGRect(origin: .zero, size: bounds.size)
        disc.position = CGPoint(x: bounds.midX, y: bounds.midY)
        disc.cornerRadius = min(bounds.width, bounds.height) / 2
        CATransaction.commit()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateAnimation()
    }

    private func updateAnimation() {
        disc.removeAnimation(forKey: "spin")
        guard isSpinning, window != nil else { return }
        let spin = CABasicAnimation(keyPath: "transform.rotation.z")
        spin.fromValue = 0
        spin.toValue = -2 * Double.pi
        spin.duration = 9
        spin.repeatCount = .infinity
        spin.isRemovedOnCompletion = false
        disc.add(spin, forKey: "spin")
    }
}

// MARK: - Equalizer

/// A few bars bouncing out of step — the "something is playing" cue.
final class EqualizerView: NSView {
    private var bars: [CALayer] = []

    var isAnimating = false {
        didSet { if oldValue != isAnimating { updateAnimation() } }
    }

    init(barCount: Int) {
        super.init(frame: .zero)
        wantsLayer = true
        for _ in 0..<barCount {
            let bar = CALayer()
            bar.backgroundColor = NSColor(srgbRed: 0.45, green: 0.85, blue: 1.0, alpha: 1).cgColor
            bar.anchorPoint = CGPoint(x: 0.5, y: 0)
            layer?.addSublayer(bar)
            bars.append(bar)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        guard !bars.isEmpty else { return }
        let gap: CGFloat = 2
        let width = max(1.5, (bounds.width - gap * CGFloat(bars.count - 1)) / CGFloat(bars.count))
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (index, bar) in bars.enumerated() {
            bar.bounds = CGRect(x: 0, y: 0, width: width, height: bounds.height)
            bar.position = CGPoint(x: CGFloat(index) * (width + gap) + width / 2, y: 0)
            bar.cornerRadius = width / 2
        }
        CATransaction.commit()
        updateAnimation()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateAnimation()
    }

    private func updateAnimation() {
        let rest: [CGFloat] = [0.35, 0.6, 0.45, 0.7, 0.4]
        for (index, bar) in bars.enumerated() {
            bar.removeAnimation(forKey: "bounce")
            bar.transform = CATransform3DMakeScale(1, rest[index % rest.count], 1)
            guard isAnimating, window != nil else { continue }
            let bounce = CABasicAnimation(keyPath: "transform.scale.y")
            bounce.fromValue = 0.18
            bounce.toValue = 1.0
            bounce.duration = 0.32 + Double(index % 3) * 0.11 + Double(index) * 0.03
            bounce.autoreverses = true
            bounce.repeatCount = .infinity
            bounce.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            bounce.timeOffset = Double(index) * 0.13
            bounce.isRemovedOnCompletion = false
            bar.add(bounce, forKey: "bounce")
        }
    }
}

// MARK: - Progress bar

/// Playback position. When seekable, a click jumps there and a drag scrubs
/// (`onScrub` while dragging, `onSeek` on release).
final class ProgressBar: NSView {
    var fraction: CGFloat = 0 {
        didSet { if abs(oldValue - fraction) > 0.001 { needsDisplay = true } }
    }
    var tint = NSColor.white { didSet { needsDisplay = true } }
    var onScrub: ((CGFloat) -> Void)?
    var onSeek: ((CGFloat) -> Void)?
    var isSeekable = false {
        didSet {
            guard oldValue != isSeekable else { return }
            needsDisplay = true
            window?.invalidateCursorRects(for: self)
        }
    }
    private(set) var isScrubbing = false
    private var isHovering = false
    private var hoverArea: NSTrackingArea?

    private static let barHeight: CGFloat = 4
    private static let activeBarHeight: CGFloat = 6
    private static let knobDiameter: CGFloat = 10

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverArea { removeTrackingArea(hoverArea) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        hoverArea = area
    }

    override func mouseEntered(with event: NSEvent) { isHovering = true; needsDisplay = true }
    override func mouseExited(with event: NSEvent) { isHovering = false; needsDisplay = true }

    override func resetCursorRects() {
        if isSeekable { addCursorRect(bounds, cursor: .pointingHand) }
    }

    override func mouseDown(with event: NSEvent) {
        guard isSeekable else { return }
        isScrubbing = true
        scrub(event)
    }

    override func mouseDragged(with event: NSEvent) {
        if isScrubbing { scrub(event) }
    }

    override func mouseUp(with event: NSEvent) {
        guard isScrubbing else { return }
        scrub(event)
        isScrubbing = false
        needsDisplay = true
        onSeek?(fraction)
    }

    private func scrub(_ event: NSEvent) {
        let x = convert(event.locationInWindow, from: nil).x
        fraction = min(max(x / max(bounds.width, 1), 0), 1)
        onScrub?(fraction)
    }

    override func draw(_ dirtyRect: NSRect) {
        let active = isSeekable && (isHovering || isScrubbing)
        let height = active ? Self.activeBarHeight : Self.barHeight
        let bar = NSRect(x: 0, y: bounds.midY - height / 2, width: bounds.width, height: height)
        NSColor(white: 1, alpha: 0.16).setFill()
        NSBezierPath(roundedRect: bar, xRadius: height / 2, yRadius: height / 2).fill()
        let width = bounds.width * min(max(fraction, 0), 1)
        tint.setFill()
        if width > 0.5 {
            let filled = NSRect(x: 0, y: bar.minY, width: max(width, height), height: height)
            NSBezierPath(roundedRect: filled, xRadius: height / 2, yRadius: height / 2).fill()
        }
        guard active else { return }
        let size = Self.knobDiameter
        let x = min(max(width, size / 2), bounds.width - size / 2)
        NSBezierPath(ovalIn: NSRect(x: x - size / 2, y: bounds.midY - size / 2, width: size, height: size)).fill()
    }
}

// MARK: - Clickable views

/// The player's cover: a click opens the playing app. Handles the click
/// itself and takes the first click even when the card is not key.
final class ClickableImageView: NSImageView {
    var onClick: (() -> Void)?
    private var pressed = false

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) { pressed = true }

    override func mouseUp(with event: NSEvent) {
        defer { pressed = false }
        guard pressed, bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
        onClick?()
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .pointingHand)
    }
}

final class ClickableStack: NSStackView {
    var onClick: (() -> Void)?
    private var pressed = false

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) { pressed = true }

    override func mouseUp(with event: NSEvent) {
        defer { pressed = false }
        guard pressed, bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
        onClick?()
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .pointingHand)
    }
}

// MARK: - Task row

final class DockTaskRow: NSView {
    private let task: TaskItem
    /// Double-click: open this to-do in the Agenda.
    var onOpen: ((UUID) -> Void)?

    init(task: TaskItem) {
        self.task = task
        super.init(frame: .zero)
        let checkbox = NSButton(checkboxWithTitle: "", target: self, action: #selector(markDone))
        checkbox.translatesAutoresizingMaskIntoConstraints = false
        checkbox.toolTip = "Mark done"
        let label = NSTextField(labelWithString: task.title)
        label.font = .systemFont(ofSize: 12)
        label.textColor = .white
        label.lineBreakMode = .byTruncatingTail
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        label.toolTip = (task.note.isEmpty ? task.title : "\(task.title)\n\(task.note)") + "\nDouble-click to open"
        label.translatesAutoresizingMaskIntoConstraints = false
        let doubleClick = NSClickGestureRecognizer(target: self, action: #selector(openTask))
        doubleClick.numberOfClicksRequired = 2
        addGestureRecognizer(doubleClick)

        addSubview(checkbox)
        addSubview(label)
        var constraints = [
            heightAnchor.constraint(equalToConstant: 22),
            checkbox.leadingAnchor.constraint(equalTo: leadingAnchor),
            checkbox.centerYAnchor.constraint(equalTo: centerYAnchor),
            label.leadingAnchor.constraint(equalTo: checkbox.trailingAnchor, constant: 4),
            label.centerYAnchor.constraint(equalTo: centerYAnchor)
        ]

        if let due = task.due {
            let formatter = DateFormatter()
            formatter.dateFormat = Calendar.current.isDateInToday(due) ? "HH:mm" : "MM-dd"
            let dueLabel = NSTextField(labelWithString: formatter.string(from: due))
            dueLabel.font = .monospacedDigitSystemFont(ofSize: 10, weight: .regular)
            dueLabel.textColor = due < Date() ? .systemRed : NSColor(white: 1, alpha: 0.45)
            dueLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
            dueLabel.translatesAutoresizingMaskIntoConstraints = false
            addSubview(dueLabel)
            constraints += [
                dueLabel.trailingAnchor.constraint(equalTo: trailingAnchor),
                dueLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
                label.trailingAnchor.constraint(lessThanOrEqualTo: dueLabel.leadingAnchor, constant: -6)
            ]
        } else {
            constraints.append(label.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor))
        }
        NSLayoutConstraint.activate(constraints)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    @objc private func markDone() {
        TaskStore.shared.complete(task.id)
    }

    @objc private func openTask() { onOpen?(task.id) }
}

/// A thin knob without a track, for lists on the dark card.
final class SlimScroller: NSScroller {
    override class var isCompatibleWithOverlayScrollers: Bool { false }
    override class func scrollerWidth(for controlSize: NSControl.ControlSize, scrollerStyle: NSScroller.Style) -> CGFloat { 8 }
    override func drawKnobSlot(in slotRect: NSRect, highlight flag: Bool) {}
    override func drawKnob() {
        let rect = rect(for: .knob).insetBy(dx: 2, dy: 2)
        NSColor(white: 1, alpha: 0.35).setFill()
        NSBezierPath(roundedRect: rect, xRadius: rect.width / 2, yRadius: rect.width / 2).fill()
    }
}
