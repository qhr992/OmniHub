import AppKit
import ApplicationServices

/// Play mode and like through the player's own menu bar, for players that
/// accept only play / pause / next / previous from other apps (they register
/// no shuffle, repeat or like command with MediaRemote, so those commands
/// are dropped). Needs Accessibility permission.
enum PlayerMenu {
    struct Entry: Equatable {
        let title: String
        /// Menu titles above the item, e.g. ["Controls", "Play Mode"].
        let path: [String]
        let checked: Bool
        let enabled: Bool
        /// Index into `elements` of the scan that produced it.
        let handle: Int
    }

    struct Scan {
        let entries: [Entry]
        fileprivate let elements: [AXUIElement]
        /// Every item title of the menus that hold a relevant item
        /// (diagnostics: shows what the player really calls things).
        var menus: [(path: String, titles: [String])] = []
        static let empty = Scan(entries: [], elements: [])
    }

    /// Modes the player's menu offers (a toggle-only player has just one).
    static func modes(in entries: [Entry]) -> Set<MediaObserver.PlayMode> {
        Set(entries.compactMap { mode(of: $0.title) })
    }

    // MARK: Matching (pure; see --dock-selftest)

    static let likeWords = ["喜欢", "红心", "Like", "Love"]
    static let unlikeWords = ["取消喜欢", "取消红心", "不喜欢", "Unlike", "Dislike", "Remove from Liked", "Unlove"]
    static let modeWords: [(MediaObserver.PlayMode, [String])] = [
        (.repeatOne, ["单曲循环", "Repeat One", "Repeat Song", "Repeat Track"]),
        (.shuffle, ["随机播放", "随机", "Shuffle"]),
        (.order, ["顺序播放", "列表循环", "Repeat All", "Repeat Playlist", "Repeat Off", "In Order", "List Loop"])
    ]

    private static func has(_ title: String, _ words: [String]) -> Bool {
        words.contains { title.range(of: $0, options: .caseInsensitive) != nil }
    }

    static func isUnlike(_ title: String) -> Bool { has(title, unlikeWords) }
    static func isLike(_ title: String) -> Bool { has(title, likeWords) && !isUnlike(title) }

    static func mode(of title: String) -> MediaObserver.PlayMode? {
        modeWords.first { has(title, $0.1) }?.0
    }

    static func isRelevant(_ title: String) -> Bool {
        isLike(title) || isUnlike(title) || mode(of: title) != nil || transport(of: title) != nil
    }

    /// Play / pause / next / previous items: how OmniHub controls a music app
    /// that does not hold Now Playing (system commands reach only the one that does).
    enum Transport: Equatable { case play, pause, toggle, next, previous }

    static let transportWords: [(Transport, [String])] = [
        (.toggle, ["播放/暂停", "Play/Pause", "Play / Pause"]),
        (.pause, ["暂停", "Pause"]),
        (.play, ["播放", "Play"]),
        (.next, ["下一个", "下一首", "Next", "Next Track", "Next Song"]),
        (.previous, ["上一个", "上一首", "Previous", "Previous Track", "Previous Song"])
    ]

    /// Whole titles only: "播放模式" or "Play Next" are not transport items.
    static func transport(of title: String) -> Transport? {
        let trimmed = title.trimmingCharacters(in: .whitespaces)
        return transportWords.first { $0.1.contains { $0.caseInsensitiveCompare(trimmed) == .orderedSame } }?.0
    }

    /// The item that does `wanted`; play / pause fall back to a play/pause item.
    static func transportTarget(_ entries: [Entry], _ wanted: Transport) -> Entry? {
        let usable = entries.filter(\.enabled)
        if let item = usable.first(where: { transport(of: $0.title) == wanted }) { return item }
        guard wanted == .play || wanted == .pause else { return nil }
        return usable.first { transport(of: $0.title) == .toggle }
    }

    /// The mode whose menu item carries the check mark.
    static func currentMode(_ entries: [Entry]) -> MediaObserver.PlayMode? {
        entries.first { $0.checked && mode(of: $0.title) != nil }.flatMap { mode(of: $0.title) }
    }

