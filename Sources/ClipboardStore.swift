import AppKit

struct ClipItem: Identifiable {
    let id: UUID
    var date: Date
    let text: String?
    let imageData: Data?
    /// Pinned entries live in the Starred tab, survive eviction, and keep a
    /// user-defined order.
    var pinned: Bool = false

    init(id: UUID = UUID(), date: Date, text: String?, imageData: Data?, pinned: Bool = false) {
        self.id = id
        self.date = date
        self.text = text
        self.imageData = imageData
        self.pinned = pinned
    }

    var image: NSImage? {
        guard let imageData else { return nil }
        return NSImage(data: imageData)
    }

    var preview: String {
        if let text { return text }
        if let image { return L("Image %ld×%ld", Int(image.size.width), Int(image.size.height)) }
        return L("Unknown")
    }
}

/// Records everything that lands on the general pasteboard.
///
/// History is built by *observing* the pasteboard: `NSPasteboard.changeCount`
/// is a monotonic counter, so polling it captures every copy from every app
/// without Accessibility or an event tap.
final class ClipboardStore {
    static let shared = ClipboardStore()

    /// Ordered favourites — index 0 is the highest priority.
    private(set) var pinnedItems: [ClipItem] = []
    /// Everything else, newest first.
    private(set) var recentItems: [ClipItem] = []

    private func notify() {
        NotificationCenter.default.post(name: .clipboardChanged, object: nil)
    }

    private var timer: Timer?
    private var lastChangeCount: Int
    private var suppressUntil = Date.distantPast

    private var maxRecent: Int { max(10, Prefs.int("clipboard.maxRecent", 120)) }
    private let maxRecentImages = 12
    private let maxTextLength = 20_000

