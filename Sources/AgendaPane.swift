import AppKit
import EventKit

/// Read-only access to the Mac's own calendars (Calendar.app accounts).
final class CalendarSource {
    static let shared = CalendarSource()
    private let store = EKEventStore()
    /// Off for headless runs, so no permission dialog appears.
    static var allowPrompt = true

    struct Entry {
        let title: String
        let start: Date
        let end: Date
        let allDay: Bool
        let color: NSColor
        let calendar: String
    }

    enum Access { case granted, denied, undetermined }

    var access: Access {
        let raw = EKEventStore.authorizationStatus(for: .event).rawValue
        switch raw {
        case 3: return .granted          // authorized / fullAccess
        case 0: return .undetermined
        default: return .denied
        }
    }

    /// Asks once; `completion` runs on the main queue.
    func requestIfNeeded(_ completion: @escaping () -> Void) {
        guard access == .undetermined, Self.allowPrompt else { completion(); return }
        let done: (Bool, Error?) -> Void = { _, _ in DispatchQueue.main.async(execute: completion) }
        if #available(macOS 14.0, *) {
            store.requestFullAccessToEvents(completion: done)
        } else {
            store.requestAccess(to: .event, completion: done)
        }
    }

    func entries(from start: Date, to end: Date) -> [Entry] {
        guard access == .granted else { return [] }
        let predicate = store.predicateForEvents(withStart: start, end: end, calendars: nil)
        return store.events(matching: predicate).map {
            Entry(title: $0.title ?? "(Untitled)", start: $0.startDate, end: $0.endDate, allDay: $0.isAllDay,
                  color: $0.calendar.color ?? .systemBlue, calendar: $0.calendar.title)
        }.sorted { $0.start < $1.start }
    }
}

/// Agenda page: a month calendar on the left; on the right the chosen day's
/// calendar events (from the Mac's Calendar) and to-dos, plus the form for a
/// new to-do. Ticking a to-do completes it and it leaves the list.
final class AgendaPane: NSView, DockPage {
    private let grid = MonthGridView()
    private let monthLabel = NSTextField(labelWithString: "")
    private let accessLabel = NSTextField(labelWithString: "")
    private let accessButton = NSButton(title: "Open System Settings", target: nil, action: nil)
    private let dayLabel = NSTextField(labelWithString: "")
    private let titleField = NSTextField()
    private let noteField = NSTextField()
    private let dateToggle = FocusButton(checkboxWithTitle: "Date", target: nil, action: nil)
    private let datePicker = NSDatePicker()
    private let addButton = FocusButton(title: "Add", target: nil, action: nil)
    private let cancelButton = FocusButton(title: "Cancel", target: nil, action: nil)
    private let editRow = NSStackView()
    /// Day = the chosen day's events and to-dos; Done = finished to-dos.
    private let modePicker = NSSegmentedControl(labels: ["Day", "Done"], trackingMode: .selectOne, target: nil, action: nil)
    /// The to-do being edited in the form (nil = the form adds a new one).
    private(set) var editingID: UUID?
    private var highlightedID: UUID?
    private weak var highlightedRow: NSView?
    private let listStack = NSStackView()
    private let summaryLabel = NSTextField(labelWithString: "")
    private var selected = Calendar.current.startOfDay(for: Date())
    private var month = Calendar.current.startOfDay(for: Date())
    private(set) var debugRows: [String] = []

