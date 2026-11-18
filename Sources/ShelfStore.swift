import Foundation

/// One file or folder put on the Shelf.
struct ShelfItem: Codable, Equatable {
    var id = UUID().uuidString
    var name = ""
    var addedAt = Date()
    var size: Int64 = 0
    var isDirectory = false
}

/// The Shelf: files dropped on the dock ball are copied to
/// ~/Library/Application Support/OmniHub/shelf/<id>/<name> and listed on the
/// Shelf page. Items older than `retentionDays` are deleted automatically.
final class ShelfStore {
    static let shared = ShelfStore()
    static let changed = Notification.Name("omnihub.shelfChanged")
    static let retentionChoices = [1, 3, 7, 14, 30]

    /// Settings → Clipboard → Shelf (days, default 7).
    static var retentionDays: Int { max(1, Prefs.int("shelf.days", 7)) }

    private(set) var items: [ShelfItem] = []
    private let indexName = "shelf.json"
    private let queue = DispatchQueue(label: "omnihub.shelf", qos: .utility)
    private var purgeTimer: Timer?

    var directory: URL { Store.url("shelf") }

    private init() {
        items = Store.load([ShelfItem].self, from: indexName) ?? []
        // Drop entries whose files are gone (removed by hand).
        let present = items.filter { FileManager.default.fileExists(atPath: url(of: $0).path) }
        if present.count != items.count {
            items = present
            persist()
        }
    }

    func url(of item: ShelfItem) -> URL {
        directory.appendingPathComponent(item.id, isDirectory: true).appendingPathComponent(item.name)
    }

    func expiry(of item: ShelfItem) -> Date {
        item.addedAt.addingTimeInterval(TimeInterval(Self.retentionDays) * 86_400)
    }

    /// Copies the files in (off the main thread); `completion` gets how many
    /// were added and the names that failed.
    func add(_ urls: [URL], completion: ((Int, [String]) -> Void)? = nil) {
        let sources = urls.filter(\.isFileURL)
        guard !sources.isEmpty else { completion?(0, []); return }
        let directory = self.directory
        queue.async {
            var added: [ShelfItem] = []
            var failed: [String] = []
            let manager = FileManager.default
            for source in sources {
                var item = ShelfItem()
                item.name = source.lastPathComponent
                let folder = directory.appendingPathComponent(item.id, isDirectory: true)
                let target = folder.appendingPathComponent(item.name)
                do {
                    try manager.createDirectory(at: folder, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
                    try manager.copyItem(at: source, to: target)
                    var isDirectory: ObjCBool = false
                    manager.fileExists(atPath: target.path, isDirectory: &isDirectory)
                    item.isDirectory = isDirectory.boolValue
                    item.size = Self.size(of: target)
                    added.append(item)
                } catch {
                    try? manager.removeItem(at: folder)
                    failed.append(item.name)
                }
            }
            DispatchQueue.main.async {
                self.items = added.reversed() + self.items
                self.persist()
                completion?(added.count, failed)
            }
        }
    }

    func remove(_ id: String) {
        guard let item = items.first(where: { $0.id == id }) else { return }
        try? FileManager.default.removeItem(at: url(of: item).deletingLastPathComponent())
        items.removeAll { $0.id == id }
        persist()
    }

    func removeAll() {
        for item in items { try? FileManager.default.removeItem(at: url(of: item).deletingLastPathComponent()) }
        items = []
        persist()
    }

    /// Deletes items past their retention; returns how many went.
    @discardableResult
    func purgeExpired(now: Date = Date()) -> Int {
        let expired = items.filter { expiry(of: $0) <= now }
        expired.forEach { try? FileManager.default.removeItem(at: url(of: $0).deletingLastPathComponent()) }
        guard !expired.isEmpty else { return 0 }
        items.removeAll { item in expired.contains { $0.id == item.id } }
        persist()
        return expired.count
    }

    /// Purges now and then every hour while the app runs.
    func startPurging() {
        purgeExpired()
        guard purgeTimer == nil else { return }
        let timer = Timer(timeInterval: 3600, repeats: true) { [weak self] _ in self?.purgeExpired() }
        RunLoop.main.add(timer, forMode: .common)
        purgeTimer = timer
    }

    /// Test hook: backdates an item.
    func debugBackdate(_ id: String, days: Double) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        items[index].addedAt = Date().addingTimeInterval(-days * 86_400)
        persist()
    }

    private func persist() {
        Store.save(items, to: indexName)
        NotificationCenter.default.post(name: Self.changed, object: nil)
    }

    private static func size(of url: URL) -> Int64 {
        let manager = FileManager.default
        var isDirectory: ObjCBool = false
        guard manager.fileExists(atPath: url.path, isDirectory: &isDirectory) else { return 0 }
        if !isDirectory.boolValue {
            return (try? manager.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? 0
        }
        var total: Int64 = 0
        let enumerator = manager.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey])
        while let file = enumerator?.nextObject() as? URL {
            total += Int64((try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
        return total
    }
}
