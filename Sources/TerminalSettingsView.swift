import AppKit

/// Terminal settings, opened with the gear at the top right of the terminal
/// page: Connections · Vault · Proxies. A click outside the panel closes it.
final class TerminalSettingsView: NSView {
    var onClose: (() -> Void)?
    private let segments = NSSegmentedControl(labels: ["Connections", "Vault", "Proxies"], trackingMode: .selectOne,
                                              target: nil, action: nil)
    private let editors: [ListEditor] = [ProfilesEditor(), VaultEditor(), ProxiesEditor()]
    private let host = NSView()

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor(srgbRed: 0.09, green: 0.09, blue: 0.12, alpha: 1).cgColor
        layer?.cornerRadius = 12
        layer?.masksToBounds = true
        layer?.borderWidth = 1
        layer?.borderColor = NSColor(white: 1, alpha: 0.16).cgColor
        // Same backdrop as the card, under a heavier veil.
        let backdrop = NSView()
        backdrop.wantsLayer = true
        backdrop.layer?.contentsGravity = .resizeAspectFill
        backdrop.layer?.masksToBounds = true
        if let image = Artwork.background {
            var rect = NSRect(origin: .zero, size: image.size)
            backdrop.layer?.contents = image.cgImage(forProposedRect: &rect, context: nil, hints: nil)
        }
        let veil = NSView()
        veil.wantsLayer = true
        veil.layer?.backgroundColor = NSColor(srgbRed: 0.06, green: 0.06, blue: 0.10, alpha: 0.86).cgColor
        for view in [backdrop, veil] {
            view.autoresizingMask = [.width, .height]
            view.frame = bounds
            addSubview(view)
        }

        segments.target = self
        segments.action = #selector(segmentChanged)
        segments.controlSize = .small
        let done = NSButton(image: NSImage(systemSymbolName: "xmark", accessibilityDescription: "Close") ?? NSImage(),
                            target: self, action: #selector(close))
        done.isBordered = false
        done.toolTip = "Close"
        done.contentTintColor = NSColor(white: 1, alpha: 0.8)
        let title = FormKit.label("Terminal Settings", size: 12, alpha: 1)
        title.font = .systemFont(ofSize: 12, weight: .semibold)

        for view in [title, segments, done, host] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            title.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            title.centerYAnchor.constraint(equalTo: segments.centerYAnchor),
            segments.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            segments.centerXAnchor.constraint(equalTo: centerXAnchor),
            done.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            done.centerYAnchor.constraint(equalTo: segments.centerYAnchor),
            done.widthAnchor.constraint(equalToConstant: 22),
            done.heightAnchor.constraint(equalToConstant: 22),
            host.topAnchor.constraint(equalTo: segments.bottomAnchor, constant: 8),
            host.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            host.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            host.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -10)
        ])
        select(tab: 0)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    /// A click on the panel's own background must not reach the terminal.
    override func mouseDown(with event: NSEvent) {}

    func select(tab: Int) {
        let index = min(max(tab, 0), editors.count - 1)
        commit()
        segments.selectedSegment = index
        host.subviews.forEach { $0.removeFromSuperview() }
        let editor = editors[index]
        editor.frame = host.bounds
        editor.autoresizingMask = [.width, .height]
        host.addSubview(editor)
        editor.refresh()
    }

    /// Saves whatever is being edited.
    func commit() { editors.forEach { $0.commit() } }

    @objc private func segmentChanged() { select(tab: segments.selectedSegment) }
    @objc private func close() { onClose?() }

    var debugEditor: ListEditor { editors[max(0, segments.selectedSegment)] }
}

// MARK: - List + form scaffold

/// A list on the left (New / Duplicate / Delete below it) and a form for the
/// selected item on the right. Edits are saved when the selection changes,
/// the panel closes, or Save is pressed.
class ListEditor: NSView, NSTableViewDataSource, NSTableViewDelegate {
    struct Item {
        /// nil = a group heading.
        let id: String?
        let title: String
        let detail: String
    }