    private var pinsDirectory: URL {
        let dir = Store.directory.appendingPathComponent("pins", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private init() {
        lastChangeCount = NSPasteboard.general.changeCount
        NotificationCenter.default.addObserver(forName: .settingsChanged, object: nil, queue: .main) { [weak self] _ in
            self?.trimToLimit()
        }
        loadPins()
        if let dtos = Store.load([ClipItemDTO].self, from: "clips.json") {
            let formatter = ISO8601DateFormatter()
            recentItems = dtos.compactMap { dto in
                guard let date = formatter.date(from: dto.date) else { return nil }
                return ClipItem(date: date, text: dto.text, imageData: nil)
            }
        }
    }

    /// Combined view: favourites first (in priority order), then recent.
    var items: [ClipItem] { pinnedItems + recentItems }

    /// Test hook: drops favourites (and their pinned images).
    func debugClearPins() {
        for item in pinnedItems { deletePinnedImage(item.id) }
        pinnedItems.removeAll()
        persistPins()
        notify()
    }

    /// Test hook: injects an entry without going through the pasteboard.
    func debugInsert(text: String) {
        insert(ClipItem(date: Date(), text: text, imageData: nil))
    }

    func start(interval: TimeInterval = 0.4) {
        guard timer == nil else { return }
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            self?.poll()
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    // MARK: Capture

    private func poll() {
        let pasteboard = NSPasteboard.general
        guard pasteboard.changeCount != lastChangeCount else { return }
        lastChangeCount = pasteboard.changeCount
        guard Date() >= suppressUntil else { return }

        // Password managers mark secrets with these types; never record them.
        let types = pasteboard.types?.map(\.rawValue) ?? []
        if types.contains("org.nspasteboard.ConcealedType")
            || types.contains("org.nspasteboard.TransientType") { return }

        if let string = pasteboard.string(forType: .string),
           !string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            insert(ClipItem(date: Date(),
                            text: String(string.prefix(maxTextLength)),
                            imageData: nil))
            return
        }

        if Prefs.bool("clipboard.images", true),
           let image = NSImage(pasteboard: pasteboard),
           let tiff = image.tiffRepresentation,
           let rep = NSBitmapImageRep(data: tiff),
           let png = rep.representation(using: .png, properties: [:]) {
            insert(ClipItem(date: Date(), text: nil, imageData: png))
        }
    }

    private func insert(_ item: ClipItem) {
        if let newText = item.text {
            // Already a favourite: just mark it as used now, so it surfaces
            // at the top of the time-ordered All list.
            if let index = pinnedItems.firstIndex(where: { $0.text == newText }) {
                pinnedItems[index].date = item.date
                persistPins()
                notify()
                return
            }
            // Copying the same text again moves it to the top instead of
            // piling up duplicates.
            recentItems.removeAll { $0.text == newText }
        } else if let data = item.imageData,
                  recentItems.first?.imageData == data {
            return
        }
        recentItems.insert(item, at: 0)

        var imageBudget = maxRecentImages
        var kept: [ClipItem] = []
        for clip in recentItems {
            if clip.imageData != nil {
                imageBudget -= 1
                if imageBudget < 0 { continue }
            }
            kept.append(clip)
            if kept.count >= maxRecent { break }
        }
        recentItems = kept
        persistRecent()
        notify()
    }

    // MARK: Favourites

    @discardableResult
    func togglePin(_ id: UUID) -> Bool {
        if let index = pinnedItems.firstIndex(where: { $0.id == id }) {
            var item = pinnedItems.remove(at: index)
            item.pinned = false
            deletePinnedImage(item.id)
            recentItems.insert(item, at: 0)
            persistPins()
            persistRecent()
            notify()
            return false
        }
        if let index = recentItems.firstIndex(where: { $0.id == id }) {
            var item = recentItems.remove(at: index)
            item.pinned = true
            pinnedItems.insert(item, at: 0)
            storePinnedImage(item)
            persistPins()
            persistRecent()
            notify()
            return true
        }
        return false
    }

    /// Moves a favourite to a new priority index (drag reorder).
    func movePinned(from source: Int, to destination: Int) {
        guard source >= 0, source < pinnedItems.count else { return }
        var target = destination
        if target > source { target -= 1 }
        target = min(max(target, 0), pinnedItems.count - 1)
        guard target != source else { return }
        let item = pinnedItems.remove(at: source)
        pinnedItems.insert(item, at: target)
        persistPins()
        notify()
    }

    /// Keyboard reorder used by the palette (⌘↑ / ⌘↓).
    func shiftPinned(_ id: UUID, by delta: Int) {
        guard let index = pinnedItems.firstIndex(where: { $0.id == id }) else { return }
        let target = index + delta
        guard target >= 0, target < pinnedItems.count else { return }
        let item = pinnedItems.remove(at: index)
        pinnedItems.insert(item, at: target)
        persistPins()
        notify()
    }

    func remove(_ id: UUID) {
        if let index = pinnedItems.firstIndex(where: { $0.id == id }) {
            deletePinnedImage(pinnedItems[index].id)
            pinnedItems.remove(at: index)
            persistPins()
        }
        recentItems.removeAll { $0.id == id }
        persistRecent()
        notify()
    }

    /// Applies a lowered history limit right away.
    func trimToLimit() {
        guard recentItems.count > maxRecent else { return }
        recentItems = Array(recentItems.prefix(maxRecent))
        persistRecent()
        notify()
    }

    /// Clears history but never touches favourites.
    func clearRecent() {
        recentItems.removeAll()
        persistRecent()
        notify()
    }

    @discardableResult
    func restore(_ item: ClipItem) -> Bool {
        suppressUntil = Date().addingTimeInterval(1.0)
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        var ok = false
        if let text = item.text {
            ok = pasteboard.setString(text, forType: .string)
        } else if let image = item.image {
            ok = pasteboard.writeObjects([image])
        }
        lastChangeCount = pasteboard.changeCount
        return ok
    }

    func filtered(_ query: String, favouritesOnly: Bool) -> [ClipItem] {
        // Starred: the user's own order. All: everything by time, newest
        // first — favourites are not floated to the top.
        let source = favouritesOnly ? pinnedItems : items.sorted { $0.date > $1.date }
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return source }
        return source.filter { item in
            if let text = item.text {
                return text.localizedCaseInsensitiveContains(trimmed)
            }
            return "Image".localizedCaseInsensitiveContains(trimmed)
        }
    }

    // MARK: Persistence

    private struct ClipItemDTO: Codable {
        let date: String
        let text: String
    }

    private struct PinDTO: Codable {
        let id: String
        let date: String
        let text: String
        let imageFile: String
    }

    private func persistRecent() {
        let formatter = ISO8601DateFormatter()
        let dtos = recentItems.compactMap { item -> ClipItemDTO? in
            guard let text = item.text else { return nil }
            return ClipItemDTO(date: formatter.string(from: item.date), text: text)
        }
        Store.save(dtos, to: "clips.json")
    }

    private func persistPins() {
        let formatter = ISO8601DateFormatter()
        let dtos = pinnedItems.map { item in
            PinDTO(id: item.id.uuidString,
                   date: formatter.string(from: item.date),
                   text: item.text ?? "",
                   imageFile: item.imageData == nil ? "" : "\(item.id.uuidString).png")
        }
        Store.save(dtos, to: "pins.json")
    }

    private func loadPins() {
        guard let dtos = Store.load([PinDTO].self, from: "pins.json") else { return }
        let formatter = ISO8601DateFormatter()
        pinnedItems = dtos.compactMap { dto in
            guard let uuid = UUID(uuidString: dto.id),
                  let date = formatter.date(from: dto.date) else { return nil }
            var data: Data?
            if !dto.imageFile.isEmpty {
                data = try? Data(contentsOf: pinsDirectory
                    .appendingPathComponent(dto.imageFile))
            }
            return ClipItem(id: uuid,
                            date: date,
                            text: dto.text.isEmpty ? nil : dto.text,
                            imageData: data,
                            pinned: true)
        }
    }

    private func storePinnedImage(_ item: ClipItem) {
        guard let data = item.imageData else { return }
        try? data.write(to: pinsDirectory.appendingPathComponent("\(item.id.uuidString).png"))
        persistPins()
    }

    private func deletePinnedImage(_ id: UUID) {
        try? FileManager.default.removeItem(at: pinsDirectory
            .appendingPathComponent("\(id.uuidString).png"))
    }
}
