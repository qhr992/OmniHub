import AppKit

/// File operations over a tab's existing ssh connection (no second login):
/// `sftp` in batch mode through the tab's control socket.
enum SFTP {
    struct Entry {
        let name: String
        let isDirectory: Bool
        let isLink: Bool
        let size: Int64
        let modified: String
        let permissions: String
    }

    /// Quotes a path for sftp's command parser.
    static func quote(_ path: String) -> String {
        "\"" + path.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    static func join(_ directory: String, _ name: String) -> String {
        directory.hasSuffix("/") ? directory + name : directory + "/" + name
    }

    /// Lists `path` ("." = the login directory). Hands back the absolute
    /// path it resolved to and the entries, folders first.
    static func list(_ target: RemoteTarget, path: String,
                     completion: @escaping (_ resolved: String?, _ entries: [Entry], _ error: String?) -> Void) {
        let batch = "cd \(quote(path))\npwd\nls -la\n"
        Subprocess.run(target.sftpArguments(), input: batch) { result in
            guard result.ok else { completion(nil, [], result.message); return }
            var resolved: String?
            var entries: [Entry] = []
            for raw in result.output.split(separator: "\n") {
                let line = String(raw)
                if line.hasPrefix("sftp>") { continue }
                if let range = line.range(of: "Remote working directory: ") {
                    resolved = String(line[range.upperBound...])
                    continue
                }
                if let entry = parse(line) { entries.append(entry) }
            }
            entries.sort {
                if $0.isDirectory != $1.isDirectory { return $0.isDirectory }
                return $0.name.localizedStandardCompare($1.name) == .orderedAscending
            }
            completion(resolved ?? path, entries, nil)
        }
    }

    /// One line of `ls -la`: "drwxr-xr-x  5 user group  160 Nov 13 10:00 name".
    static func parse(_ line: String) -> Entry? {
        let fields = line.split(separator: " ", maxSplits: 8, omittingEmptySubsequences: true)
        guard fields.count == 9, let type = fields[0].first, "-dlbcps".contains(type),
              fields[0].count >= 10, let size = Int64(fields[4]) else { return nil }
        let name = String(fields[8])
        guard name != ".", name != ".." else { return nil }
        return Entry(name: name, isDirectory: type == "d", isLink: type == "l", size: size,
                     modified: "\(fields[5]) \(fields[6]) \(fields[7])", permissions: String(fields[0]))
    }

    static func makeDirectory(_ target: RemoteTarget, path: String, completion: @escaping (String?) -> Void) {
        Subprocess.run(target.sftpArguments(), input: "mkdir \(quote(path))\n") { result in
            completion(result.ok ? nil : result.message)
        }
    }
}

/// One download or upload.
final class Transfer {
    enum State: String, Codable { case running, done, failed }

    let id = UUID().uuidString
    let name: String
    let isUpload: Bool
    let localPath: String
    let remotePath: String
    let host: String
    var total: Int64?
    var transferred: Int64 = 0
    var state = State.running
    var message = ""
    var finished: Date?
    var process: Process?

    init(name: String, isUpload: Bool, localPath: String, remotePath: String, host: String, total: Int64?) {
        self.name = name
        self.isUpload = isUpload
        self.localPath = localPath
        self.remotePath = remotePath
        self.host = host
        self.total = total
    }

    /// 0…1, nil when the size is not known.
    var fraction: Double? {
        guard let total, total > 0 else { return nil }
        return min(1, Double(transferred) / Double(total))
    }
}

/// Runs the transfers and remembers the recent ones (Downloads button of the
/// terminal page).
final class TransferCenter {
    static let shared = TransferCenter()

    private struct Record: Codable {
        let name: String
        let isUpload: Bool
        let localPath: String
        let remotePath: String
        let host: String
        let total: Int64?
        let state: Transfer.State
        let message: String
        let finished: Date?
    }

    /// Newest first.
    private(set) var items: [Transfer] = []
    private var timer: Timer?
    private let measureQueue = DispatchQueue(label: "omnihub.transfers", qos: .utility)

