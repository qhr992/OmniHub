import AppKit

/// Help in the main window: every feature, with a search across all of it.
/// Typing narrows the help to the topics that mention every word (in the
/// topic or its section's title), marked where they appear; a section whose
/// title matches shows whole.
final class HelpView: NSView, NSSearchFieldDelegate {
    static let maxWidth: CGFloat = 760

    private let search = NSSearchField()
    private let count = NSTextField(labelWithString: "")
    private let empty = NSTextField(labelWithString: "")
    private let list = NSStackView()
    private let scroll = NSScrollView()
    private var blocks: [SectionBlock] = []

    init(sections: [HelpSection] = HelpContent.sections) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor(srgbRed: 0.098, green: 0.102, blue: 0.122, alpha: 1).cgColor
        translatesAutoresizingMaskIntoConstraints = false

        search.placeholderString = L("Search help")
        search.delegate = self
        search.sendsSearchStringImmediately = true
        search.target = self
        search.action = #selector(searched)
        search.font = .systemFont(ofSize: 14)
        search.controlSize = .large
        count.font = .systemFont(ofSize: 11)
        count.textColor = NSColor(white: 1, alpha: 0.45)
        empty.font = .systemFont(ofSize: 13)
        empty.textColor = NSColor(white: 1, alpha: 0.5)
        empty.isHidden = true

        list.orientation = .vertical
        list.alignment = .leading
        list.spacing = 14
        list.translatesAutoresizingMaskIntoConstraints = false
        blocks = sections.map(SectionBlock.init)
        for block in blocks {
            list.addArrangedSubview(block)
            block.widthAnchor.constraint(equalTo: list.widthAnchor).isActive = true
        }
        list.addArrangedSubview(empty)

        let document = FlippedView()
        document.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(list)
        scroll.documentView = document
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        for view in [search, count, scroll] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        let clip = scroll.contentView
        let wide = list.widthAnchor.constraint(equalTo: document.widthAnchor, constant: -4)
        wide.priority = .defaultHigh
        let searchWide = search.widthAnchor.constraint(equalTo: widthAnchor, constant: -4)
        searchWide.priority = .defaultHigh
        NSLayoutConstraint.activate([
            search.topAnchor.constraint(equalTo: topAnchor, constant: 2),
            search.leadingAnchor.constraint(equalTo: leadingAnchor),
            search.widthAnchor.constraint(lessThanOrEqualToConstant: Self.maxWidth),
            searchWide,
            count.leadingAnchor.constraint(equalTo: search.leadingAnchor, constant: 2),
            count.topAnchor.constraint(equalTo: search.bottomAnchor, constant: 6),
            scroll.topAnchor.constraint(equalTo: count.bottomAnchor, constant: 8),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
            document.topAnchor.constraint(equalTo: clip.topAnchor),
            document.leadingAnchor.constraint(equalTo: clip.leadingAnchor),
            document.widthAnchor.constraint(equalTo: clip.widthAnchor),
            list.topAnchor.constraint(equalTo: document.topAnchor),
            list.leadingAnchor.constraint(equalTo: document.leadingAnchor),
            list.bottomAnchor.constraint(equalTo: document.bottomAnchor, constant: -16),
            list.widthAnchor.constraint(lessThanOrEqualToConstant: Self.maxWidth),
            wide
        ])
        apply("")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    /// Where the keyboard goes when help opens.
    var searchField: NSSearchField { search }

    @objc private func searched() { apply(search.stringValue) }

    func controlTextDidChange(_ obj: Notification) { apply(search.stringValue) }

    /// Shows what matches `query` (everything when it is empty).
    func apply(_ query: String) {
        let words = query.split(whereSeparator: \.isWhitespace).map(String.init)
        var shown = 0
        for block in blocks { shown += block.filter(words) }
        let total = blocks.reduce(0) { $0 + $1.entryCount }
        count.stringValue = words.isEmpty ? L("%ld topics", total) : L("%ld of %ld topics", shown, total)
        empty.stringValue = L("Nothing in the help mentions “%@”.", query.trimmingCharacters(in: .whitespaces))
        empty.isHidden = shown > 0 || words.isEmpty
        scroll.contentView.scroll(to: .zero)
        scroll.reflectScrolledClipView(scroll.contentView)
    }

    /// Test hook: types into the search field.
    func debugSearch(_ text: String) {
        search.stringValue = text
        apply(text)
    }

    /// Test hook: the headings shown, and how many marks are drawn.
    var debugShown: (headings: [String], marks: Int, empty: Bool) {
        let shown = blocks.filter { !$0.isHidden }.flatMap { $0.shownHeadings }
        return (shown, blocks.reduce(0) { $0 + $1.marks }, !empty.isHidden)
    }