    let tableView = NSTableView()
    let form = NSStackView()
    /// Stays at the bottom of the form, outside its scroll area (Save…).
    let footer = NSStackView()
    let emptyLabel = FormKit.label("", size: 12, alpha: 0.5)
    private(set) var items: [Item] = []
    var selectedID: String?
    private var cloneButton: NSButton!
    private var deleteButton: NSButton!
    private var loading = false

    // Subclass hooks.
    var supportsClone: Bool { false }
    var emptyText: String { "" }
    func loadItems() -> [Item] { [] }
    func buildForm() {}
    func fillForm(_ id: String) {}
    func commit() {}
    func createItem() -> String { "" }
    func cloneItem(_ id: String) -> String? { nil }
    func deleteItem(_ id: String) {}

    init() {
        super.init(frame: .zero)
        tableView.headerView = nil
        tableView.rowHeight = 34
        tableView.backgroundColor = .clear
        if #available(macOS 11.0, *) { tableView.style = .plain }
        tableView.dataSource = self
        tableView.delegate = self
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("main"))
        column.resizingMask = .autoresizingMask
        tableView.addTableColumn(column)
        let scroll = NSScrollView()
        scroll.documentView = tableView
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.wantsLayer = true
        scroll.layer?.backgroundColor = NSColor(white: 1, alpha: 0.05).cgColor
        scroll.layer?.cornerRadius = 7

