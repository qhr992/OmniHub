import AppKit

/// The apps using the most CPU or memory. Processes are read with `ps` and
/// counted towards the outermost app bundle they run from, so a browser's
/// helpers add up under the browser; a process outside any bundle is listed
/// by its own name.
enum TopApps {
    struct Entry: Equatable {
        let name: String
        /// The app bundle, or the executable for a bare process.
        let path: String
        /// One of its processes (for the icon when the path is relative).
        var pid: Int32 = 0
        var cpu: Double       // percent of one core, summed (can exceed 100)
        var memory: UInt64    // resident bytes
        var processes: Int
    }

    enum Order: Int { case cpu = 0, memory = 1 }

    private static let queue = DispatchQueue(label: "omnihub.topapps", qos: .utility)
    private static var running = false

    /// Reads in the background and calls back on the main queue; a read
    /// still in flight makes this one a no-op.
    static func sample(completion: @escaping ([Entry]) -> Void) {
        guard !running else { return }
        running = true
        queue.async {
            let output = (try? UpdateChecker.run("/bin/ps", ["-Aeo", "pid=,pcpu=,rss=,comm="])) ?? ""
            let entries = parse(ps: output)
            DispatchQueue.main.async {
                running = false
                completion(entries)
            }
        }
    }

    /// `ps -Aeo pid=,pcpu=,rss=,comm=` lines (comm is the full executable
    /// path and may contain spaces), grouped per app.
    static func parse(ps output: String) -> [Entry] {
        var byPath: [String: Entry] = [:]
        for line in output.split(separator: "\n") {
            let fields = line.split(separator: " ", maxSplits: 3, omittingEmptySubsequences: true)
            guard fields.count == 4, let pid = Int32(fields[0]), let cpu = Double(fields[1]),
                  let rss = UInt64(fields[2]) else { continue }
            let command = String(fields[3]).trimmingCharacters(in: .whitespaces)
            let (path, name) = owner(of: command)
            var entry = byPath[path] ?? Entry(name: name, path: path, pid: pid, cpu: 0, memory: 0, processes: 0)
            entry.cpu += cpu
            entry.memory += rss * 1024
            entry.processes += 1
            byPath[path] = entry
        }
        return Array(byPath.values)
    }

    /// The outermost `.app` in `command`, or the command itself.
    static func owner(of command: String) -> (path: String, name: String) {
        if let range = command.range(of: ".app/") ?? (command.hasSuffix(".app") ? command.range(of: ".app") : nil) {
            let bundle = String(command[..<range.upperBound]).replacingOccurrences(of: ".app/", with: ".app")
            let name = ((bundle as NSString).lastPathComponent as NSString).deletingPathExtension
            return (bundle, name)
        }
        return (command, (command as NSString).lastPathComponent)
    }

    static func top(_ entries: [Entry], by order: Order, count: Int) -> [Entry] {
        let sorted = entries.sorted {
            order == .cpu ? ($0.cpu, $0.memory) > ($1.cpu, $1.memory) : ($0.memory, $0.cpu) > ($1.memory, $1.cpu)
        }
        return Array(sorted.prefix(count))
    }

    private static var icons: [String: NSImage] = [:]

    /// The app's icon; a generic one for bare processes.
    static func icon(for entry: Entry) -> NSImage {
        if let cached = icons[entry.path] { return cached }
        let image: NSImage
        if entry.path.hasPrefix("/"), entry.path.hasSuffix(".app") {
            image = NSWorkspace.shared.icon(forFile: entry.path)
        } else if let running = NSRunningApplication(processIdentifier: entry.pid)?.icon {
            image = running        // started from a relative path
        } else {
            image = NSImage(systemSymbolName: "gearshape", accessibilityDescription: nil) ?? NSImage()
        }
        if icons.count > 200 { icons.removeAll() }
        icons[entry.path] = image
        return image
    }

    /// The name Finder shows for an app (localized, without ".app").
    static func displayName(for entry: Entry) -> String {
        guard entry.path.hasSuffix(".app") else { return entry.name }
        return FileManager.default.displayName(atPath: entry.path)
            .replacingOccurrences(of: ".app", with: "")
    }
}