    /// The item to press to reach `next`.
    static func modeTarget(_ entries: [Entry], next: MediaObserver.PlayMode) -> Entry? {
        let usable = entries.filter(\.enabled)
        if let direct = usable.first(where: { mode(of: $0.title) == next && !$0.checked }) { return direct }
        // A player with on/off toggles (Shuffle, Repeat One) and no "in order"
        // item: switching the checked toggle off goes back to order.
        if next == .order { return usable.first { $0.checked && mode(of: $0.title) != nil } }
        return nil
    }

    /// Liked when an "Unlike" item is offered or the "Like" item is checked.
    static func likedState(_ entries: [Entry]) -> Bool? {
        if entries.contains(where: { isUnlike($0.title) }) { return true }
        if let like = entries.first(where: { isLike($0.title) }) { return like.checked ? true : (hasOnlyToggle(entries) ? false : nil) }
        return nil
    }

    private static func hasOnlyToggle(_ entries: [Entry]) -> Bool {
        entries.filter { isLike($0.title) }.count == 1
    }

    static func likeTarget(_ entries: [Entry], liked: Bool?) -> Entry? {
        let usable = entries.filter(\.enabled)
        if liked == true, let unlike = usable.first(where: { isUnlike($0.title) }) { return unlike }
        return usable.first { isLike($0.title) } ?? usable.first { isUnlike($0.title) }
    }

    // MARK: Accessibility

    static var isTrusted: Bool { AXIsProcessTrusted() }

    /// Shows the system prompt for Accessibility (once per launch).
    private static var prompted = false
    static func promptForTrust() {
        guard !prompted else { return }
        prompted = true
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    /// Walks the app's menu bar (three levels deep) and keeps the items about
    /// play mode and liking.
    static func scan(pid: pid_t) -> Scan {
        guard pid > 0, isTrusted else { return .empty }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.6)
        guard let bar: AXUIElement = attribute(app, kAXMenuBarAttribute) else { return .empty }
        var entries: [Entry] = []
        var elements: [AXUIElement] = []
        var menus: [(String, [String])] = []
        // Skip the Apple menu.
        for top in children(bar).dropFirst() {
            let topTitle = string(top, kAXTitleAttribute)
            for menu in children(top) { walk(menu, path: [topTitle], depth: 0, into: &entries, &elements, &menus) }
        }
        var scan = Scan(entries: entries, elements: elements)
        scan.menus = menus.map { (path: $0.0, titles: $0.1) }
        return scan
    }

    private static func walk(_ menu: AXUIElement, path: [String], depth: Int,
                             into entries: inout [Entry], _ elements: inout [AXUIElement],
                             _ menus: inout [(String, [String])]) {
        guard depth < 3 else { return }
        let items = children(menu)
        let titles = items.map { item -> String in
            let title = string(item, kAXTitleAttribute)
            let mark = string(item, kAXMenuItemMarkCharAttribute)
            return title.isEmpty ? "—" : (mark.isEmpty ? title : "\(title) \(mark)")
        }
        if titles.contains(where: { isRelevant($0) }) { menus.append((path.joined(separator: " › "), titles)) }
        for item in items {
            let title = string(item, kAXTitleAttribute)
            if !title.isEmpty, isRelevant(title) {
                let mark = string(item, kAXMenuItemMarkCharAttribute)
                let enabled: Bool = attribute(item, kAXEnabledAttribute) ?? true
                entries.append(Entry(title: title, path: path, checked: !mark.isEmpty, enabled: enabled,
                                     handle: elements.count))
                elements.append(item)
            }
            for submenu in children(item) where string(submenu, kAXRoleAttribute) == kAXMenuRole {
                walk(submenu, path: path + [title], depth: depth + 1, into: &entries, &elements, &menus)
            }
        }
    }

    @discardableResult
    static func press(_ entry: Entry, in scan: Scan) -> Bool {
        guard entry.handle < scan.elements.count else { return false }
        return AXUIElementPerformAction(scan.elements[entry.handle], kAXPressAction as CFString) == .success
    }

    private static func attribute<T>(_ element: AXUIElement, _ name: String) -> T? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value as? T
    }

    private static func string(_ element: AXUIElement, _ name: String) -> String {
        attribute(element, name) ?? ""
    }

    private static func children(_ element: AXUIElement) -> [AXUIElement] {
        attribute(element, kAXChildrenAttribute) ?? []
    }
}
