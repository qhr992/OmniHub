import AppKit

/// Small builders shared by the terminal's drop-downs and settings.
enum FormKit {
    static func label(_ text: String, size: CGFloat = 11.5, alpha: CGFloat = 0.7) -> NSTextField {
        let field = NSTextField(labelWithString: L(text))
        field.font = .systemFont(ofSize: size)
        field.textColor = NSColor(white: 1, alpha: alpha)
        return field
    }

    static func field(_ placeholder: String, width: CGFloat? = nil) -> NSTextField {
        let field = NSTextField()
        field.placeholderString = L(placeholder)
        field.font = .systemFont(ofSize: 12)
        field.controlSize = .small
        field.translatesAutoresizingMaskIntoConstraints = false
        if let width { field.widthAnchor.constraint(equalToConstant: width).isActive = true }
        return field
    }

    static func popup(width: CGFloat? = nil) -> NSPopUpButton {
        let popup = FocusPopUp(frame: .zero, pullsDown: false)
        popup.controlSize = .small
        popup.font = .systemFont(ofSize: 11.5)
        popup.translatesAutoresizingMaskIntoConstraints = false
        if let width { popup.widthAnchor.constraint(equalToConstant: width).isActive = true }
        return popup
    }

    static func row(_ views: [NSView], spacing: CGFloat = 6) -> NSStackView {
        let stack = NSStackView(views: views)
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = spacing
        return stack
    }

    static func button(_ title: String, _ target: AnyObject, _ action: Selector) -> NSButton {
        let button = FocusButton(title: L(title), target: target, action: action)
        button.bezelStyle = .rounded
        button.controlSize = .small
        return button
    }

    /// Fills a pop-up with "none" plus the named items; selects `current`.
    static func fill(_ popup: NSPopUpButton, none: String, items: [(id: String, name: String)], current: String) {
        popup.removeAllItems()
        popup.addItem(withTitle: L(none))
        popup.lastItem?.representedObject = ""
        for item in items {
            popup.addItem(withTitle: item.name)
            popup.lastItem?.representedObject = item.id
        }
        let index = items.firstIndex { $0.id == current }.map { $0 + 1 } ?? 0
        popup.selectItem(at: index)
    }

    static func selectedID(_ popup: NSPopUpButton) -> String {
        popup.selectedItem?.representedObject as? String ?? ""
    }

    static var vaultItems: [(id: String, name: String)] {
        ConnectionStore.shared.vault.map { ($0.id, $0.account.isEmpty ? $0.name : "\($0.name) (\($0.account))") }
    }

    static var proxyItems: [(id: String, name: String)] {
        ConnectionStore.shared.proxies.map { ($0.id, "\($0.name) · \($0.kind)://\($0.host):\($0.port)") }
    }
}

// MARK: - Port forwarding

/// Drop-down of the Port forwarding button: the forwards of this connection and a
/// form for a new one.
final class ForwardsView: NSView, TabScope {
    private let session: TerminalSession
    private let list = NSStackView()
    private let kind = FormKit.popup(width: 150)
    private let listenPort = FormKit.field("Local port", width: 70)
    private let targetHost = FormKit.field("Target host", width: 130)
    private let targetPort = FormKit.field("Port", width: 60)
    private let proxy = FormKit.popup(width: 250)
    private let hint = FormKit.label("", size: 10.5, alpha: 0.5)
    private let arrow = FormKit.label("→")
    /// Forwards that already exist on the server (looked up on open).
    private(set) var serverTunnels: [ServerTunnel] = []
    private(set) var serverStatus = ""
    private var loadStamp = 0

