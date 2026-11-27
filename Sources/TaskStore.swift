import Foundation

struct TaskItem: Codable, Identifiable {
    var id: UUID = UUID()
    var title: String
    var note: String = ""
    var due: Date?
    var done: Bool = false
    var createdAt: Date = Date()
    /// When it was ticked off (nil for to-dos finished before 1.6.0).
    var completedAt: Date?
}

/// Task board storage. Completed items stay on disk but leave the visible list.
final class TaskStore {
    static let shared = TaskStore()

    private(set) var items: [TaskItem] = []
    private init() {
        items = Store.load([TaskItem].self, from: "tasks.json") ?? []
    }

    /// Visible list: not done, soonest due first, then oldest created.
    var active: [TaskItem] {
        items.filter { !$0.done }.sorted { lhs, rhs in
            switch (lhs.due, rhs.due) {
            case let (l?, r?): return l < r
            case (nil, _?):    return false
            case (_?, nil):    return true
            case (nil, nil):   return lhs.createdAt < rhs.createdAt
            }
        }
    }

    var completedCount: Int { items.filter(\.done).count }

    /// Finished to-dos, most recently finished first.
    var completed: [TaskItem] {
        items.filter(\.done).sorted {
            ($0.completedAt ?? $0.due ?? $0.createdAt) > ($1.completedAt ?? $1.due ?? $1.createdAt)
        }
    }

    func item(_ id: UUID) -> TaskItem? { items.first { $0.id == id } }

    /// Edits a to-do in place (title is required).
    @discardableResult
    func update(_ id: UUID, title: String, note: String, due: Date?) -> Bool {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let index = items.firstIndex(where: { $0.id == id }) else { return false }
        items[index].title = trimmed
        items[index].note = note
        items[index].due = due
        persist()
        return true
    }

    @discardableResult
    func add(title: String, note: String, due: Date?) -> TaskItem? {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let item = TaskItem(title: trimmed, note: note, due: due)
        items.append(item)
        persist()
        return item
    }

    func complete(_ id: UUID) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        items[index].done = true
        items[index].completedAt = Date()
        persist()
    }

    func reopen(_ id: UUID) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        items[index].done = false
        items[index].completedAt = nil
        persist()
    }

    func remove(_ id: UUID) {
        items.removeAll { $0.id == id }
        persist()
    }

    /// Drops every finished task for good.
    func clearCompleted() {
        items.removeAll { $0.done }
        persist()
    }

    private func persist() {
        Store.save(items, to: "tasks.json")
        // Several views (task board, dock) listen, so this is a broadcast.
        NotificationCenter.default.post(name: .tasksChanged, object: nil)
    }
}

extension String {
    /// Line breaks folded into spaces, for a one-line label.
    var singleLine: String {
        split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }
}