    init() {
        super.init(frame: .zero)
        buildContent()
        NotificationCenter.default.addObserver(self, selector: #selector(reload), name: .tasksChanged, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(reload),
                                               name: .EKEventStoreChanged, object: nil)
        showMonth(containing: selected)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func preferredSize(horizontal: Bool) -> NSSize { NSSize(width: 640, height: 420) }
    var initialResponder: NSView? { titleField }

    func pageWillAppear() {
        endEditing()
        modePicker.selectedSegment = 0
        highlightedID = nil
        select(Calendar.current.startOfDay(for: Date()))
        CalendarSource.shared.requestIfNeeded { [weak self] in self?.reload() }
    }

    var debugState: String {
        "agenda month=\(monthLabel.stringValue) day=\(dayLabel.stringValue) calendar=\(CalendarSource.shared.access) rows=\(debugRows)"
    }

    /// Test hook: jump to a day.
    func debugSelect(_ date: Date) { select(Calendar.current.startOfDay(for: date)) }
    func debugShowDone(_ done: Bool) { modePicker.selectedSegment = done ? 1 : 0; reload() }
    var debugForm: String {
        "title=\(titleField.stringValue) note=\(noteField.stringValue) button=\(addButton.title) "
            + "editing=\(editingID != nil) highlighted=\(highlightedRow != nil)"
    }
    /// The Tab order of the form, as titles / placeholders.
    var debugTabOrder: [String] {
        var names: [String] = []
        var view: NSView? = titleField
        for _ in 0..<8 {
            guard let current = view else { break }
            names.append((current as? NSTextField)?.placeholderString ?? (current as? NSButton)?.title
                         ?? (current is NSDatePicker ? "date picker" : "\(type(of: current))"))
            view = current.nextKeyView
            if view === titleField { break }
        }
        return names
    }
    func debugSave() { addTask() }

    /// Opens a to-do: its day (or the Done list), highlighted, and loaded
    /// into the form for editing.
    func focus(taskID: UUID) {
        guard let task = TaskStore.shared.item(taskID) else { return }
        highlightedID = taskID
        if task.done {
            modePicker.selectedSegment = 1
            endEditing()
            reload()
        } else {
            modePicker.selectedSegment = 0
            let calendar = Calendar.current
            let today = calendar.startOfDay(for: Date())
            // Undated and overdue to-dos are listed under today.
            let day = task.due.map { calendar.startOfDay(for: $0) }.map { $0 < today ? today : $0 } ?? today
            select(day)
            beginEditing(task)
        }
        if let row = highlightedRow {
            DispatchQueue.main.async { row.scrollToVisible(row.bounds) }
        }
    }

    // MARK: Build

    private func buildContent() {
        // ---- left: calendar
        monthLabel.font = .systemFont(ofSize: 14, weight: .semibold)
        monthLabel.textColor = .white
        func arrow(_ symbol: String, _ tooltip: String, _ action: Selector) -> NSButton {
            let button = NSButton(image: NSImage(systemSymbolName: symbol, accessibilityDescription: tooltip) ?? NSImage(),
                                  target: self, action: action)
            button.isBordered = false
            button.toolTip = tooltip
            button.contentTintColor = NSColor(white: 1, alpha: 0.8)
            return button
        }
        let today = NSButton(title: "Today", target: self, action: #selector(goToday))
        today.bezelStyle = .inline
        today.controlSize = .small
        let gap = NSView()
        gap.setContentHuggingPriority(.init(1), for: .horizontal)
        let monthRow = NSStackView(views: [monthLabel, gap, today,
                                           arrow("chevron.left", "Previous month", #selector(previousMonth)),
                                           arrow("chevron.right", "Next month", #selector(nextMonth))])
        monthRow.orientation = .horizontal
        monthRow.spacing = 8

        grid.onSelect = { [weak self] date in self?.select(date) }
        grid.translatesAutoresizingMaskIntoConstraints = false
        grid.heightAnchor.constraint(equalToConstant: 238).isActive = true

        accessLabel.font = .systemFont(ofSize: 10.5)
        accessLabel.textColor = NSColor(white: 1, alpha: 0.55)
        accessLabel.lineBreakMode = .byWordWrapping
        accessLabel.maximumNumberOfLines = 2
        accessLabel.preferredMaxLayoutWidth = 240
        accessButton.target = self
        accessButton.action = #selector(openCalendarSettings)
        accessButton.bezelStyle = .inline
        accessButton.controlSize = .small

        let legend = NSTextField(labelWithString: "● Calendar   ● To-do")
        legend.font = .systemFont(ofSize: 10)
        let legendText = NSMutableAttributedString(string: "● Calendar   ● To-do",
                                                   attributes: [.foregroundColor: NSColor(white: 1, alpha: 0.55),
                                                                .font: NSFont.systemFont(ofSize: 10)])
        legendText.addAttribute(.foregroundColor, value: MonthGridView.eventColor, range: NSRange(location: 0, length: 1))
        legendText.addAttribute(.foregroundColor, value: MonthGridView.taskColor, range: NSRange(location: 13, length: 1))
        legend.attributedStringValue = legendText

        let left = NSStackView(views: [monthRow, grid, legend, accessLabel, accessButton])
        left.orientation = .vertical
        left.alignment = .leading
        left.spacing = 8
        left.translatesAutoresizingMaskIntoConstraints = false
        monthRow.widthAnchor.constraint(equalTo: left.widthAnchor).isActive = true
        grid.widthAnchor.constraint(equalTo: left.widthAnchor).isActive = true

        // ---- right: the day
        dayLabel.font = .systemFont(ofSize: 14, weight: .semibold)
        dayLabel.textColor = .white
        dayLabel.translatesAutoresizingMaskIntoConstraints = false

        titleField.placeholderString = "New to-do"
        titleField.font = .systemFont(ofSize: 13)
        titleField.target = self
        titleField.action = #selector(addTask)
        // Without this, tabbing to the note field fires the action and adds
        // a half-filled item.
        titleField.cell?.sendsActionOnEndEditing = false
        noteField.placeholderString = "Note (optional)"
        noteField.font = .systemFont(ofSize: 12)
        noteField.target = self
        noteField.action = #selector(addTask)
        noteField.cell?.sendsActionOnEndEditing = false

        dateToggle.target = self
        dateToggle.action = #selector(toggleDate)
        datePicker.datePickerStyle = .textFieldAndStepper
        datePicker.datePickerElements = [.yearMonthDay, .hourMinute]
        datePicker.dateValue = Date()
        addButton.target = self
        addButton.action = #selector(addTask)
        addButton.bezelStyle = .rounded
        addButton.keyEquivalent = ""
        cancelButton.target = self
        cancelButton.action = #selector(cancelEditing)
        cancelButton.bezelStyle = .rounded
        cancelButton.isHidden = true
        let dateGap = NSView()
        dateGap.setContentHuggingPriority(.init(1), for: .horizontal)
        // Date on its own line; the buttons go to the right of it while
        // adding, and get a line of their own while editing (Cancel shows).
        let dateRow = NSStackView(views: [dateToggle, datePicker, dateGap, addButton])
        dateRow.orientation = .horizontal
        dateRow.spacing = 8
        editRow.orientation = .horizontal
        editRow.spacing = 8
        let editGap = NSView()
        editGap.setContentHuggingPriority(.init(1), for: .horizontal)
        editRow.addArrangedSubview(editGap)
        editRow.addArrangedSubview(cancelButton)
        editRow.isHidden = true

        // Tab walks the form: title → note → date → time → Add (→ Cancel).
        titleField.nextKeyView = noteField
        noteField.nextKeyView = dateToggle
        dateToggle.nextKeyView = datePicker
        datePicker.nextKeyView = addButton
        addButton.nextKeyView = cancelButton
        cancelButton.nextKeyView = titleField

        modePicker.target = self
        modePicker.action = #selector(modeChanged)
        modePicker.selectedSegment = 0
        modePicker.controlSize = .small
        modePicker.segmentStyle = .rounded
        let headerGap = NSView()
        headerGap.setContentHuggingPriority(.init(1), for: .horizontal)
        let header = NSStackView(views: [dayLabel, headerGap, modePicker])
        header.orientation = .horizontal
        header.spacing = 8

        listStack.orientation = .vertical
        listStack.spacing = 6
        listStack.alignment = .leading
        listStack.translatesAutoresizingMaskIntoConstraints = false
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        // Flipped so the list starts at the top of the scroll area.
        let document = FlippedView()
        document.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(listStack)
        scroll.documentView = document

        summaryLabel.font = .systemFont(ofSize: 10.5)
        summaryLabel.textColor = NSColor(white: 1, alpha: 0.5)

        let right = NSStackView(views: [header, titleField, noteField, dateRow, editRow, scroll, summaryLabel])
        right.orientation = .vertical
        right.alignment = .leading
        right.spacing = 8
        right.translatesAutoresizingMaskIntoConstraints = false
        for view in [header, titleField, noteField, dateRow, editRow, scroll] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            view.widthAnchor.constraint(equalTo: right.widthAnchor).isActive = true
        }

        let divider = NSView()
        divider.wantsLayer = true
        divider.layer?.backgroundColor = NSColor(white: 1, alpha: 0.12).cgColor
        divider.translatesAutoresizingMaskIntoConstraints = false

        for view in [left, divider, right] { addSubview(view) }
        NSLayoutConstraint.activate([
            left.topAnchor.constraint(equalTo: topAnchor, constant: 2),
            left.leadingAnchor.constraint(equalTo: leadingAnchor),
            left.widthAnchor.constraint(equalToConstant: 248),

            divider.leadingAnchor.constraint(equalTo: left.trailingAnchor, constant: 14),
            divider.topAnchor.constraint(equalTo: topAnchor),
            divider.bottomAnchor.constraint(equalTo: bottomAnchor),
            divider.widthAnchor.constraint(equalToConstant: 1),

            right.leadingAnchor.constraint(equalTo: divider.trailingAnchor, constant: 14),
            right.trailingAnchor.constraint(equalTo: trailingAnchor),
            right.topAnchor.constraint(equalTo: topAnchor, constant: 2),
            right.bottomAnchor.constraint(equalTo: bottomAnchor),

            document.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            document.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            document.trailingAnchor.constraint(equalTo: scroll.contentView.trailingAnchor),
            listStack.topAnchor.constraint(equalTo: document.topAnchor),
            listStack.leadingAnchor.constraint(equalTo: document.leadingAnchor),
            listStack.trailingAnchor.constraint(equalTo: document.trailingAnchor, constant: -4),
            listStack.bottomAnchor.constraint(equalTo: document.bottomAnchor)
        ])
    }

    // MARK: Calendar navigation

    private func showMonth(containing date: Date) {
        let calendar = Calendar.current
        month = calendar.date(from: calendar.dateComponents([.year, .month], from: date)) ?? date
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US")
        formatter.dateFormat = "MMMM yyyy"
        monthLabel.stringValue = formatter.string(from: month)
        refreshGrid()
    }

    private func refreshGrid() {
        let calendar = Calendar.current
        guard let range = grid.visibleRange(for: month) else { return }
        var eventDays = Set<Date>()
        for entry in CalendarSource.shared.entries(from: range.start, to: range.end) {
            // An event spanning several days marks each of them.
            var day = calendar.startOfDay(for: max(entry.start, range.start))
            let last = entry.allDay ? entry.end.addingTimeInterval(-1) : entry.end
            while day <= last, day < range.end {
                eventDays.insert(day)
                guard let next = calendar.date(byAdding: .day, value: 1, to: day) else { break }
                day = next
            }
        }
        let taskDays = Set(TaskStore.shared.active.compactMap { $0.due.map { calendar.startOfDay(for: $0) } })
        grid.show(month: month, selected: selected, eventDays: eventDays, taskDays: taskDays)
    }

    private func select(_ date: Date) {
        selected = date
        let calendar = Calendar.current
        if !calendar.isDate(date, equalTo: month, toGranularity: .month) {
            showMonth(containing: date)
        }
        // New items default to the chosen day, at the current time of day.
        let now = calendar.dateComponents([.hour, .minute], from: Date())
        datePicker.dateValue = calendar.date(bySettingHour: now.hour ?? 9, minute: now.minute ?? 0, second: 0, of: date) ?? date
        reload()
    }

    @objc private func previousMonth() { shiftMonth(-1) }
    @objc private func nextMonth() { shiftMonth(1) }
    private func shiftMonth(_ delta: Int) {
        guard let next = Calendar.current.date(byAdding: .month, value: delta, to: month) else { return }
        showMonth(containing: next)
    }
    @objc private func goToday() { select(Calendar.current.startOfDay(for: Date())) }

    @objc private func openCalendarSettings() {
        if CalendarSource.shared.access == .undetermined {
            CalendarSource.shared.requestIfNeeded { [weak self] in self?.reload() }
        } else if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: Form

    @objc private func toggleDate() {
        datePicker.isEnabled = dateToggle.state == .on
    }

    @objc private func addTask() {
        let due = dateToggle.state == .on ? datePicker.dateValue : nil
        let note = noteField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let saved: Bool
        if let editingID {
            saved = TaskStore.shared.update(editingID, title: titleField.stringValue, note: note, due: due)
        } else {
            saved = TaskStore.shared.add(title: titleField.stringValue, note: note, due: due) != nil
        }
        guard saved else {
            // A title is required; put the cursor where it is missing.
            NSSound.beep()
            window?.makeFirstResponder(titleField)
            return
        }
        endEditing()
        window?.makeFirstResponder(titleField)
    }

    /// Loads a to-do into the form; Add becomes Save.
    private func beginEditing(_ task: TaskItem) {
        editingID = task.id
        titleField.stringValue = task.title
        noteField.stringValue = task.note
        dateToggle.state = task.due == nil ? .off : .on
        datePicker.isEnabled = task.due != nil
        if let due = task.due { datePicker.dateValue = due }
        addButton.title = "Save"
        cancelButton.isHidden = false
        editRow.isHidden = false
        window?.makeFirstResponder(titleField)
    }

    /// Back to adding new to-dos.
    private func endEditing() {
        editingID = nil
        titleField.stringValue = ""
        noteField.stringValue = ""
        let withDate = Prefs.bool("task.defaultDate", true)
        dateToggle.state = withDate ? .on : .off
        datePicker.isEnabled = withDate
        addButton.title = "Add"
        cancelButton.isHidden = true
        editRow.isHidden = true
    }

    @objc private func cancelEditing() {
        endEditing()
        highlightedID = nil
        reload()
        window?.makeFirstResponder(titleField)
    }

    @objc private func modeChanged() {
        highlightedID = nil
        reload()
    }

    private func openRow(_ id: UUID) { focus(taskID: id) }

    // MARK: Day list

    @objc private func reload() {
        refreshGrid()
        let calendar = Calendar.current
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US")
        formatter.dateFormat = "EEE, MMM d"
        let isToday = calendar.isDateInToday(selected)
        dayLabel.stringValue = formatter.string(from: selected) + (isToday ? " · Today" : "")

        switch CalendarSource.shared.access {
        case .granted:
            accessLabel.stringValue = "Calendar connected"
            accessLabel.textColor = NSColor(white: 1, alpha: 0.55)
            accessButton.isHidden = true
        case .undetermined:
            accessLabel.stringValue = "Calendar access not granted yet"
            accessLabel.textColor = .systemRed
            accessButton.title = "Allow"
            accessButton.isHidden = false
        case .denied:
            accessLabel.stringValue = "No calendar access. System Settings → Privacy & Security → Calendars: give OmniHub full access"
            accessLabel.textColor = .systemRed
            accessButton.title = "Open System Settings"
            accessButton.isHidden = false
        }

        for view in listStack.arrangedSubviews {
            listStack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        debugRows = []
        func section(_ text: String) {
            let label = NSTextField(labelWithString: text)
            label.font = .systemFont(ofSize: 10, weight: .semibold)
            label.textColor = NSColor(white: 1, alpha: 0.45)
            listStack.addArrangedSubview(label)
        }
        func add(_ row: NSView) {
            row.translatesAutoresizingMaskIntoConstraints = false
            listStack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: listStack.widthAnchor).isActive = true
        }

        highlightedRow = nil
        func taskRow(_ task: TaskItem) -> TaskRowView {
            let row = TaskRowView(task: task)
            row.onOpen = { [weak self] id in self?.openRow(id) }
            if task.id == highlightedID {
                row.setHighlighted(true)
                highlightedRow = row
            }
            return row
        }

        if modePicker.selectedSegment == 1 {
            // History: every finished to-do, newest first; untick to reopen.
            let done = TaskStore.shared.completed
            dayLabel.stringValue = "Done"
            if done.isEmpty {
                let empty = NSTextField(labelWithString: "Nothing finished yet")
                empty.font = .systemFont(ofSize: 12)
                empty.textColor = NSColor(white: 1, alpha: 0.4)
                listStack.addArrangedSubview(empty)
            }
            var lastDay: Date?
            for task in done {
                let day = calendar.startOfDay(for: task.completedAt ?? task.due ?? task.createdAt)
                if day != lastDay {
                    section(task.completedAt == nil ? "Earlier" : formatter.string(from: day))
                    lastDay = day
                }
                add(taskRow(task))
                debugRows.append("done: \(task.title)")
            }
            summaryLabel.stringValue = "\(TaskStore.shared.active.count) open · \(done.count) done"
            return
        }

        guard let dayEnd = calendar.date(byAdding: .day, value: 1, to: selected) else { return }
        let events = CalendarSource.shared.entries(from: selected, to: dayEnd)
        if !events.isEmpty {
            section("Calendar")
            for event in events {
                add(EventRowView(entry: event))
                debugRows.append("event: \(event.title)")
            }
        }

        let active = TaskStore.shared.active
        let dueToday = active.filter { $0.due.map { calendar.isDate($0, inSameDayAs: selected) } ?? false }
        // Today also carries what is overdue and what has no date at all.
        let overdue = isToday ? active.filter { $0.due.map { $0 < selected } ?? false } : []
        let undated = isToday ? active.filter { $0.due == nil } : []
        if !overdue.isEmpty {
            section("Overdue")
            for task in overdue { add(taskRow(task)); debugRows.append("overdue: \(task.title)") }
        }
        if !dueToday.isEmpty {
            section("To-dos")
            for task in dueToday { add(taskRow(task)); debugRows.append("task: \(task.title)") }
        }
        if !undated.isEmpty {
            section("No date")
            for task in undated { add(taskRow(task)); debugRows.append("undated: \(task.title)") }
        }
        if listStack.arrangedSubviews.isEmpty {
            let empty = NSTextField(labelWithString: "Nothing on this day")
            empty.font = .systemFont(ofSize: 12)
            empty.textColor = NSColor(white: 1, alpha: 0.4)
            listStack.addArrangedSubview(empty)
        }
        summaryLabel.stringValue = "\(active.count) open · \(TaskStore.shared.completedCount) done"
    }
}

// MARK: - Month grid

/// Six weeks of days, Monday first. Click a day to select it.
final class MonthGridView: NSView {
    static let eventColor = NSColor(srgbRed: 0.45, green: 0.85, blue: 1.0, alpha: 1)
    static let taskColor = NSColor(srgbRed: 1.0, green: 0.72, blue: 0.40, alpha: 1)

    var onSelect: ((Date) -> Void)?
    private var month = Date()
    private var selected = Date()
    private var eventDays = Set<Date>()
    private var taskDays = Set<Date>()
    private var calendar: Calendar = {
        var calendar = Calendar.current
        calendar.firstWeekday = 2
        return calendar
    }()

    override var isFlipped: Bool { true }

    /// First day shown and the day after the last one.
    func visibleRange(for month: Date) -> (start: Date, end: Date)? {
        guard let first = calendar.date(from: calendar.dateComponents([.year, .month], from: month)) else { return nil }
        let weekday = calendar.component(.weekday, from: first)
        let lead = (weekday - calendar.firstWeekday + 7) % 7
        guard let start = calendar.date(byAdding: .day, value: -lead, to: first),
              let end = calendar.date(byAdding: .day, value: 42, to: start) else { return nil }
        return (start, end)
    }

    func show(month: Date, selected: Date, eventDays: Set<Date>, taskDays: Set<Date>) {
        self.month = month
        self.selected = selected
        self.eventDays = eventDays
        self.taskDays = taskDays
        needsDisplay = true
    }

    private var headerHeight: CGFloat { 22 }
    private var cell: NSSize { NSSize(width: bounds.width / 7, height: (bounds.height - headerHeight) / 6) }

    override func draw(_ dirtyRect: NSRect) {
        guard let range = visibleRange(for: month) else { return }
        let size = cell
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        for (index, name) in ["M", "T", "W", "T", "F", "S", "S"].enumerated() {
            (name as NSString).draw(in: NSRect(x: CGFloat(index) * size.width, y: 3, width: size.width, height: 16),
                                    withAttributes: [.font: NSFont.systemFont(ofSize: 10, weight: .medium),
                                                     .foregroundColor: NSColor(white: 1, alpha: index >= 5 ? 0.38 : 0.5),
                                                     .paragraphStyle: paragraph])
        }
        for slot in 0..<42 {
            guard let day = calendar.date(byAdding: .day, value: slot, to: range.start) else { continue }
            let rect = NSRect(x: CGFloat(slot % 7) * size.width, y: headerHeight + CGFloat(slot / 7) * size.height,
                              width: size.width, height: size.height)
            let inMonth = calendar.isDate(day, equalTo: month, toGranularity: .month)
            let isToday = calendar.isDateInToday(day)
            let isSelected = calendar.isDate(day, inSameDayAs: selected)
            let side = min(rect.width, rect.height) - 8
            let bubble = NSRect(x: rect.midX - side / 2, y: rect.minY + 2, width: side, height: side)
            if isSelected {
                NSColor(srgbRed: 0.30, green: 0.62, blue: 1.0, alpha: 0.95).setFill()
                NSBezierPath(ovalIn: bubble).fill()
            } else if isToday {
                NSColor(white: 1, alpha: 0.55).setStroke()
                let ring = NSBezierPath(ovalIn: bubble.insetBy(dx: 0.5, dy: 0.5))
                ring.lineWidth = 1
                ring.stroke()
            }
            let number = "\(calendar.component(.day, from: day))" as NSString
            number.draw(in: NSRect(x: rect.minX, y: bubble.midY - 8, width: rect.width, height: 16),
                        withAttributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: isToday || isSelected ? .semibold : .regular),
                                         .foregroundColor: NSColor(white: 1, alpha: inMonth ? 0.95 : 0.28),
                                         .paragraphStyle: paragraph])
            var dots: [NSColor] = []
            if eventDays.contains(day) { dots.append(Self.eventColor) }
            if taskDays.contains(day) { dots.append(Self.taskColor) }
            let dotSize: CGFloat = 4
            var x = rect.midX - (CGFloat(dots.count) * dotSize + CGFloat(max(dots.count - 1, 0)) * 3) / 2
            for color in dots {
                color.withAlphaComponent(inMonth ? 1 : 0.4).setFill()
                NSBezierPath(ovalIn: NSRect(x: x, y: rect.maxY - dotSize - 1, width: dotSize, height: dotSize)).fill()
                x += dotSize + 3
            }
        }
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard point.y >= headerHeight, let range = visibleRange(for: month) else { return }
        let size = cell
        let column = min(6, max(0, Int(point.x / size.width)))
        let row = min(5, max(0, Int((point.y - headerHeight) / size.height)))
        if let day = calendar.date(byAdding: .day, value: row * 7 + column, to: range.start) {
            onSelect?(day)
        }
    }
}

// MARK: - Calendar event row

final class EventRowView: NSView {
    init(entry: CalendarSource.Entry) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor(white: 1, alpha: 0.06).cgColor
        layer?.cornerRadius = 7

        let bar = NSView()
        bar.wantsLayer = true
        bar.layer?.backgroundColor = entry.color.cgColor
        bar.layer?.cornerRadius = 1.5
        let title = NSTextField(labelWithString: entry.title)
        title.font = .systemFont(ofSize: 13, weight: .medium)
        title.textColor = .white
        title.lineBreakMode = .byTruncatingTail
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        let when = entry.allDay ? "All day" : "\(formatter.string(from: entry.start)) – \(formatter.string(from: entry.end))"
        let detail = NSTextField(labelWithString: "\(when) · \(entry.calendar)")
        detail.font = .monospacedDigitSystemFont(ofSize: 10.5, weight: .regular)
        detail.textColor = NSColor(white: 1, alpha: 0.55)
        detail.lineBreakMode = .byTruncatingTail
        detail.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        for view in [bar, title, detail] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 44),
            bar.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            bar.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            bar.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),
            bar.widthAnchor.constraint(equalToConstant: 3),
            title.leadingAnchor.constraint(equalTo: bar.trailingAnchor, constant: 8),
            title.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            title.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -10),
            detail.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            detail.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 1),
            detail.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -10)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }
}