    private init() {
        for record in Store.load([Record].self, from: "transfers.json") ?? [] {
            let item = Transfer(name: record.name, isUpload: record.isUpload, localPath: record.localPath,
                                remotePath: record.remotePath, host: record.host, total: record.total)
            // Anything still "running" in the file was cut off by a quit.
            item.state = record.state == .running ? .failed : record.state
            item.message = record.state == .running ? "Interrupted" : record.message
            item.transferred = record.state == .done ? (record.total ?? 0) : 0
            item.finished = record.finished
            items.append(item)
        }
    }

    static var downloadsDirectory: URL {
        FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory() + "/Downloads")
    }

    /// "report.pdf" → "report (1).pdf" when the name is taken.
    private static func freeURL(for name: String, in directory: URL) -> URL {
        var candidate = directory.appendingPathComponent(name)
        let base = (name as NSString).deletingPathExtension, ext = (name as NSString).pathExtension
        var counter = 1
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = directory.appendingPathComponent(ext.isEmpty ? "\(base) (\(counter))" : "\(base) (\(counter)).\(ext)")
            counter += 1
        }
        return candidate
    }

    @discardableResult
    func download(_ target: RemoteTarget, remotePath: String, name: String, size: Int64, isDirectory: Bool,
                  to directory: URL = TransferCenter.downloadsDirectory) -> Transfer {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let local = Self.freeURL(for: name, in: directory)
        let item = Transfer(name: name, isUpload: false, localPath: local.path, remotePath: remotePath,
                            host: target.host, total: isDirectory ? nil : size)
        items.insert(item, at: 0)
        if isDirectory {
            // The size of a folder has to be asked for; until it is known
            // the bar just shows activity.
            Subprocess.run(target.muxArguments([target.host, "du -sk -- \(Self.shellQuote(remotePath))"])) { [weak self] result in
                if result.ok, let kilobytes = Int64(result.output.split(whereSeparator: { $0 == "\t" || $0 == " " }).first ?? "") {
                    item.total = kilobytes * 1024
                    self?.changed()
                }
            }
        }
        let batch = "get -r \(SFTP.quote(remotePath)) \(SFTP.quote(local.path))\n"
        item.process = Subprocess.run(target.sftpArguments(), input: batch) { [weak self] result in
            self?.finish(item, result)
        }
        started()
        return item
    }

    @discardableResult
    func upload(_ target: RemoteTarget, local: URL, remoteDirectory: String, completion: (() -> Void)? = nil) -> Transfer {
        var isDirectory: ObjCBool = false
        FileManager.default.fileExists(atPath: local.path, isDirectory: &isDirectory)
        let remote = SFTP.join(remoteDirectory, local.lastPathComponent)
        let item = Transfer(name: local.lastPathComponent, isUpload: true, localPath: local.path, remotePath: remote,
                            host: target.host, total: nil)
        items.insert(item, at: 0)
        let batch = "put -r \(SFTP.quote(local.path)) \(SFTP.quote(remote))\n"
        item.process = Subprocess.run(target.sftpArguments(), input: batch) { [weak self] result in
            self?.finish(item, result)
            completion?()
        }
        started()
        return item
    }

    private static func shellQuote(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private func finish(_ item: Transfer, _ result: Subprocess.Result) {
        item.process = nil
        item.finished = Date()
        if item.state == .running {
            item.state = result.ok ? .done : .failed
            item.message = result.ok ? "" : result.message
        }
        if item.state == .done, !item.isUpload {
            item.transferred = Self.size(of: item.localPath)
            if item.total == nil { item.total = item.transferred }
        }
        persist()
        changed()
    }

    func cancel(_ item: Transfer) {
        guard item.state == .running else { return }
        item.state = .failed
        item.message = "Cancelled"
        item.process?.terminate()
    }

    func clearFinished() {
        items.removeAll { $0.state != .running }
        persist()
        changed()
    }

    private func persist() {
        let records = items.prefix(40).map {
            Record(name: $0.name, isUpload: $0.isUpload, localPath: $0.localPath, remotePath: $0.remotePath,
                   host: $0.host, total: $0.total, state: $0.state, message: $0.message, finished: $0.finished)
        }
        Store.save(Array(records), to: "transfers.json")
    }

    private func changed() {
        NotificationCenter.default.post(name: .transfersChanged, object: nil)
    }

    /// Bytes on disk of a file, or of everything inside a folder.
    static func size(of path: String) -> Int64 {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) else { return 0 }
        if !isDirectory.boolValue {
            return ((try? FileManager.default.attributesOfItem(atPath: path))?[.size] as? NSNumber)?.int64Value ?? 0
        }
        var total: Int64 = 0
        if let walker = FileManager.default.enumerator(at: URL(fileURLWithPath: path), includingPropertiesForKeys: [.fileSizeKey]) {
            for case let url as URL in walker {
                total += Int64((try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
            }
        }
        return total
    }

    /// While something runs, measures what has arrived twice a second.
    private func started() {
        changed()
        guard timer == nil else { return }
        let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in self?.measure() }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func measure() {
        let running = items.filter { $0.state == .running }
        guard !running.isEmpty else {
            timer?.invalidate()
            timer = nil
            return
        }
        let downloads = running.filter { !$0.isUpload }
        measureQueue.async { [weak self] in
            let sizes = downloads.map { ($0, Self.size(of: $0.localPath)) }
            DispatchQueue.main.async {
                for (item, size) in sizes where item.state == .running { item.transferred = size }
                self?.changed()
            }
        }
    }
}

// MARK: - Recent downloads

/// Drop-down of the Downloads button: recent transfers, running ones with a bar.
final class TransfersView: NSView, TabScope {
    private let stack = NSStackView()
    private var rows: [String: TransferRow] = [:]

    init() {
        super.init(frame: .zero)
        let title = NSTextField(labelWithString: "Recent Downloads")
        title.font = .systemFont(ofSize: 12, weight: .semibold)
        title.textColor = .white
        let clear = NSButton(title: "Clear", target: self, action: #selector(clearFinished))
        clear.bezelStyle = .inline
        clear.controlSize = .small

        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false
        let document = FlippedView()
        document.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(stack)
        let scroll = NSScrollView()
        scroll.documentView = document
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false

        for view in [title, clear, scroll] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            title.topAnchor.constraint(equalTo: topAnchor, constant: 10),
            title.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            clear.centerYAnchor.constraint(equalTo: title.centerYAnchor),
            clear.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            scroll.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 8),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),
            document.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            document.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            document.trailingAnchor.constraint(equalTo: scroll.contentView.trailingAnchor),
            stack.topAnchor.constraint(equalTo: document.topAnchor),
            stack.leadingAnchor.constraint(equalTo: document.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: document.trailingAnchor, constant: -6),
            stack.bottomAnchor.constraint(equalTo: document.bottomAnchor)
        ])
        NotificationCenter.default.addObserver(self, selector: #selector(reload), name: .transfersChanged, object: nil)
        reload()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    @objc private func clearFinished() { TransferCenter.shared.clearFinished() }

    @objc private func reload() {
        let items = TransferCenter.shared.items
        // Rows are kept between refreshes so the bars do not flicker.
        if items.map(\.id) != stack.arrangedSubviews.compactMap({ ($0 as? TransferRow)?.item.id }) {
            for view in stack.arrangedSubviews {
                stack.removeArrangedSubview(view)
                view.removeFromSuperview()
            }
            rows = [:]
            for item in items {
                let row = TransferRow(item: item)
                rows[item.id] = row
                stack.addArrangedSubview(row)
                row.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
            }
            if items.isEmpty {
                let empty = NSTextField(labelWithString: "Nothing downloaded yet. In the SFTP panel, right-click a file or folder and choose Download.")
                empty.font = .systemFont(ofSize: 11)
                empty.textColor = NSColor(white: 1, alpha: 0.5)
                empty.lineBreakMode = .byWordWrapping
                empty.maximumNumberOfLines = 2
                empty.preferredMaxLayoutWidth = 360
                stack.addArrangedSubview(empty)
            }
        }
        rows.values.forEach { $0.refresh() }
    }
}

