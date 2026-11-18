import Foundation

/// Tiny JSON persistence under ~/Library/Application Support/OmniHub.
enum Store {
    static let directory: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                            in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("OmniHub", isDirectory: true)
        // The app used to be called SnaCut: carry its data over once.
        let legacy = base.appendingPathComponent("SnaCut", isDirectory: true)
        if !FileManager.default.fileExists(atPath: dir.path),
           FileManager.default.fileExists(atPath: legacy.path) {
            try? FileManager.default.copyItem(at: legacy, to: dir)
        }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    static func url(_ name: String) -> URL { directory.appendingPathComponent(name) }

    static func load<T: Decodable>(_ type: T.Type, from name: String) -> T? {
        guard let data = try? Data(contentsOf: url(name)) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }

    static func save<T: Encodable>(_ value: T, to name: String) {
        guard let data = try? JSONEncoder().encode(value) else { return }
        try? data.write(to: url(name), options: .atomic)
    }
}

/// Lightweight preference facade (UserDefaults-backed).
enum Prefs {
    static func string(_ key: String, _ fallback: String = "") -> String {
        UserDefaults.standard.string(forKey: key) ?? fallback
    }
    static func double(_ key: String, _ fallback: Double) -> Double {
        UserDefaults.standard.object(forKey: key) as? Double ?? fallback
    }
    static func int(_ key: String, _ fallback: Int) -> Int {
        UserDefaults.standard.object(forKey: key) as? Int ?? fallback
    }
    static func bool(_ key: String, _ fallback: Bool = false) -> Bool {
        UserDefaults.standard.object(forKey: key) as? Bool ?? fallback
    }
    static func set(_ key: String, _ value: Any?) {
        UserDefaults.standard.set(value, forKey: key)
    }
}