        func icon(_ symbol: String, _ tooltip: String, _ action: Selector) -> NSButton {
            let image = NSImage(systemSymbolName: symbol, accessibilityDescription: tooltip)?
                .withSymbolConfiguration(.init(pointSize: 12, weight: .medium))
            let button = NSButton(image: image ?? NSImage(), target: self, action: action)
            button.isBordered = false
            button.toolTip = tooltip
            button.contentTintColor = NSColor(white: 1, alpha: 0.8)
            button.translatesAutoresizingMaskIntoConstraints = false
            button.widthAnchor.constraint(equalToConstant: 26).isActive = true
            button.heightAnchor.constraint(equalToConstant: 22).isActive = true
            return button
        }
        let add = icon("plus", "New", #selector(addTapped))
        cloneButton = icon("doc.on.doc", "Duplicate", #selector(cloneTapped))
        deleteButton = icon("trash", "Delete", #selector(deleteTapped))
        cloneButton.isHidden = !supportsClone
        let buttons = FormKit.row([add, cloneButton, deleteButton], spacing: 2)

        form.orientation = .vertical
        form.alignment = .leading
        form.spacing = 7
        let formScroll = NSScrollView()
        let document = FlippedView()
        document.translatesAutoresizingMaskIntoConstraints = false
        form.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(form)
        formScroll.documentView = document
        formScroll.hasVerticalScroller = true
        formScroll.drawsBackground = false
        emptyLabel.lineBreakMode = .byWordWrapping
        emptyLabel.maximumNumberOfLines = 4
        emptyLabel.preferredMaxLayoutWidth = 420

        footer.orientation = .vertical
        footer.alignment = .leading
        footer.spacing = 4
        for view in [scroll, buttons, formScroll, footer, emptyLabel] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        // List on the left, details on the right, 2 : 5 (the 14 pt gap
        // between them is shared out the same way).
        let listLayout = [
            scroll.topAnchor.constraint(equalTo: topAnchor),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.widthAnchor.constraint(equalTo: widthAnchor, multiplier: 2.0 / 7.0, constant: -4),
            scroll.bottomAnchor.constraint(equalTo: buttons.topAnchor, constant: -6),
            buttons.leadingAnchor.constraint(equalTo: leadingAnchor),
            buttons.bottomAnchor.constraint(equalTo: bottomAnchor),
            formScroll.topAnchor.constraint(equalTo: topAnchor),
            formScroll.leadingAnchor.constraint(equalTo: scroll.trailingAnchor, constant: 14),
            emptyLabel.topAnchor.constraint(equalTo: topAnchor, constant: 30),
            emptyLabel.leadingAnchor.constraint(equalTo: scroll.trailingAnchor, constant: 24),
            emptyLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -8)
        ]
        NSLayoutConstraint.activate([
            formScroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            formScroll.bottomAnchor.constraint(equalTo: footer.topAnchor, constant: -8),
            footer.leadingAnchor.constraint(equalTo: formScroll.leadingAnchor),
            footer.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
            footer.bottomAnchor.constraint(equalTo: bottomAnchor),
            document.topAnchor.constraint(equalTo: formScroll.contentView.topAnchor),
            document.leadingAnchor.constraint(equalTo: formScroll.contentView.leadingAnchor),
            document.trailingAnchor.constraint(equalTo: formScroll.contentView.trailingAnchor),
            form.topAnchor.constraint(equalTo: document.topAnchor, constant: 2),
            form.leadingAnchor.constraint(equalTo: document.leadingAnchor),
            form.trailingAnchor.constraint(lessThanOrEqualTo: document.trailingAnchor, constant: -8),
            form.bottomAnchor.constraint(equalTo: document.bottomAnchor, constant: -4)
        ] + listLayout)
        emptyLabel.preferredMaxLayoutWidth = 300
        buildForm()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    /// Widths of the list and the details column (test hook).
    var debugColumns: (list: CGFloat, form: CGFloat) {
        layoutSubtreeIfNeeded()
        let list = subviews.first { ($0 as? NSScrollView)?.documentView is NSTableView }?.frame ?? .zero
        return (list.width, bounds.width - list.maxX - 14)
    }

    /// One "label: control" line of the form.
    func line(_ title: String, _ views: NSView...) -> NSStackView {
        let name = FormKit.label(title)
        name.alignment = .right
        name.translatesAutoresizingMaskIntoConstraints = false
        name.widthAnchor.constraint(equalToConstant: 58).isActive = true
        return FormKit.row([name] + views, spacing: 8)
    }

    /// Re-reads the store and keeps (or picks) a selection.
    func refresh(select id: String? = nil) {
        items = loadItems()
        let wanted = id ?? selectedID
        selectedID = items.contains { $0.id == wanted && wanted != nil } ? wanted : items.first { $0.id != nil }?.id
        loading = true
        tableView.reloadData()
        if let selectedID, let index = items.firstIndex(where: { $0.id == selectedID }) {
            tableView.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
        }
        loading = false
        showSelection()
    }

    private func showSelection() {
        let has = selectedID != nil
        form.isHidden = !has
        footer.isHidden = !has
        emptyLabel.isHidden = has
        emptyLabel.stringValue = emptyText
        cloneButton.isEnabled = has
        deleteButton.isEnabled = has
        if let selectedID { fillForm(selectedID) }
    }

    /// "Saved ✓" beside the Save button; fades out by itself.
    let savedNote = FormKit.label("", size: 11, alpha: 1)
    private var savedStamp = 0

    /// The Save button with its confirmation (and anything else on that line).
    func saveRow(_ extra: NSView...) -> NSStackView {
        savedNote.textColor = .systemGreen
        return FormKit.row([FormKit.button("Save", self, #selector(saveTapped)), savedNote] + extra, spacing: 8)
    }

    @objc func saveTapped() {
        commit()
        refresh()
        savedNote.stringValue = "Saved ✓"
        savedNote.alphaValue = 1
        savedStamp += 1
        let mine = savedStamp
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            guard let self, self.savedStamp == mine else { return }
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.4
                self.savedNote.animator().alphaValue = 0
            }
        }
    }

    @objc private func addTapped() {
        commit()
        refresh(select: createItem())
    }

    @objc private func cloneTapped() {
        guard let id = selectedID else { return }
        commit()
        refresh(select: cloneItem(id))
    }

    @objc private func deleteTapped() {
        guard let id = selectedID else { return }
        selectedID = nil
        deleteItem(id)
        refresh()
    }

    // Test hooks.
    func debugAdd() { addTapped() }
    func debugClone() { cloneTapped() }
    func debugDelete() { deleteTapped() }
    var debugList: [String] { items.map { $0.id == nil ? "[\($0.title)]" : "\($0.title) | \($0.detail)" } }

    func numberOfRows(in tableView: NSTableView) -> Int { items.count }
    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool { items[row].id != nil }
    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat { items[row].id == nil ? 20 : 34 }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !loading, tableView.selectedRow >= 0, tableView.selectedRow < items.count,
              let id = items[tableView.selectedRow].id, id != selectedID else { return }
        commit()
        refresh(select: id)
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let item = items[row]
        let cell = NSTableCellView()
        let title = FormKit.label(item.title, size: item.id == nil ? 10.5 : 12, alpha: item.id == nil ? 0.5 : 1)
        title.font = .systemFont(ofSize: item.id == nil ? 10.5 : 12, weight: item.id == nil ? .semibold : .medium)
        title.lineBreakMode = .byTruncatingTail
        title.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(title)
        if item.id == nil {
            NSLayoutConstraint.activate([title.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 6),
                                         title.centerYAnchor.constraint(equalTo: cell.centerYAnchor)])
            return cell
        }
        let detail = FormKit.label(item.detail, size: 10, alpha: 0.5)
        detail.lineBreakMode = .byTruncatingMiddle
        detail.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(detail)
        NSLayoutConstraint.activate([
            title.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 8),
            title.topAnchor.constraint(equalTo: cell.topAnchor, constant: 3),
            title.trailingAnchor.constraint(lessThanOrEqualTo: cell.trailingAnchor, constant: -6),
            detail.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            detail.topAnchor.constraint(equalTo: title.bottomAnchor),
            detail.trailingAnchor.constraint(lessThanOrEqualTo: cell.trailingAnchor, constant: -6)
        ])
        return cell
    }
}