final class TransferRow: NSView {
    let item: Transfer
    private let detail = NSTextField(labelWithString: "")
    private let bar = NSProgressIndicator()
    private let action = NSButton()

    private static func size(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    init(item: Transfer) {
        self.item = item
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 7
        layer?.backgroundColor = NSColor(white: 1, alpha: 0.06).cgColor
        translatesAutoresizingMaskIntoConstraints = false

        let icon = NSImageView()
        icon.image = NSImage(systemSymbolName: item.isUpload ? "arrow.up.circle.fill" : "arrow.down.circle.fill",
                             accessibilityDescription: item.isUpload ? "Upload" : "Download")
        icon.contentTintColor = item.isUpload ? .systemOrange : .systemBlue
        let name = NSTextField(labelWithString: item.name)
        name.font = .systemFont(ofSize: 12, weight: .medium)
        name.textColor = .white
        name.lineBreakMode = .byTruncatingMiddle
        name.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        detail.font = .monospacedDigitSystemFont(ofSize: 10, weight: .regular)
        detail.textColor = NSColor(white: 1, alpha: 0.55)
        detail.lineBreakMode = .byTruncatingTail
        detail.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        bar.style = .bar
        bar.controlSize = .small
        bar.minValue = 0
        bar.maxValue = 1
        action.isBordered = false
        action.target = self
        action.action = #selector(actionTapped)
        action.contentTintColor = NSColor(white: 1, alpha: 0.75)

        for view in [icon, name, detail, bar, action] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 52),
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            icon.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            icon.widthAnchor.constraint(equalToConstant: 16),
            icon.heightAnchor.constraint(equalToConstant: 16),
            name.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 6),
            name.centerYAnchor.constraint(equalTo: icon.centerYAnchor),
            name.trailingAnchor.constraint(lessThanOrEqualTo: action.leadingAnchor, constant: -6),
            action.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            action.centerYAnchor.constraint(equalTo: icon.centerYAnchor),
            action.widthAnchor.constraint(equalToConstant: 22),
            action.heightAnchor.constraint(equalToConstant: 20),
            detail.leadingAnchor.constraint(equalTo: name.leadingAnchor),
            detail.topAnchor.constraint(equalTo: name.bottomAnchor, constant: 2),
            detail.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -8),
            bar.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            bar.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            bar.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -3)
        ])
        refresh()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    /// What the row currently says (verification).
    var debugText: String { "\(item.name): \(detail.stringValue) bar=\(bar.isHidden ? "hidden" : (bar.isIndeterminate ? "busy" : String(format: "%.0f%%", bar.doubleValue * 100)))" }

    func refresh() {
        switch item.state {
        case .running:
            bar.isHidden = false
            if let fraction = item.fraction {
                bar.isIndeterminate = false
                bar.doubleValue = fraction
                detail.stringValue = "\(Self.size(item.transferred)) / \(Self.size(item.total ?? 0)) · \(Int(fraction * 100))% · \(item.host)"
            } else {
                bar.isIndeterminate = true
                bar.startAnimation(nil)
                detail.stringValue = (item.isUpload ? "Uploading" : "Downloading \(Self.size(item.transferred))") + " · \(item.host)"
            }
            action.image = NSImage(systemSymbolName: "xmark.circle", accessibilityDescription: "Cancel")
            action.toolTip = "Cancel"
        case .done:
            bar.isHidden = true
            let formatter = DateFormatter()
            formatter.dateFormat = "MM-dd HH:mm"
            let when = item.finished.map { formatter.string(from: $0) } ?? ""
            detail.stringValue = (item.isUpload ? "Uploaded to \(item.remotePath)" : "Done · \(Self.size(item.total ?? item.transferred))")
                + " · \(item.host) · \(when)"
            action.image = NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: "Show in Finder")
            action.toolTip = "Show in Finder"
            action.isHidden = item.isUpload
        case .failed:
            bar.isHidden = true
            detail.stringValue = "Failed: \(item.message)"
            detail.textColor = .systemRed
            action.isHidden = true
        }
    }

    @objc private func actionTapped() {
        if item.state == .running {
            TransferCenter.shared.cancel(item)
        } else {
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: item.localPath)])
        }
    }
}