    init(session: TerminalSession) {
        self.session = session
        super.init(frame: .zero)
        let title = FormKit.label(L("Port Forwarding · %@", session.target?.display ?? ""), size: 12, alpha: 1)
        title.font = .systemFont(ofSize: 12, weight: .semibold)
        title.lineBreakMode = .byTruncatingMiddle
        let refresh = NSButton(image: NSImage(systemSymbolName: "arrow.clockwise", accessibilityDescription: L("Refresh"))?
                                .withSymbolConfiguration(.init(pointSize: 11, weight: .medium)) ?? NSImage(),
                               target: self, action: #selector(loadServerTunnels))
        refresh.isBordered = false
        refresh.toolTip = L("Look up the forwards on the server again")
        refresh.contentTintColor = NSColor(white: 1, alpha: 0.75)

        list.orientation = .vertical
        list.alignment = .leading
        list.spacing = 5
        list.translatesAutoresizingMaskIntoConstraints = false
        let document = FlippedView()
        document.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(list)
        let scroll = NSScrollView()
        scroll.documentView = document
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false

        kind.addItems(withTitles: [L("Local (-L)"), L("Remote (-R)"), L("Dynamic SOCKS (-D)")])
        kind.target = self
        kind.action = #selector(kindChanged)
        targetHost.stringValue = "127.0.0.1"
        FormKit.fill(proxy, none: "No proxy (this connection)", items: FormKit.proxyItems, current: "")
        hint.lineBreakMode = .byWordWrapping
        hint.maximumNumberOfLines = 3
        hint.preferredMaxLayoutWidth = 440

        let add = FormKit.button("Add", self, #selector(addForward))
        let form = NSStackView(views: [
            FormKit.label("New forward", size: 10.5, alpha: 0.45),
            FormKit.row([kind, listenPort, arrow, targetHost, targetPort]),
            FormKit.row([FormKit.label("Proxy"), proxy, add]),
            hint
        ])
        form.orientation = .vertical
        form.alignment = .leading
        form.spacing = 6

        for view in [title, refresh, scroll, form] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            title.topAnchor.constraint(equalTo: topAnchor, constant: 10),
            title.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            title.trailingAnchor.constraint(lessThanOrEqualTo: refresh.leadingAnchor, constant: -8),
            refresh.centerYAnchor.constraint(equalTo: title.centerYAnchor),
            refresh.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            scroll.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 8),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            scroll.bottomAnchor.constraint(equalTo: form.topAnchor, constant: -8),
            form.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            form.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -12),
            form.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -10),
            document.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            document.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            document.trailingAnchor.constraint(equalTo: scroll.contentView.trailingAnchor),
            list.topAnchor.constraint(equalTo: document.topAnchor),
            list.leadingAnchor.constraint(equalTo: document.leadingAnchor),
            list.trailingAnchor.constraint(equalTo: document.trailingAnchor, constant: -6),
            list.bottomAnchor.constraint(equalTo: document.bottomAnchor)
        ])
        kindChanged()
        reload()
        loadServerTunnels()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    /// Asks the server which forwards it already has.
    @objc func loadServerTunnels() {
        guard let target = session.target, target.isSSH else { return }
        loadStamp += 1
        let mine = loadStamp
        serverStatus = L("Looking up the server…")
        reload()
        ServerTunnels.load(target) { [weak self] result in
            guard let self, self.loadStamp == mine else { return }
            switch result {
            case .success(let tunnels):
                // Remote forwards opened from this tab show up as sshd
                // listeners there; they are already listed above.
                let mine = Set(self.session.forwards.filter { $0.kind == "R" }.map(\.listenPort))
                self.serverTunnels = tunnels.filter { !($0.source == .listener && $0.listenPort.map(mine.contains) == true) }
                self.serverStatus = self.serverTunnels.isEmpty ? L("No forwards found on the server.") : ""
            case .failure(let error):
                self.serverTunnels = []
                self.serverStatus = L("Could not look up the server: %@", error.localizedDescription)
            }
            self.reload()
        }
    }

    private func section(_ text: String) {
        let label = FormKit.label(text, size: 10.5, alpha: 0.45)
        label.font = .systemFont(ofSize: 10.5, weight: .semibold)
        list.addArrangedSubview(label)
    }

    private func dot(_ color: NSColor) -> NSView {
        let dot = NSView()
        dot.wantsLayer = true
        dot.layer?.cornerRadius = 3.5
        dot.layer?.backgroundColor = color.cgColor
        dot.translatesAutoresizingMaskIntoConstraints = false
        dot.widthAnchor.constraint(equalToConstant: 7).isActive = true
        dot.heightAnchor.constraint(equalToConstant: 7).isActive = true
        return dot
    }

    private func addRow(_ views: [NSView]) {
        let row = FormKit.row(views)
        row.translatesAutoresizingMaskIntoConstraints = false
        list.addArrangedSubview(row)
        row.widthAnchor.constraint(equalTo: list.widthAnchor).isActive = true
    }

    private func appendServerRows() {
        section(L("ON THE SERVER"))
        if !serverStatus.isEmpty {
            let note = FormKit.label(serverStatus, size: 11.5, alpha: 0.5)
            note.lineBreakMode = .byTruncatingTail
            note.toolTip = serverStatus
            list.addArrangedSubview(note)
        }
        for tunnel in serverTunnels {
            let text = FormKit.label(tunnel.summary, size: 11.5, alpha: 0.95)
            text.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
            text.lineBreakMode = .byTruncatingMiddle
            text.toolTip = tunnel.summary
            text.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            let state = FormKit.label(tunnel.state, size: 10.5, alpha: 0.55)
            state.lineBreakMode = .byTruncatingTail
            state.toolTip = tunnel.state
            state.setContentCompressionResistancePriority(.init(200), for: .horizontal)
            let gap = NSView()
            gap.setContentHuggingPriority(.init(1), for: .horizontal)
            let color: NSColor = tunnel.source == .config ? NSColor(white: 1, alpha: 0.35) : .systemTeal
            addRow([dot(color), text, state, gap])
        }
    }

    var debugServerRows: [String] { serverTunnels.map { "\($0.summary) | \($0.state)" } }

    private var kindCode: String { ["L", "R", "D"][max(0, kind.indexOfSelectedItem)] }

    @objc private func kindChanged() {
        let dynamic = kindCode == "D"
        targetHost.isHidden = dynamic
        targetPort.isHidden = dynamic
        arrow.isHidden = dynamic
        listenPort.placeholderString = kindCode == "R" ? L("Server port") : L("Local port")
        switch kindCode {
        case "L": hint.stringValue = L("This local port reaches target host:port as seen from the server (127.0.0.1 = the server itself).")
        case "R": hint.stringValue = L("This port on the server reaches target host:port as seen from this Mac.")
        default: hint.stringValue = L("Opens a local SOCKS5 port; traffic leaves from the server.")
        }
        if FormKit.selectedID(proxy) != "" {
            hint.stringValue += L(" With a proxy, the forward gets its own connection through it (credentials: Terminal Settings → Proxies).")
        }
    }

    func reload() {
        for view in list.arrangedSubviews {
            list.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        section(L("THIS CONNECTION"))
        if session.forwards.isEmpty {
            list.addArrangedSubview(FormKit.label("No forwards on this connection.", size: 11.5, alpha: 0.5))
        }
        for forward in session.forwards {
            let dot = NSView()
            dot.wantsLayer = true
            dot.layer?.cornerRadius = 3.5
            dot.layer?.backgroundColor = (forward.active ? NSColor.systemGreen
                                          : (forward.state == L("Starting…") ? NSColor.systemYellow : NSColor.systemRed)).cgColor
            dot.translatesAutoresizingMaskIntoConstraints = false
            dot.widthAnchor.constraint(equalToConstant: 7).isActive = true
            dot.heightAnchor.constraint(equalToConstant: 7).isActive = true
            let text = FormKit.label(forward.summary, size: 11.5, alpha: 0.95)
            text.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
            text.lineBreakMode = .byTruncatingMiddle
            text.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            let state = FormKit.label(forward.state, size: 10.5, alpha: 0.55)
            state.lineBreakMode = .byTruncatingTail
            state.setContentCompressionResistancePriority(.init(200), for: .horizontal)
            let gap = NSView()
            gap.setContentHuggingPriority(.init(1), for: .horizontal)
            let remove = NSButton(image: NSImage(systemSymbolName: "trash", accessibilityDescription: L("Stop")) ?? NSImage(),
                                  target: self, action: #selector(removeForward(_:)))
            remove.isBordered = false
            remove.toolTip = L("Stop this forward")
            remove.contentTintColor = NSColor(white: 1, alpha: 0.7)
            remove.identifier = NSUserInterfaceItemIdentifier(forward.id)
            addRow([dot, text, state, gap, remove])
        }
        if session.target?.isSSH == true { appendServerRows() }
    }

    @objc private func removeForward(_ sender: NSButton) {
        guard let id = sender.identifier?.rawValue else { return }
        session.removeForward(id)
    }

    @objc private func addForward() {
        let code = kindCode
        guard let listen = Int(listenPort.stringValue.trimmingCharacters(in: .whitespaces)), (1...65535).contains(listen) else {
            hint.stringValue = L("Enter a port between 1 and 65535.")
            return
        }
        var host = "", port = 0
        if code != "D" {
            host = targetHost.stringValue.trimmingCharacters(in: .whitespaces)
            guard !host.isEmpty, let value = Int(targetPort.stringValue.trimmingCharacters(in: .whitespaces)),
                  (1...65535).contains(value) else {
                hint.stringValue = L("Enter a target host and a port between 1 and 65535.")
                return
            }
            port = value
        }
        session.addForward(kind: code, bind: "", listenPort: listen, targetHost: host, targetPort: port,
                           proxyID: FormKit.selectedID(proxy))
        listenPort.stringValue = ""
        targetPort.stringValue = ""
    }
}

// MARK: - Connections (picker)

/// Drop-down of the Connections button: type to filter the saved profiles,
/// or type an ssh / telnet command and press Return.
final class ConnectionPickerView: NSView, TabScope, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate {
    var onConnect: ((RemoteTarget) -> Void)?
    var onManage: (() -> Void)?
    let searchField = NSSearchField()
    private let tableView = NSTableView()

    private enum Row {
        case group(String)
        case profile(ConnectionProfile)
        case command(RemoteTarget, String)
    }
    private var rows: [Row] = []

    init() {
        super.init(frame: .zero)
        searchField.placeholderString = L("Search, or type ssh user@host -p 22 ⏎")
        searchField.font = .systemFont(ofSize: 12)
        searchField.delegate = self

        tableView.headerView = nil
        tableView.rowHeight = 36
        tableView.backgroundColor = .clear
        if #available(macOS 11.0, *) { tableView.style = .plain }
        tableView.dataSource = self
        tableView.delegate = self
        tableView.target = self
        tableView.action = #selector(rowClicked)
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("main"))
        column.resizingMask = .autoresizingMask
        tableView.addTableColumn(column)
        let scroll = NSScrollView()
        scroll.documentView = tableView
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false

        let manage = NSButton(title: L("Manage Connections…"), target: self, action: #selector(manage))
        manage.bezelStyle = .inline
        manage.controlSize = .small

        for view in [searchField, scroll, manage] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            searchField.topAnchor.constraint(equalTo: topAnchor, constant: 10),
            searchField.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            searchField.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            scroll.topAnchor.constraint(equalTo: searchField.bottomAnchor, constant: 8),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            scroll.bottomAnchor.constraint(equalTo: manage.topAnchor, constant: -6),
            manage.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            manage.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8)
        ])
        reload()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    var debugRows: [String] {
        rows.map {
            switch $0 {
            case .group(let name): return "[\(name)]"
            case .profile(let profile): return "\(profile.name) \(profile.summary)"
            case .command(_, let text): return "→ \(text)"
            }
        }
    }
    func debugType(_ text: String) { searchField.stringValue = text; reload() }

    private func reload() {
        let query = searchField.stringValue.trimmingCharacters(in: .whitespaces)
        var result: [Row] = []
        let all = ConnectionStore.shared.profiles
        let matches = query.isEmpty ? all : all.filter {
            [$0.name, $0.host, $0.user, $0.group].contains { $0.localizedCaseInsensitiveContains(query) }
        }
        // Something that reads like a command line can be run as it is.
        let looksLikeCommand = query.hasPrefix("ssh ") || query.hasPrefix("telnet ") || query.contains("@")
        if !query.isEmpty, looksLikeCommand || matches.isEmpty, let target = RemoteTarget(commandLine: query) {
            let text = target.kind == "telnet" ? "telnet \(target.host) \(target.port)" : "ssh " + (target.rawArguments ?? []).joined(separator: " ")
            result.append(.command(target, text))
        }
        let grouped = Dictionary(grouping: matches) { $0.group }
        for group in grouped.keys.sorted(by: { ($0.isEmpty ? "~" : $0) < ($1.isEmpty ? "~" : $1) }) {
            result.append(.group(group.isEmpty ? L("Ungrouped") : group))
            for profile in (grouped[group] ?? []).sorted(by: { $0.name.localizedStandardCompare($1.name) == .orderedAscending }) {
                result.append(.profile(profile))
            }
        }
        rows = result
        tableView.reloadData()
        if let first = rows.firstIndex(where: { if case .group = $0 { return false } else { return true } }) {
            tableView.selectRowIndexes(IndexSet(integer: first), byExtendingSelection: false)
        }
    }

    func controlTextDidChange(_ obj: Notification) { reload() }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        switch commandSelector {
        case #selector(NSResponder.moveDown(_:)): moveSelection(1); return true
        case #selector(NSResponder.moveUp(_:)): moveSelection(-1); return true
        case #selector(NSResponder.insertNewline(_:)): activate(tableView.selectedRow); return true
        default: return false
        }
    }

    private func moveSelection(_ delta: Int) {
        var index = tableView.selectedRow + delta
        while rows.indices.contains(index) {
            if case .group = rows[index] { index += delta; continue }
            tableView.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
            tableView.scrollRowToVisible(index)
            return
        }
    }

    @objc private func rowClicked() { activate(tableView.clickedRow) }
    @objc private func manage() { onManage?() }

    func activate(_ index: Int) {
        guard rows.indices.contains(index) else { return }
        switch rows[index] {
        case .group: return
        case .profile(let profile):
            guard !profile.host.isEmpty else { return }
            onConnect?(RemoteTarget(profile: profile))
        case .command(let target, _):
            onConnect?(target)
        }
    }

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }
    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        if case .group = rows[row] { return false }
        return true
    }
    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        if case .group = rows[row] { return 20 }
        return 36
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let cell = NSTableCellView()
        switch rows[row] {
        case .group(let name):
            let label = FormKit.label(name, size: 10.5, alpha: 0.5)
            label.font = .systemFont(ofSize: 10.5, weight: .semibold)
            label.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(label)
            NSLayoutConstraint.activate([label.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 6),
                                         label.centerYAnchor.constraint(equalTo: cell.centerYAnchor)])
        case .profile(let profile):
            fill(cell, symbol: profile.kind == "telnet" ? "antenna.radiowaves.left.and.right" : "network",
                 title: profile.name, detail: (profile.kind == "telnet" ? "telnet · " : "ssh · ") + profile.summary)
        case .command(_, let text):
            fill(cell, symbol: "return", title: L("Connect"), detail: text)
        }
        return cell
    }

    private func fill(_ cell: NSView, symbol: String, title: String, detail: String) {
        let icon = NSImageView()
        icon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        icon.contentTintColor = NSColor(srgbRed: 0.45, green: 0.85, blue: 1.0, alpha: 1)
        let name = FormKit.label(title, size: 12, alpha: 1)
        name.font = .systemFont(ofSize: 12, weight: .medium)
        let info = FormKit.label(detail, size: 10.5, alpha: 0.55)
        info.font = .monospacedSystemFont(ofSize: 10, weight: .regular)
        info.lineBreakMode = .byTruncatingMiddle
        for view in [icon, name, info] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(view)
        }
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 6),
            icon.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 18),
            name.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 8),
            name.topAnchor.constraint(equalTo: cell.topAnchor, constant: 3),
            name.trailingAnchor.constraint(lessThanOrEqualTo: cell.trailingAnchor, constant: -6),
            info.leadingAnchor.constraint(equalTo: name.leadingAnchor),
            info.topAnchor.constraint(equalTo: name.bottomAnchor, constant: 0),
            info.trailingAnchor.constraint(lessThanOrEqualTo: cell.trailingAnchor, constant: -6)
        ])
    }
}