// MARK: - Connections

final class ProfilesEditor: ListEditor {
    private let name = FormKit.field("Display name", width: 220)
    private let group = NSComboBox()
    private let kind = FormKit.popup(width: 90)
    private let host = FormKit.field("Host name or IP", width: 190)
    private let port = FormKit.field("22", width: 60)
    private let credential = FormKit.popup(width: 220)
    private let user = FormKit.field("Username (optional)", width: 160)
    private let password = NSSecureTextField()
    private let vaultNote = FormKit.label("", size: 10.5, alpha: 0.5)
    private var passwordLines: [NSView] = []
    private var vaultNoteLine: NSView?
    private let keyPath = FormKit.field("Private key file (optional)", width: 220)
    private let proxy = FormKit.popup(width: 290)
    private let stepsStack = NSStackView()
    private let testResult = FormKit.label("", size: 11, alpha: 1)
    private var sshOnly: [NSView] = []

    override var supportsClone: Bool { true }
    override var emptyText: String { "No saved connections. Press + to add one, or type an ssh command in the Connections box." }

    override func loadItems() -> [Item] {
        var result: [Item] = []
        let grouped = Dictionary(grouping: ConnectionStore.shared.profiles) { $0.group }
        for key in grouped.keys.sorted(by: { ($0.isEmpty ? "~" : $0) < ($1.isEmpty ? "~" : $1) }) {
            result.append(Item(id: nil, title: key.isEmpty ? "Ungrouped" : key, detail: ""))
            for profile in (grouped[key] ?? []).sorted(by: { $0.name.localizedStandardCompare($1.name) == .orderedAscending }) {
                result.append(Item(id: profile.id, title: profile.name, detail: "\(profile.kind) · \(profile.summary)"))
            }
        }
        return result
    }