// MARK: - SFTP drawer

/// Slides up over the terminal: the server's folders and files.
/// Double-click enters a folder; right-click (or two-finger click) offers
/// Copy Path and Download.
final class SFTPBrowserView: NSView, TabScope, NSTableViewDataSource, NSTableViewDelegate, NSTextFieldDelegate {
    let session: TerminalSession
    var onClose: (() -> Void)?

    private let pathLabel = NSTextField(labelWithString: "")
    private let statusLabel = NSTextField(labelWithString: "")
    private let inputField = NSTextField()
    private var inputHeight: NSLayoutConstraint!
    private let tableView = NSTableView()
    private var entries: [SFTP.Entry] = []
    private var visible: [SFTP.Entry] = []
    private(set) var path = "."
    private var loading = false
    /// What the input row is for at the moment.
    private enum InputMode { case none, filter, newFolder }
    private var inputMode = InputMode.none

    init(session: TerminalSession) {
        self.session = session
        super.init(frame: .zero)
        build()
        NotificationCenter.default.addObserver(self, selector: #selector(transfersChanged), name: .transfersChanged, object: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    var debugState: String {
        "sftp path=\(path) entries=\(entries.count) shown=\(visible.count) status=\"\(statusLabel.stringValue)\" first=\(visible.prefix(6).map { $0.isDirectory ? $0.name + "/" : $0.name })"
    }
    var debugEntries: [SFTP.Entry] { visible }

    private func button(_ symbol: String, _ tooltip: String, _ action: Selector) -> NSButton {
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: tooltip)?
            .withSymbolConfiguration(.init(pointSize: 12, weight: .medium))
        let button = NSButton(image: image ?? NSImage(), target: self, action: action)
        button.isBordered = false
        button.toolTip = tooltip
        button.contentTintColor = NSColor(white: 1, alpha: 0.8)
        button.translatesAutoresizingMaskIntoConstraints = false
        button.widthAnchor.constraint(equalToConstant: 24).isActive = true
        button.heightAnchor.constraint(equalToConstant: 22).isActive = true
        return button
    }