    /// Text with every occurrence of `words` marked.
    static func marked(_ text: String, _ words: [String], font: NSFont, colour: NSColor, mark: NSColor) -> (NSAttributedString, Int) {
        let out = NSMutableAttributedString(string: text, attributes: [.font: font, .foregroundColor: colour])
        var marks = 0
        let source = text as NSString
        for word in words where !word.isEmpty {
            var range = NSRange(location: 0, length: source.length)
            while true {
                let found = source.range(of: word, options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], range: range)
                guard found.location != NSNotFound else { break }
                out.addAttributes([.backgroundColor: mark, .foregroundColor: NSColor.white], range: found)
                marks += 1
                let next = found.location + found.length
                range = NSRange(location: next, length: source.length - next)
            }
        }
        return (out, marks)
    }

    static func matches(_ text: String, _ words: [String]) -> Bool {
        words.allSatisfy { text.range(of: $0, options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive]) != nil }
    }
}

/// One help section: badge and title, then its topics.
private final class SectionBlock: NSStackView {
    private let section: HelpSection
    private let titleField = NSTextField(labelWithString: "")
    private var rows: [(entry: HelpEntry, view: NSStackView, heading: NSTextField, body: NSTextField)] = []
    private(set) var marks = 0

    var entryCount: Int { section.entries.count }
    var shownHeadings: [String] { rows.filter { !$0.view.isHidden }.map(\.entry.heading) }

    init(_ section: HelpSection) {
        self.section = section
        super.init(frame: .zero)
        orientation = .vertical
        alignment = .leading
        spacing = 12
        wantsLayer = true
        layer?.cornerRadius = 14
        layer?.backgroundColor = NSColor(white: 1, alpha: 0.045).cgColor
        layer?.borderColor = section.tint.withAlphaComponent(0.2).cgColor
        layer?.borderWidth = 1
        edgeInsets = NSEdgeInsets(top: 16, left: 18, bottom: 18, right: 18)
        translatesAutoresizingMaskIntoConstraints = false

        titleField.font = .systemFont(ofSize: 16, weight: .bold)
        titleField.textColor = .white
        let header = NSStackView(views: [BadgeView(symbol: section.symbol, tint: section.tint, side: 26), titleField])
        header.spacing = 10
        addArrangedSubview(header)
        for entry in section.entries {
            let heading = NSTextField(labelWithString: "")
            let body = NSTextField(wrappingLabelWithString: "")
            body.isSelectable = true
            body.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            let view = NSStackView(views: [heading, body])
            view.orientation = .vertical
            view.alignment = .leading
            view.spacing = 4
            addArrangedSubview(view)
            view.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 54).isActive = true
            view.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -18).isActive = true
            body.widthAnchor.constraint(equalTo: view.widthAnchor).isActive = true
            rows.append((entry, view, heading, body))
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    /// Shows the topics matching `words`; returns how many.
    func filter(_ words: [String]) -> Int {
        let wholeSection = !words.isEmpty && HelpView.matches(section.title, words)
        let mark = section.tint.withAlphaComponent(0.55)
        var shown = 0
        marks = 0
        let (title, titleMarks) = HelpView.marked(section.title, words, font: .systemFont(ofSize: 16, weight: .bold),
                                                  colour: .white, mark: mark)
        titleField.attributedStringValue = title
        marks += titleMarks
        for row in rows {
            // Each word may be in the section's title or the topic itself.
            let hit = words.isEmpty || wholeSection
                || HelpView.matches(section.title + " " + row.entry.heading + " " + row.entry.body, words)
            row.view.isHidden = !hit
            guard hit else { continue }
            shown += 1
            let (heading, headingMarks) = HelpView.marked(row.entry.heading, words, font: .systemFont(ofSize: 13, weight: .semibold),
                                                          colour: NSColor(white: 1, alpha: 0.92), mark: mark)
            let (body, bodyMarks) = HelpView.marked(row.entry.body, words, font: .systemFont(ofSize: 12.5),
                                                    colour: NSColor(white: 1, alpha: 0.62), mark: mark)
            row.heading.attributedStringValue = heading
            row.body.attributedStringValue = body
            marks += headingMarks + bodyMarks
        }
        isHidden = shown == 0
        return shown
    }
}

/// The "?" at the bottom of the main window's page list.
final class HelpButton: FocusButton {
    private var hovering = false { didSet { if hovering != oldValue { restyle() } } }
    var isActive = false { didSet { restyle() } }

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: 24, height: 24))
        title = ""
        isBordered = false
        image = NSImage(systemSymbolName: "questionmark", accessibilityDescription: L("Help"))?
            .withSymbolConfiguration(.init(pointSize: 11, weight: .bold))
        imagePosition = .imageOnly
        toolTip = L("Help") + "  ⌘?"
        setAccessibilityTitle(L("Help"))
        keyEquivalent = "?"
        keyEquivalentModifierMask = [.command]
        wantsLayer = true
        layer?.cornerRadius = 12
        layer?.borderWidth = 1
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(equalToConstant: 24).isActive = true
        heightAnchor.constraint(equalToConstant: 24).isActive = true
        restyle()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private func restyle() {
        let lit = hovering || isActive
        layer?.backgroundColor = NSColor(white: 1, alpha: isActive ? 0.16 : hovering ? 0.1 : 0.05).cgColor
        layer?.borderColor = NSColor(white: 1, alpha: lit ? 0.3 : 0.14).cgColor
        contentTintColor = NSColor(white: 1, alpha: lit ? 0.95 : 0.6)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                       owner: self))
    }

    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }
}