final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

// MARK: - Row

final class TaskRowView: NSView {
    private let task: TaskItem
    private let checkbox = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    /// Double-click: edit this to-do.
    var onOpen: ((UUID) -> Void)?

    func setHighlighted(_ on: Bool) {
        layer?.borderWidth = on ? 1.5 : 0
        layer?.borderColor = MonthGridView.taskColor.cgColor
        layer?.backgroundColor = NSColor(white: 1, alpha: on ? 0.12 : 0.06).cgColor
    }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 { onOpen?(task.id) } else { super.mouseDown(with: event) }
    }

    init(task: TaskItem) {
        self.task = task
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor(white: 1, alpha: 0.06).cgColor
        layer?.cornerRadius = 7

        checkbox.target = self
        checkbox.action = #selector(markDone)
        checkbox.state = task.done ? .on : .off
        checkbox.toolTip = task.done ? "Reopen" : "Mark done"
        checkbox.translatesAutoresizingMaskIntoConstraints = false

        let title = NSTextField(labelWithString: task.title)
        if task.done {
            title.attributedStringValue = NSAttributedString(string: task.title, attributes: [
                .strikethroughStyle: NSUnderlineStyle.single.rawValue,
                .foregroundColor: NSColor(white: 1, alpha: 0.5),
                .font: NSFont.systemFont(ofSize: 13, weight: .medium)])
        }
        title.font = .systemFont(ofSize: 13, weight: .medium)
        title.lineBreakMode = .byTruncatingTail
        title.translatesAutoresizingMaskIntoConstraints = false

        let note = NSTextField(labelWithString: task.note)
        note.font = .systemFont(ofSize: 11)
        note.textColor = .secondaryLabelColor
        note.lineBreakMode = .byTruncatingTail
        note.isHidden = task.note.isEmpty
        note.translatesAutoresizingMaskIntoConstraints = false

        addSubview(checkbox)
        addSubview(title)
        addSubview(note)

        var constraints: [NSLayoutConstraint] = [
            heightAnchor.constraint(greaterThanOrEqualToConstant: task.note.isEmpty ? 36 : 50),

            checkbox.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            checkbox.centerYAnchor.constraint(equalTo: centerYAnchor),

            title.leadingAnchor.constraint(equalTo: checkbox.trailingAnchor, constant: 6),
            title.topAnchor.constraint(equalTo: topAnchor, constant: task.note.isEmpty ? 9 : 7),
            title.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -12)
        ]

        if !task.note.isEmpty {
            constraints += [
                note.leadingAnchor.constraint(equalTo: title.leadingAnchor),
                note.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 2),
                note.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -12)
            ]
        }

        let stamp = task.done ? task.completedAt : task.due
        if let due = stamp {
            let formatter = DateFormatter()
            formatter.dateFormat = task.done ? "'Done' HH:mm" : "MM-dd HH:mm"
            let dueLabel = NSTextField(labelWithString: formatter.string(from: due))
            dueLabel.font = .monospacedDigitSystemFont(ofSize: 10, weight: .regular)
            dueLabel.textColor = !task.done && due < Date() ? .systemRed : .tertiaryLabelColor
            dueLabel.translatesAutoresizingMaskIntoConstraints = false
            addSubview(dueLabel)
            constraints += [
                dueLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
                dueLabel.centerYAnchor.constraint(equalTo: title.centerYAnchor)
            ]
        }

        NSLayoutConstraint.activate(constraints)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    @objc private func markDone() {
        if task.done { TaskStore.shared.reopen(task.id) } else { TaskStore.shared.complete(task.id) }
    }
}