    private func build() {
        wantsLayer = true
        layer?.backgroundColor = NSColor(srgbRed: 0.09, green: 0.09, blue: 0.12, alpha: 0.98).cgColor
        layer?.cornerRadius = 10
        layer?.maskedCorners = [.layerMinXMaxYCorner, .layerMaxXMaxYCorner]
        layer?.borderWidth = 1
        layer?.borderColor = NSColor(white: 1, alpha: 0.14).cgColor

        let up = button("arrow.up", "Up", #selector(goUp))
        pathLabel.font = .monospacedSystemFont(ofSize: 11, weight: .medium)
        pathLabel.textColor = .white
        pathLabel.lineBreakMode = .byTruncatingHead
        pathLabel.isSelectable = true
        pathLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let tools = NSStackView(views: [button("arrow.clockwise", "Refresh", #selector(refresh)),
                                        button("line.3.horizontal.decrease.circle", "Filter", #selector(toggleFilter)),
                                        button("folder.badge.plus", "New Folder", #selector(newFolder)),
                                        button("square.and.arrow.up", "Upload", #selector(upload)),
                                        button("xmark", "Close", #selector(closeTapped))])
        tools.orientation = .horizontal
        tools.spacing = 2

        inputField.font = .systemFont(ofSize: 12)
        inputField.delegate = self
        inputField.target = self
        inputField.action = #selector(inputSubmitted)
        inputField.isHidden = true

        tableView.headerView = nil
        tableView.rowHeight = 22
        tableView.backgroundColor = .clear
        tableView.dataSource = self
        tableView.delegate = self
        tableView.target = self
        tableView.doubleAction = #selector(openSelection)
        tableView.allowsMultipleSelection = true
        for (id, width) in [("name", CGFloat(420)), ("size", 90), ("modified", 130)] {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id))
            column.width = width
            if id == "name" { column.resizingMask = .autoresizingMask } else { column.resizingMask = [] }
            tableView.addTableColumn(column)
        }
        tableView.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle
        let menu = NSMenu()
        menu.addItem(withTitle: "Copy Path", action: #selector(copyPath), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Download", action: #selector(downloadSelection), keyEquivalent: "").target = self
        tableView.menu = menu
        let scroll = NSScrollView()
        scroll.documentView = tableView
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false

        statusLabel.font = .systemFont(ofSize: 10.5)
        statusLabel.textColor = NSColor(white: 1, alpha: 0.55)
        statusLabel.lineBreakMode = .byTruncatingTail

        for view in [up, pathLabel, tools, inputField, scroll, statusLabel] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        inputHeight = inputField.heightAnchor.constraint(equalToConstant: 0)
        NSLayoutConstraint.activate([
            up.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            up.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            pathLabel.leadingAnchor.constraint(equalTo: up.trailingAnchor, constant: 4),
            pathLabel.centerYAnchor.constraint(equalTo: up.centerYAnchor),
            pathLabel.trailingAnchor.constraint(lessThanOrEqualTo: tools.leadingAnchor, constant: -8),
            tools.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            tools.centerYAnchor.constraint(equalTo: up.centerYAnchor),
            inputField.topAnchor.constraint(equalTo: up.bottomAnchor, constant: 4),
            inputField.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            inputField.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            inputHeight,
            scroll.topAnchor.constraint(equalTo: inputField.bottomAnchor, constant: 4),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            scroll.bottomAnchor.constraint(equalTo: statusLabel.topAnchor, constant: -3),
            statusLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            statusLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -10),
            statusLabel.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -5)
        ])
    }

    // MARK: Loading

    func load(_ target: String, completion: (() -> Void)? = nil) {
        guard let remote = session.target, !loading else { return }
        loading = true
        statusLabel.textColor = NSColor(white: 1, alpha: 0.55)
        statusLabel.stringValue = "Loading…"
        SFTP.list(remote, path: target) { [weak self] resolved, entries, error in
            guard let self else { return }
            self.loading = false
            if let error {
                self.statusLabel.textColor = .systemRed
                self.statusLabel.stringValue = "Cannot open \(target): \(error)"
                completion?()
                return
            }
            self.path = resolved ?? target
            self.entries = entries
            self.pathLabel.stringValue = self.path
            self.applyFilter()
            completion?()
        }
    }

    private func applyFilter() {
        let needle = inputMode == .filter ? inputField.stringValue.trimmingCharacters(in: .whitespaces) : ""
        visible = needle.isEmpty ? entries : entries.filter { $0.name.localizedCaseInsensitiveContains(needle) }
        tableView.reloadData()
        let folders = visible.filter(\.isDirectory).count
        statusLabel.textColor = NSColor(white: 1, alpha: 0.55)
        statusLabel.stringValue = "\(folders) folders, \(visible.count - folders) files"
            + (needle.isEmpty ? "" : " (filtered from \(entries.count))") + " · double-click to open, right-click for Copy Path / Download"
    }

    @objc private func refresh() { load(path) }

    @objc private func goUp() {
        guard path != "/", path != "." else { return }
        let parent = (path as NSString).deletingLastPathComponent
        load(parent.isEmpty ? "/" : parent)
    }

    @objc private func openSelection() {
        let row = tableView.clickedRow >= 0 ? tableView.clickedRow : tableView.selectedRow
        guard row >= 0, row < visible.count else { return }
        let entry = visible[row]
        // A link may point at a folder; trying is the only way to know.
        guard entry.isDirectory || entry.isLink else { return }
        if inputMode == .filter { setInput(.none) }
        load(SFTP.join(path, entry.name))
    }

    @objc private func closeTapped() { onClose?() }

    // MARK: Input row (filter / new folder)

    private func setInput(_ mode: InputMode) {
        inputMode = mode
        inputField.stringValue = ""
        inputField.isHidden = mode == .none
        inputHeight.constant = mode == .none ? 0 : 22
        inputField.placeholderString = mode == .filter ? "Filter names in this folder…" : "New folder name, Return to create"
        if mode != .none { window?.makeFirstResponder(inputField) }
        applyFilter()
    }

    @objc private func toggleFilter() { setInput(inputMode == .filter ? .none : .filter) }
    @objc private func newFolder() { setInput(inputMode == .newFolder ? .none : .newFolder) }

    func controlTextDidChange(_ obj: Notification) {
        if inputMode == .filter { applyFilter() }
    }

    @objc private func inputSubmitted() {
        guard inputMode == .newFolder else { return }
        let name = inputField.stringValue.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        createFolder(named: name)
    }

    func createFolder(named name: String, completion: (() -> Void)? = nil) {
        guard let remote = session.target else { return }
        guard !name.contains("/") else {
            statusLabel.textColor = .systemRed
            statusLabel.stringValue = "A folder name cannot contain /"
            return
        }
        SFTP.makeDirectory(remote, path: SFTP.join(path, name)) { [weak self] error in
            guard let self else { return }
            if let error {
                self.statusLabel.textColor = .systemRed
                self.statusLabel.stringValue = "Create failed: \(error)"
                completion?()
                return
            }
            self.setInput(.none)
            self.load(self.path, completion: completion)
        }
    }

    // MARK: Transfers

    @objc private func upload() {
        guard let remote = session.target else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.message = "Choose files or folders to upload to \(path)"
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK else { return }
        for url in panel.urls {
            TransferCenter.shared.upload(remote, local: url, remoteDirectory: path)
        }
        statusLabel.stringValue = "Uploading \(panel.urls.count) item(s) — see the Downloads button"
    }

    /// Refreshes the listing when an upload into this folder has finished.
    private var seenUploads = Set<String>()
    @objc private func transfersChanged() {
        let finished = TransferCenter.shared.items.filter {
            $0.isUpload && $0.state == .done && ($0.remotePath as NSString).deletingLastPathComponent == path
        }
        let fresh = finished.filter { !seenUploads.contains($0.id) }
        guard !fresh.isEmpty else { return }
        fresh.forEach { seenUploads.insert($0.id) }
        load(path)
    }

    private func targets() -> [SFTP.Entry] {
        var rows = tableView.selectedRowIndexes
        // A right-click on a row outside the selection acts on that row.
        if tableView.clickedRow >= 0, !rows.contains(tableView.clickedRow) { rows = IndexSet(integer: tableView.clickedRow) }
        return rows.compactMap { $0 < visible.count ? visible[$0] : nil }
    }

    @objc private func copyPath() {
        let paths = targets().map { SFTP.join(path, $0.name) }
        guard !paths.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(paths.joined(separator: "\n"), forType: .string)
        statusLabel.stringValue = "Path copied: \(paths[0])" + (paths.count > 1 ? " (+\(paths.count - 1))" : "")
    }

    @objc private func downloadSelection() {
        let chosen = targets()
        guard !chosen.isEmpty else { return }
        chosen.forEach { download($0) }
        statusLabel.stringValue = "Downloading \(chosen.count) item(s) to Downloads — see the Downloads button"
    }

    @discardableResult
    func download(_ entry: SFTP.Entry, to directory: URL = TransferCenter.downloadsDirectory) -> Transfer? {
        guard let remote = session.target else { return nil }
        return TransferCenter.shared.download(remote, remotePath: SFTP.join(path, entry.name), name: entry.name,
                                              size: entry.size, isDirectory: entry.isDirectory, to: directory)
    }

    // MARK: Table

    func numberOfRows(in tableView: NSTableView) -> Int { visible.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let entry = visible[row]
        let id = tableColumn?.identifier.rawValue ?? "name"
        let cell = NSTableCellView()
        let label = NSTextField(labelWithString: "")
        label.lineBreakMode = .byTruncatingMiddle
        label.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(label)
        var leading: CGFloat = 2
        switch id {
        case "name":
            let icon = NSImageView()
            icon.image = NSImage(systemSymbolName: entry.isDirectory ? "folder.fill" : (entry.isLink ? "link" : "doc"),
                                 accessibilityDescription: nil)?.withSymbolConfiguration(.init(pointSize: 11, weight: .regular))
            icon.contentTintColor = entry.isDirectory ? NSColor(srgbRed: 0.45, green: 0.75, blue: 1.0, alpha: 1) : NSColor(white: 1, alpha: 0.6)
            icon.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(icon)
            NSLayoutConstraint.activate([icon.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
                                         icon.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                                         icon.widthAnchor.constraint(equalToConstant: 16)])
            leading = 26
            label.stringValue = entry.name
            label.font = .systemFont(ofSize: 12)
            label.textColor = .white
        case "size":
            label.stringValue = entry.isDirectory ? "—" : ByteCountFormatter.string(fromByteCount: entry.size, countStyle: .file)
            label.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
            label.textColor = NSColor(white: 1, alpha: 0.6)
            label.alignment = .right
        default:
            label.stringValue = entry.modified
            label.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
            label.textColor = NSColor(white: 1, alpha: 0.6)
        }
        NSLayoutConstraint.activate([label.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: leading),
                                     label.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
                                     label.centerYAnchor.constraint(equalTo: cell.centerYAnchor)])
        return cell
    }
}