    override func buildForm() {
        group.font = .systemFont(ofSize: 12)
        group.controlSize = .small
        group.placeholderString = "Group"
        group.translatesAutoresizingMaskIntoConstraints = false
        group.widthAnchor.constraint(equalToConstant: 160).isActive = true
        kind.addItems(withTitles: ["SSH", "Telnet"])
        kind.target = self
        kind.action = #selector(kindChanged)
        let choose = FormKit.button("Choose…", self, #selector(chooseKey))

        stepsStack.orientation = .vertical
        stepsStack.alignment = .leading
        stepsStack.spacing = 4
        let addStep = FormKit.button("+ Add command", self, #selector(addStep))
        let stepHint = FormKit.label("Commands run in order after login. If a command asks for something (e.g. a password), pick a Vault entry or type a reply: it is sent, followed by Return, once the prompt shows. Leave “Prompt” empty to match any password or (yes/no) prompt.",
                                     size: 10.5, alpha: 0.5)
        stepHint.lineBreakMode = .byWordWrapping
        stepHint.maximumNumberOfLines = 4
        stepHint.preferredMaxLayoutWidth = 480

        credential.target = self
        credential.action = #selector(credentialChanged)
        credential.toolTip = "Username & Password typed here, or a Vault entry (its Username is used)."
        password.placeholderString = "Empty = ask when connecting"
        password.font = .systemFont(ofSize: 12)
        password.controlSize = .small
        password.translatesAutoresizingMaskIntoConstraints = false
        password.widthAnchor.constraint(equalToConstant: 160).isActive = true
        let userLine = line("Username", user)
        let passwordLine = line("Password", password)
        passwordLines = [userLine, passwordLine]
        let noteLine = line("", vaultNote)
        noteLine.isHidden = true
        vaultNoteLine = noteLine
        let keyLine = line("Key", keyPath, choose)
        sshOnly = [keyLine]
        let heading = FormKit.label("Run after login", size: 10.5, alpha: 0.45)
        heading.font = .systemFont(ofSize: 10.5, weight: .semibold)
        testResult.lineBreakMode = .byTruncatingTail
        testResult.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        for view in [line("Name", name), line("Group", group, FormKit.label("Type"), kind),
                     line("Host", host, FormKit.label("Port"), port), line("Credential", credential),
                     noteLine, userLine, passwordLine, keyLine, line("Proxy", proxy), heading, stepsStack, addStep, stepHint] as [NSView] {
            form.addArrangedSubview(view)
        }
        footer.addArrangedSubview(saveRow(FormKit.button("Test Connection", self, #selector(testTapped)), testResult))
        form.setCustomSpacing(12, after: form.arrangedSubviews[8])
    }

    @objc private func kindChanged() {
        let ssh = kind.indexOfSelectedItem == 0
        sshOnly.forEach { $0.isHidden = !ssh }
        // Switching type moves the port to that protocol's default.
        if port.stringValue == "22" || port.stringValue == "23" || port.stringValue.isEmpty {
            port.stringValue = ssh ? "22" : "23"
        }
    }

    @objc private func chooseKey() {
        let panel = NSOpenPanel()
        panel.directoryURL = URL(fileURLWithPath: NSHomeDirectory() + "/.ssh")
        panel.showsHiddenFiles = true
        panel.message = "Choose a private key"
        NSApp.activate(ignoringOtherApps: true)
        if panel.runModal() == .OK, let url = panel.url { keyPath.stringValue = url.path }
    }

    override func fillForm(_ id: String) {
        guard let profile = ConnectionStore.shared.profile(id) else { return }
        name.stringValue = profile.name
        group.removeAllItems()
        group.addItems(withObjectValues: ConnectionStore.shared.groups)
        group.stringValue = profile.group
        kind.selectItem(at: profile.kind == "telnet" ? 1 : 0)
        host.stringValue = profile.host
        port.stringValue = "\(profile.port)"
        user.stringValue = profile.user
        fillCredential(profile)
        keyPath.stringValue = profile.keyPath
        FormKit.fill(proxy, none: "No proxy", items: FormKit.proxyItems, current: profile.proxyID)
        for view in stepsStack.arrangedSubviews {
            stepsStack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        profile.steps.forEach { appendStepRow($0) }
        sshOnly.forEach { $0.isHidden = profile.kind == "telnet" }
        testResult.stringValue = ""
    }

    /// Credential list: "Username & Password" first (typed here; the
    /// password goes to the Keychain), then the Vault entries.
    private func fillCredential(_ profile: ConnectionProfile) {
        let current = profile.vaultEntry == nil ? "" : profile.secretID
        FormKit.fill(credential, none: "Username & Password",
                     items: FormKit.vaultItems.map { ($0.id, "Vault: \($0.name)") }, current: current)
        password.stringValue = profile.secretID == profile.ownSecretID ? (Vault.secret(for: profile.ownSecretID) ?? "") : ""
        credentialChanged()
    }

    /// Username & Password shows the two fields; a Vault entry shows which
    /// user it logs in as instead.
    @objc private func credentialChanged() {
        let entryID = FormKit.selectedID(credential)
        let entry = ConnectionStore.shared.vault.first { $0.id == entryID }
        passwordLines.forEach { $0.isHidden = entry != nil }
        vaultNoteLine?.isHidden = entry == nil
        if let entry {
            vaultNote.stringValue = entry.account.isEmpty ? "No username: none is sent" : "Logs in as \(entry.account)"
            vaultNote.toolTip = entry.account.isEmpty
                ? "This Vault entry has no Username: no account name is sent."
                : "Logs in with the Vault entry's Username."
        }
    }

    /// Test hooks.
    func debugCredential(user: String, password: String) {
        credential.selectItem(at: 0)
        credentialChanged()
        self.user.stringValue = user
        self.password.stringValue = password
        saveTapped()
    }
    func debugCredential(vaultID: String) {
        if let index = credential.itemArray.firstIndex(where: { $0.representedObject as? String == vaultID }) {
            credential.selectItem(at: index)
        }
        credentialChanged()
        saveTapped()
    }
    var debugCredentialChoice: String { credential.titleOfSelectedItem ?? "" }
    var debugPasswordFieldsShown: Bool { passwordLines.allSatisfy { !$0.isHidden } }
    var debugVaultNote: String { vaultNoteLine?.isHidden != false ? "" : vaultNote.stringValue }

    private func appendStepRow(_ step: AutoStep) {
        let row = StepRow(step: step)
        row.onRemove = { [weak self, weak row] in
            guard let self, let row else { return }
            self.stepsStack.removeArrangedSubview(row)
            row.removeFromSuperview()
        }
        stepsStack.addArrangedSubview(row)
    }

    @objc private func addStep() { appendStepRow(AutoStep()) }

    override func commit() {
        guard let id = selectedID, var profile = ConnectionStore.shared.profile(id) else { return }
        let before = profile
        let trimmed = name.stringValue.trimmingCharacters(in: .whitespaces)
        profile.name = trimmed.isEmpty ? "Untitled" : trimmed
        profile.group = group.stringValue.trimmingCharacters(in: .whitespaces)
        profile.kind = kind.indexOfSelectedItem == 1 ? "telnet" : "ssh"
        profile.host = host.stringValue.trimmingCharacters(in: .whitespaces)
        profile.port = Int(port.stringValue.trimmingCharacters(in: .whitespaces)) ?? (profile.kind == "telnet" ? 23 : 22)
        profile.user = user.stringValue.trimmingCharacters(in: .whitespaces)
        let entryID = FormKit.selectedID(credential)
        if !entryID.isEmpty {
            profile.secretID = entryID
        } else if password.stringValue.isEmpty {
            // Nothing typed: ask when connecting.
            Vault.remove(profile.ownSecretID)
            profile.secretID = ""
        } else {
            if Vault.secret(for: profile.ownSecretID) != password.stringValue {
                _ = Vault.set(password.stringValue, for: profile.ownSecretID)
            }
            profile.secretID = profile.ownSecretID
        }
        profile.keyPath = keyPath.stringValue.trimmingCharacters(in: .whitespaces)
        profile.proxyID = FormKit.selectedID(proxy)
        profile.steps = stepsStack.arrangedSubviews.compactMap { ($0 as? StepRow)?.value }.filter { !$0.send.isEmpty }
        if profile != before { ConnectionStore.shared.upsert(profile) }
    }

    /// Saves the form, then tries to log in (ssh) or reach the port (Telnet).
    @objc private func testTapped() {
        commit()
        refresh()
        guard let id = selectedID, let profile = ConnectionStore.shared.profile(id) else { return }
        guard !profile.host.isEmpty else {
            show(test: "Enter a host first.", ok: false)
            return
        }
        testResult.textColor = NSColor(white: 1, alpha: 0.6)
        testResult.stringValue = "Testing…"
        let (arguments, environment) = RemoteTarget(profile: profile).testLaunch()
        let started = Date()
        Subprocess.run(arguments, environment: environment) { [weak self] result in
            guard let self, self.selectedID == id else { return }
            if result.ok {
                self.show(test: String(format: "Connected ✓  (%.1f s)", Date().timeIntervalSince(started)), ok: true)
            } else {
                self.show(test: "Failed: \(result.message)", ok: false)
            }
        }
    }

    private func show(test text: String, ok: Bool) {
        testResult.textColor = ok ? .systemGreen : .systemRed
        testResult.stringValue = text
        testResult.toolTip = text
    }

    var debugTestResult: String { testResult.stringValue }
    func debugTest() { testTapped() }

    override func createItem() -> String {
        var profile = ConnectionProfile()
        profile.name = "New Connection"
        ConnectionStore.shared.upsert(profile)
        return profile.id
    }

    override func cloneItem(_ id: String) -> String? { ConnectionStore.shared.clone(id)?.id }
    override func deleteItem(_ id: String) { ConnectionStore.shared.removeProfile(id) }
}

/// One command run after login, on two lines so it fits the details
/// column: Command · −, then Prompt · Reply · Vault.
final class StepRow: NSStackView {
    var onRemove: (() -> Void)?
    private let command = FormKit.field("Command", width: 284)
    private let prompt = FormKit.field("Prompt (any)", width: 88)
    private let reply = FormKit.field("Reply", width: 70)
    private let secret = FormKit.popup(width: 118)

    init(step: AutoStep) {
        super.init(frame: .zero)
        orientation = .vertical
        alignment = .leading
        spacing = 3
        command.stringValue = step.send
        prompt.stringValue = step.expect
        reply.stringValue = step.reply
        command.toolTip = "Command to run"
        prompt.toolTip = "Text to wait for before answering. Empty = any password or (yes/no) prompt."
        reply.toolTip = "Plain text typed at the prompt"
        secret.toolTip = "Vault password typed at the prompt"
        FormKit.fill(secret, none: "No password", items: FormKit.vaultItems, current: step.secretID)
        let remove = NSButton(image: NSImage(systemSymbolName: "minus.circle", accessibilityDescription: "Remove") ?? NSImage(),
                              target: self, action: #selector(removeTapped))
        remove.isBordered = false
        remove.toolTip = "Remove"
        remove.contentTintColor = NSColor(white: 1, alpha: 0.7)
        addArrangedSubview(FormKit.row([command, remove], spacing: 4))
        addArrangedSubview(FormKit.row([prompt, reply, secret], spacing: 4))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    @objc private func removeTapped() { onRemove?() }

    var value: AutoStep {
        AutoStep(send: command.stringValue.trimmingCharacters(in: .whitespaces),
                 expect: prompt.stringValue.trimmingCharacters(in: .whitespaces),
                 reply: reply.stringValue, secretID: FormKit.selectedID(secret))
    }
}

// MARK: - Vault

final class VaultEditor: ListEditor {
    private let name = FormKit.field("Name, e.g. “jump host root”", width: 240)
    private let account = FormKit.field("Username (optional)", width: 240)
    private let password = NSSecureTextField()
    private let status = FormKit.label("", size: 10.5, alpha: 0.5)

    override var emptyText: String { "The vault is empty. Passwords saved here go to the macOS Keychain; connections, commands and proxies can use them." }

    override func loadItems() -> [Item] {
        ConnectionStore.shared.vault.map { Item(id: $0.id, title: $0.name, detail: $0.account.isEmpty ? "Password saved" : $0.account) }
    }

    override func buildForm() {
        password.placeholderString = "New password (empty = keep)"
        password.font = .systemFont(ofSize: 12)
        password.controlSize = .small
        password.translatesAutoresizingMaskIntoConstraints = false
        password.widthAnchor.constraint(equalToConstant: 240).isActive = true
        let hint = FormKit.label("Stored in the macOS login Keychain — never in the settings file, never shown.", size: 10.5, alpha: 0.5)
        hint.lineBreakMode = .byWordWrapping
        hint.maximumNumberOfLines = 3
        hint.preferredMaxLayoutWidth = 440
        for view in [line("Name", name), line("Username", account), line("Password", password), status, hint] as [NSView] {
            form.addArrangedSubview(view)
        }
        footer.addArrangedSubview(saveRow())
    }

    override func fillForm(_ id: String) {
        guard let entry = ConnectionStore.shared.vault.first(where: { $0.id == id }) else { return }
        name.stringValue = entry.name
        account.stringValue = entry.account
        password.stringValue = ""
        status.stringValue = Vault.secret(for: id) == nil ? "No password saved yet" : "Password saved ✓"
    }

    override func commit() {
        guard let id = selectedID, var entry = ConnectionStore.shared.vault.first(where: { $0.id == id }) else { return }
        let before = entry
        let trimmed = name.stringValue.trimmingCharacters(in: .whitespaces)
        entry.name = trimmed.isEmpty ? "Untitled" : trimmed
        entry.account = account.stringValue.trimmingCharacters(in: .whitespaces)
        let secret = password.stringValue.isEmpty ? nil : password.stringValue
        if entry != before || secret != nil { ConnectionStore.shared.upsert(entry, secret: secret) }
        password.stringValue = ""
    }

    override func createItem() -> String {
        var entry = VaultEntry()
        entry.name = "New Password"
        ConnectionStore.shared.upsert(entry, secret: nil)
        return entry.id
    }

    override func deleteItem(_ id: String) { ConnectionStore.shared.removeVaultEntry(id) }

    /// Test hook: type a password into the form.
    func debugSet(name: String, password: String) {
        self.name.stringValue = name
        self.password.stringValue = password
        saveTapped()
    }
}

// MARK: - Proxies

final class ProxiesEditor: ListEditor {
    private let name = FormKit.field("Display name", width: 220)
    private let kind = FormKit.popup(width: 120)
    private let host = FormKit.field("Proxy host", width: 190)
    private let port = FormKit.field("1080", width: 60)
    private let username = FormKit.field("User name (optional)", width: 160)
    private let secret = FormKit.popup(width: 220)
    private static let kinds = ["socks5", "http", "https"]

    override var emptyText: String { "No proxies. SOCKS5, HTTP and HTTPS are supported; saved proxies can be used by connections and port forwards." }

    override func loadItems() -> [Item] {
        ConnectionStore.shared.proxies.map { Item(id: $0.id, title: $0.name, detail: "\($0.kind)://\($0.host):\($0.port)") }
    }

    override func buildForm() {
        kind.addItems(withTitles: ["SOCKS5", "HTTP", "HTTPS"])
        let hint = FormKit.label("HTTP / HTTPS use CONNECT; HTTPS encrypts the link to the proxy itself. For authentication, enter a user name and pick the password from the Vault.",
                                 size: 10.5, alpha: 0.5)
        hint.lineBreakMode = .byWordWrapping
        hint.maximumNumberOfLines = 3
        hint.preferredMaxLayoutWidth = 440
        for view in [line("Name", name), line("Type", kind), line("Host", host, FormKit.label("Port"), port),
                     line("User", username), line("Password", secret, FormKit.label("from Vault", size: 10.5, alpha: 0.45)),
                     hint] as [NSView] {
            form.addArrangedSubview(view)
        }
        footer.addArrangedSubview(saveRow())
    }

    override func fillForm(_ id: String) {
        guard let proxy = ConnectionStore.shared.proxy(id) else { return }
        name.stringValue = proxy.name
        kind.selectItem(at: Self.kinds.firstIndex(of: proxy.kind) ?? 0)
        host.stringValue = proxy.host
        port.stringValue = "\(proxy.port)"
        username.stringValue = proxy.username
        FormKit.fill(secret, none: "No password", items: FormKit.vaultItems, current: proxy.secretID)
    }

    override func commit() {
        guard let id = selectedID, var proxy = ConnectionStore.shared.proxy(id) else { return }
        let before = proxy
        let trimmed = name.stringValue.trimmingCharacters(in: .whitespaces)
        proxy.name = trimmed.isEmpty ? "Untitled" : trimmed
        proxy.kind = Self.kinds[max(0, kind.indexOfSelectedItem)]
        proxy.host = host.stringValue.trimmingCharacters(in: .whitespaces)
        proxy.port = Int(port.stringValue.trimmingCharacters(in: .whitespaces)) ?? 1080
        proxy.username = username.stringValue.trimmingCharacters(in: .whitespaces)
        proxy.secretID = FormKit.selectedID(secret)
        if proxy != before { ConnectionStore.shared.upsert(proxy) }
    }

    override func createItem() -> String {
        var proxy = ProxyConfig()
        proxy.name = "New Proxy"
        ConnectionStore.shared.upsert(proxy)
        return proxy.id
    }

    override func deleteItem(_ id: String) { ConnectionStore.shared.removeProxy(id) }
}
