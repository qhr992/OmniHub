import Foundation
import Security

extension Notification.Name {
    static let connectionsChanged = Notification.Name("omnihub.connectionsChanged")
    static let transfersChanged = Notification.Name("omnihub.transfersChanged")
}

/// A proxy a connection (or a port forward) can go through.
struct ProxyConfig: Codable, Equatable {
    var id = UUID().uuidString
    var name = "New Proxy"
    /// "http", "https" (TLS to the proxy) or "socks5".
    var kind = "socks5"
    var host = ""
    var port = 1080
    var username = ""
    /// Vault entry holding the proxy password ("" = none).
    var secretID = ""
}

/// One command run for the user after login, optionally followed by an
/// answer to what the command asks — e.g. `security unlock-keychain …`,
/// wait for its password prompt, type the password, Return.
struct AutoStep: Codable, Equatable {
    /// The command line to run.
    var send = ""
    /// Text of the prompt to wait for before answering. Empty = any
    /// password / passphrase / (yes/no) prompt.
    var expect = ""
    /// Plain answer to type at the prompt ("" = none).
    var reply = ""
    /// Vault entry to type at the prompt instead of `reply` ("" = none).
    var secretID = ""

    var answers: Bool { !reply.isEmpty || !secretID.isEmpty }

    init(send: String = "", expect: String = "", reply: String = "", secretID: String = "") {
        self.send = send
        self.expect = expect
        self.reply = reply
        self.secretID = secretID
    }

    private enum Keys: String, CodingKey { case send, expect, reply, secretID }

    init(from decoder: Decoder) throws {
        let box = try decoder.container(keyedBy: Keys.self)
        send = try box.decodeIfPresent(String.self, forKey: .send) ?? ""
        expect = try box.decodeIfPresent(String.self, forKey: .expect) ?? ""
        secretID = try box.decodeIfPresent(String.self, forKey: .secretID) ?? ""
        if let reply = try box.decodeIfPresent(String.self, forKey: .reply) {
            self.reply = reply
        } else {
            // 1.3.0 stored "wait for X, then send Y" as a step of its own;
            // `migrated` folds those into the command before them.
            legacy = true
        }
    }

    /// Decoded from the 1.3.0 layout (not saved).
    private(set) var legacy = false

    static func == (a: AutoStep, b: AutoStep) -> Bool {
        a.send == b.send && a.expect == b.expect && a.reply == b.reply && a.secretID == b.secretID
    }

    /// Converts steps saved by 1.3.0.
    static func migrated(_ steps: [AutoStep]) -> [AutoStep] {
        guard steps.contains(where: \.legacy) else { return steps }
        var result: [AutoStep] = []
        for old in steps {
            let isAnswer = !old.expect.isEmpty || !old.secretID.isEmpty
            if isAnswer, var previous = result.last, !previous.answers {
                previous.expect = old.expect
                previous.reply = old.send
                previous.secretID = old.secretID
                result[result.count - 1] = previous
            } else if !isAnswer {
                result.append(AutoStep(send: old.send))
            }
        }
        return result
    }
}

struct ConnectionProfile: Codable, Equatable {
    var id = UUID().uuidString
    var name = "New Connection"
    var group = ""
    /// "ssh" or "telnet".
    var kind = "ssh"
    var host = ""
    var port = 22
    /// Login user of the "Username & Password" credential.
    var user = ""
    /// Credential: "" = Username & Password with nothing saved (ask when
    /// connecting); `ownSecretID` = Username & Password with the password in
    /// the Keychain; anything else = a Vault entry (its Username is used).
    var secretID = ""
    var keyPath = ""
    var proxyID = ""
    var steps: [AutoStep] = []

    var destination: String { loginUser.isEmpty ? host : "\(loginUser)@\(host)" }
    var summary: String { "\(destination):\(port)" }
}

/// Name of a stored password; the password itself lives in the Keychain.
extension ConnectionProfile {
    /// Keychain item of the password typed for this connection alone.
    var ownSecretID: String { "conn:" + id }
    var hasOwnPassword: Bool { Vault.secret(for: ownSecretID) != nil }

    /// The Vault entry chosen as the credential, if one is.
    var vaultEntry: VaultEntry? {
        guard !secretID.isEmpty, secretID != ownSecretID else { return nil }
        return ConnectionStore.shared.vault.first { $0.id == secretID }
    }

    /// User to log in as: the Vault entry's Username when a Vault entry is
    /// the credential ("" = the server needs no account name), otherwise
    /// the Username typed for this connection.
    var loginUser: String {
        if let entry = vaultEntry { return entry.account }
        return user
    }
}

struct VaultEntry: Codable, Equatable {
    var id = UUID().uuidString
    var name = "New Password"
    /// Username (optional; shown as "Username" in the Vault form).
    var account = ""
}

/// Connections / Vault / Proxies, persisted in connections.json.
final class ConnectionStore {
    static let shared = ConnectionStore()

    struct Contents: Codable {
        var profiles: [ConnectionProfile] = []
        var proxies: [ProxyConfig] = []
        var vault: [VaultEntry] = []
    }

    private(set) var contents: Contents

    private init() {
        contents = Store.load(Contents.self, from: "connections.json") ?? Contents()
        for index in contents.profiles.indices {
            contents.profiles[index].steps = AutoStep.migrated(contents.profiles[index].steps)
        }
        migrateVaultUsernames()
    }

    /// Profiles used to carry their own user next to a Vault password; now a
    /// Vault credential brings its Username. An entry without one takes the
    /// user its profiles agreed on, so existing connections keep working.
    private func migrateVaultUsernames() {
        var changed = false
        for index in contents.vault.indices where contents.vault[index].account.isEmpty {
            let id = contents.vault[index].id
            let users = Set(contents.profiles.filter { $0.secretID == id }.map(\.user).filter { !$0.isEmpty })
            if users.count == 1, let user = users.first {
                contents.vault[index].account = user
                changed = true
            }
        }
        if changed { Store.save(contents, to: "connections.json") }
    }

    var profiles: [ConnectionProfile] { contents.profiles }
    var proxies: [ProxyConfig] { contents.proxies }
    var vault: [VaultEntry] { contents.vault }

    /// Group names in use, sorted; "" (ungrouped) is not included.
    var groups: [String] {
        Array(Set(contents.profiles.map(\.group).filter { !$0.isEmpty })).sorted()
    }

    func profile(_ id: String) -> ConnectionProfile? { contents.profiles.first { $0.id == id } }
    func proxy(_ id: String) -> ProxyConfig? { id.isEmpty ? nil : contents.proxies.first { $0.id == id } }

    private func persist() {
        Store.save(contents, to: "connections.json")
        // The file names hosts and accounts: keep it private to the user.
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: Store.url("connections.json").path)
        NotificationCenter.default.post(name: .connectionsChanged, object: nil)
    }

    func upsert(_ profile: ConnectionProfile) {
        if let index = contents.profiles.firstIndex(where: { $0.id == profile.id }) {
            contents.profiles[index] = profile
        } else {
            contents.profiles.append(profile)
        }
        persist()
    }

    @discardableResult
    func clone(_ id: String) -> ConnectionProfile? {
        guard let original = profile(id) else { return nil }
        var copy = original
        copy.id = UUID().uuidString
        copy.name += " copy"
        // A password typed for the original goes with the copy.
        if original.secretID == original.ownSecretID {
            copy.secretID = ""
            if let password = Vault.secret(for: original.ownSecretID), Vault.set(password, for: copy.ownSecretID) {
                copy.secretID = copy.ownSecretID
            }
        }
        contents.profiles.append(copy)
        persist()
        return copy
    }

    func removeProfile(_ id: String) {
        if let profile = profile(id) { Vault.remove(profile.ownSecretID) }
        contents.profiles.removeAll { $0.id == id }
        persist()
    }

    /// A password typed for one connection (not shared through the Vault):
    /// kept in the Keychain and selected for that connection.
    @discardableResult
    func setOwnPassword(_ password: String, for id: String) -> Bool {
        guard var profile = profile(id), !password.isEmpty, Vault.set(password, for: profile.ownSecretID) else { return false }
        profile.secretID = profile.ownSecretID
        upsert(profile)
        return true
    }

    func upsert(_ proxy: ProxyConfig) {
        if let index = contents.proxies.firstIndex(where: { $0.id == proxy.id }) {
            contents.proxies[index] = proxy
        } else {
            contents.proxies.append(proxy)
        }
        persist()
    }

    func removeProxy(_ id: String) {
        contents.proxies.removeAll { $0.id == id }
        for index in contents.profiles.indices where contents.profiles[index].proxyID == id {
            contents.profiles[index].proxyID = ""
        }
        persist()
    }

    /// `secret` nil keeps the stored password as it is.
    func upsert(_ entry: VaultEntry, secret: String?) {
        if let index = contents.vault.firstIndex(where: { $0.id == entry.id }) {
            contents.vault[index] = entry
        } else {
            contents.vault.append(entry)
        }
        if let secret { Vault.set(secret, for: entry.id) }
        persist()
    }

    func removeVaultEntry(_ id: String) {
        contents.vault.removeAll { $0.id == id }
        Vault.remove(id)
        for index in contents.profiles.indices {
            if contents.profiles[index].secretID == id { contents.profiles[index].secretID = "" }
            for step in contents.profiles[index].steps.indices where contents.profiles[index].steps[step].secretID == id {
                contents.profiles[index].steps[step].secretID = ""
            }
        }
        for index in contents.proxies.indices where contents.proxies[index].secretID == id {
            contents.proxies[index].secretID = ""
        }
        persist()
    }
}

/// Vault: passwords in the login Keychain, all of them in one generic-password
/// item (a JSON map id → password), so macOS asks for access once rather than
/// once per password. Builds signed without a developer team ID are told
/// apart by their code, so after an update the question comes back — once,
/// and "Always Allow" settles it for that build.
///
/// Older versions kept one item per password. The first time the vault is
/// opened those are moved into the shared item (macOS asks for each one this
/// last time) and deleted. An item whose access was refused stays where it
/// is, and nothing is written while the shared item cannot be read, so a
/// refused prompt never loses a password.
enum Vault {
    /// `OMNIHUB_VAULT_SERVICE` gives tests a Keychain service of their own.
    static var service = ProcessInfo.processInfo.environment["OMNIHUB_VAULT_SERVICE"] ?? "com.local.omnihub.vault"
    /// Account name of the shared item. Old per-password items use the id.
    private static let sharedAccount = "omnihub-vault"
    private static let label = "OmniHub Vault"

    private enum State {
        case loaded([String: String])
        case unreadable(OSStatus)
    }

    /// The decoded shared item, kept for the life of the process.
    private static var cache: [String: String]?

    @discardableResult
    static func set(_ secret: String, for id: String) -> Bool {
        guard !id.isEmpty, case .loaded(var map) = state() else { return false }
        map[id] = secret
        return save(map)
    }

    static func secret(for id: String) -> String? {
        guard !id.isEmpty, case .loaded(let map) = state() else { return nil }
        return map[id]
    }

    static func remove(_ id: String) {
        guard !id.isEmpty, case .loaded(var map) = state(), map[id] != nil else { return }
        map[id] = nil
        save(map)
    }

    /// Test hook: forget what was read, so the next call reads the Keychain.
    static func debugForget() { cache = nil }

    /// Accounts of this service's Keychain items: attributes only, so no
    /// password is read and macOS does not ask (tests, diagnostics).
    static var debugAccounts: [String] {
        let request: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                      kSecAttrService as String: service,
                                      kSecReturnAttributes as String: true,
                                      kSecMatchLimit as String: kSecMatchLimitAll]
        var result: CFTypeRef?
        guard SecItemCopyMatching(request as CFDictionary, &result) == errSecSuccess,
              let items = result as? [[String: Any]] else { return [] }
        return items.compactMap { $0[kSecAttrAccount as String] as? String }.sorted()
    }

    /// One line for the diagnostics.
    static var debugSummary: String {
        let accounts = debugAccounts
        return "vault keychain items=\(accounts.count) shared=\(accounts.contains(sharedAccount)) "
            + "older=\(accounts.filter { $0 != sharedAccount }.count)"
    }

    /// Test hook: delete every item of this service.
    static func debugDeleteAll() {
        let match: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: service]
        while SecItemDelete(match as CFDictionary) == errSecSuccess {}
        cache = nil
    }

    // MARK: Keychain

    private static func query(account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    /// The shared map, with old per-password items moved into it first.
    private static func state() -> State {
        if let cache { return .loaded(cache) }
        var map: [String: String] = [:]
        var request = query(account: sharedAccount)
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            guard let data = result as? Data,
                  let decoded = try? JSONDecoder().decode([String: String].self, from: data) else {
                return .unreadable(errSecDecode)
            }
            map = decoded
        case errSecItemNotFound:
            break
        default:
            return .unreadable(status)              // refused or locked: touch nothing
        }
        let old = readOldItems(into: &map)
        if !old.moved.isEmpty {
            guard save(map) else { return .unreadable(errSecIO) }
            old.moved.forEach { SecItemDelete(query(account: $0) as CFDictionary) }
        }
        // An old item that was refused is asked for again next time.
        cache = old.refused ? nil : map
        return .loaded(map)
    }

    /// Reads the per-password items of older versions into `map`: the
    /// accounts that were read (only those may be deleted), and whether any
    /// could not be read.
    private static func readOldItems(into map: inout [String: String]) -> (moved: [String], refused: Bool) {
        var request: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                      kSecAttrService as String: service,
                                      kSecReturnAttributes as String: true,
                                      kSecMatchLimit as String: kSecMatchLimitAll]
        var result: CFTypeRef?
        guard SecItemCopyMatching(request as CFDictionary, &result) == errSecSuccess,
              let items = result as? [[String: Any]] else { return ([], false) }
        var moved: [String] = []
        var refused = false
        for account in items.compactMap({ $0[kSecAttrAccount as String] as? String }) where account != sharedAccount {
            request = query(account: account)
            request[kSecReturnData as String] = true
            request[kSecMatchLimit as String] = kSecMatchLimitOne
            var data: CFTypeRef?
            guard SecItemCopyMatching(request as CFDictionary, &data) == errSecSuccess,
                  let bytes = data as? Data, let secret = String(data: bytes, encoding: .utf8) else {
                refused = true
                continue
            }
            if map[account] == nil { map[account] = secret }
            moved.append(account)
        }
        return (moved, refused)
    }

    /// Writes the map into the shared item (updated in place; created the
    /// first time).
    @discardableResult
    private static func save(_ map: [String: String]) -> Bool {
        guard let data = try? JSONEncoder().encode(map) else { return false }
        let match = query(account: sharedAccount)
        var status = SecItemUpdate(match as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var item = match
            item[kSecValueData as String] = data
            item[kSecAttrLabel as String] = label
            status = SecItemAdd(item as CFDictionary, nil)
        }
        guard status == errSecSuccess else { return false }
        cache = map
        return true
    }
}

/// Where a terminal tab is connected to, and how to launch it.
struct RemoteTarget {
    var kind = "ssh"
    var user = ""
    var host = ""
    var port = 22
    var profile: ConnectionProfile?
    /// Arguments of an `ssh …` line typed by hand (nil for profiles).
    var rawArguments: [String]?
    /// Control socket of this tab's connection (ssh only).
    var controlPath = ""

    /// "alice@192.0.2.10:22"
    var display: String {
        let user = self.user.isEmpty ? NSUserName() : self.user
        return "\(user)@\(host):\(port)"
    }

    var title: String { profile?.name ?? host }
    var isSSH: Bool { kind == "ssh" }

    static var executable: String { Bundle.main.executablePath ?? CommandLine.arguments[0] }

    private static var controlDirectory: String {
        // Short path: a Unix socket path is limited to about 100 bytes.
        let dir = NSHomeDirectory() + "/.omnihub/cm"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        return dir
    }

    static func newControlPath() -> String {
        controlDirectory + "/" + UUID().uuidString.prefix(8).lowercased()
    }

    init(profile: ConnectionProfile) {
        self.profile = profile
        kind = profile.kind
        user = profile.loginUser
        host = profile.host
        port = profile.port
        if isSSH { controlPath = Self.newControlPath() }
    }

    /// Parses what was typed into the quick-connect field: `ssh …`,
    /// `telnet host [port]`, or just `user@host[:port]`.
    init?(commandLine: String) {
        var tokens = Self.tokenize(commandLine)
        guard let first = tokens.first else { return nil }
        if first == "telnet" {
            guard tokens.count >= 2 else { return nil }
            kind = "telnet"
            host = tokens[1]
            port = tokens.count >= 3 ? Int(tokens[2]) ?? 23 : 23
            return
        }
        if first == "ssh" { tokens.removeFirst() }
        guard !tokens.isEmpty else { return nil }

        // Options of ssh(1) that take an argument.
        let withArgument = Set("BbcDEeFIiJLlmOoPpQRSWw")
        var destination: String?
        var index = 0
        while index < tokens.count {
            let token = tokens[index]
            if token.hasPrefix("-"), token.count >= 2 {
                let flag = token[token.index(after: token.startIndex)]
                if withArgument.contains(flag) {
                    let value: String?
                    if token.count > 2 {
                        value = String(token.dropFirst(2))
                    } else {
                        index += 1
                        value = index < tokens.count ? tokens[index] : nil
                    }
                    if flag == "p", let value, let number = Int(value) { port = number }
                    if flag == "l", let value { user = value }
                }
                index += 1
                continue
            }
            destination = token
            break
        }
        guard var dest = destination else { return nil }
        if dest.hasPrefix("ssh://") { dest = String(dest.dropFirst(6)) }
        if let at = dest.lastIndex(of: "@") {
            user = String(dest[..<at])
            dest = String(dest[dest.index(after: at)...])
        }
        // "host:2222" (not an IPv6 literal) as a shorthand for -p.
        var extraPort: [String] = []
        if dest.filter({ $0 == ":" }).count == 1, let colon = dest.firstIndex(of: ":"),
           let number = Int(dest[dest.index(after: colon)...]) {
            port = number
            dest = String(dest[..<colon])
            extraPort = ["-p", "\(number)"]
            // Rewrite the destination token without the port.
            if let position = tokens.firstIndex(of: destination ?? "") {
                tokens[position] = user.isEmpty ? dest : "\(user)@\(dest)"
            }
        }
        guard !dest.isEmpty, !dest.contains(" ") else { return nil }
        host = dest
        rawArguments = extraPort + tokens
        controlPath = Self.newControlPath()
    }

    /// Splits like a shell would, honouring single and double quotes.
    static func tokenize(_ line: String) -> [String] {
        var tokens: [String] = []
        var current = ""
        var quote: Character?
        var active = false
        for character in line {
            if let open = quote {
                if character == open { quote = nil } else { current.append(character) }
            } else if character == "\"" || character == "'" {
                quote = character
                active = true
            } else if character == " " || character == "\t" {
                if active { tokens.append(current); current = ""; active = false }
            } else {
                current.append(character)
                active = true
            }
        }
        if active { tokens.append(current) }
        return tokens
    }

    private func proxyOption(_ proxyID: String) -> [String] {
        guard ConnectionStore.shared.proxy(proxyID) != nil else { return [] }
        return ["-o", "ProxyCommand='\(Self.executable)' --proxy-connect \(proxyID) %h %p"]
    }

    /// Environment that lets ssh fetch the profile's password from the vault.
    func askpassEnvironment() -> [String: String] {
        guard let profile, !profile.secretID.isEmpty else { return [:] }
        return ["SSH_ASKPASS": Self.executable,
                "SSH_ASKPASS_REQUIRE": "force",
                "OMNIHUB_ASKPASS_SECRET": profile.secretID]
    }

    /// Command line and extra environment for the tab's own process.
    func launch() -> (arguments: [String], environment: [String: String]) {
        if kind == "telnet" {
            var arguments = [Self.executable, "--telnet", host, "\(port)"]
            if let proxyID = profile?.proxyID, ConnectionStore.shared.proxy(proxyID) != nil {
                arguments += ["--proxy", proxyID]
            }
            return (arguments, [:])
        }
        var arguments = ["/usr/bin/ssh", "-o", "ControlMaster=yes", "-o", "ControlPath=\(controlPath)",
                         "-o", "ControlPersist=no"]
        guard let profile else { return (arguments + (rawArguments ?? [host]), [:]) }
        arguments += ["-o", "ServerAliveInterval=30", "-p", "\(profile.port)"]
        arguments += identityOptions(profile)
        arguments += proxyOption(profile.proxyID)
        arguments.append(profile.destination)
        return (arguments, askpassEnvironment())
    }

    private func identityOptions(_ profile: ConnectionProfile) -> [String] {
        var options: [String] = []
        if !profile.keyPath.isEmpty {
            options += ["-i", (profile.keyPath as NSString).expandingTildeInPath]
        }
        if !profile.secretID.isEmpty {
            // The password comes from the vault through SSH_ASKPASS, which
            // cannot show a host-key question: new hosts are accepted, a
            // changed key still fails.
            options += ["-o", "StrictHostKeyChecking=accept-new", "-o", "NumberOfPasswordPrompts=1"]
        }
        return options
    }

    /// A one-off login that runs nothing and exits (Test Connection).
    /// Telnet: just reaches the port, through the proxy if there is one.
    func testLaunch() -> (arguments: [String], environment: [String: String]) {
        guard let profile, kind == "ssh" else { return launch() }
        var arguments = ["/usr/bin/ssh", "-T", "-o", "ControlMaster=no", "-o", "ControlPath=none",
                         "-o", "ConnectTimeout=8", "-o", "StrictHostKeyChecking=accept-new", "-p", "\(profile.port)"]
        arguments += identityOptions(profile)
        // Without a stored password nothing can be typed: fail, do not hang.
        if profile.secretID.isEmpty { arguments += ["-o", "BatchMode=yes"] }
        arguments += proxyOption(profile.proxyID)
        arguments += [profile.destination, "exit"]
        return (arguments, askpassEnvironment())
    }

    /// `ssh` talking to this tab's existing connection (no new login).
    func muxArguments(_ extra: [String]) -> [String] {
        ["/usr/bin/ssh", "-o", "ControlPath=\(controlPath)", "-o", "ControlMaster=no", "-o", "BatchMode=yes"]
            + extra
    }

    func sftpArguments() -> [String] {
        ["/usr/bin/sftp", "-q", "-o", "ControlPath=\(controlPath)", "-o", "ControlMaster=no",
         "-o", "BatchMode=yes", "-b", "-", host]
    }

    /// A separate ssh that only carries one port forward, optionally through
    /// another proxy. Needs a profile (it logs in again by itself).
    func standaloneForwardArguments(spec: [String], proxyID: String) -> (arguments: [String], environment: [String: String])? {
        guard let profile else { return nil }
        var arguments = ["/usr/bin/ssh", "-N", "-o", "ExitOnForwardFailure=yes", "-o", "ServerAliveInterval=30",
                         "-o", "ControlMaster=no", "-o", "ControlPath=none", "-p", "\(profile.port)"]
        arguments += identityOptions(profile)
        if profile.secretID.isEmpty { arguments += ["-o", "BatchMode=yes"] }
        arguments += proxyOption(proxyID.isEmpty ? profile.proxyID : proxyID)
        arguments += spec
        arguments.append(profile.destination)
        return (arguments, askpassEnvironment())
    }
}

/// Runs a command off the main thread and hands back its output.
enum Subprocess {
    struct Result {
        let status: Int32
        let output: String
        let error: String
        var ok: Bool { status == 0 }
        /// The most useful line of what went wrong.
        var message: String {
            let text = (error.isEmpty ? output : error).trimmingCharacters(in: .whitespacesAndNewlines)
            return text.split(separator: "\n").last.map(String.init) ?? "exit code \(status)"
        }
    }

    @discardableResult
    static func run(_ arguments: [String], input: String? = nil, environment: [String: String] = [:],
                    completion: @escaping (Result) -> Void) -> Process {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: arguments[0])
        process.arguments = Array(arguments.dropFirst())
        if !environment.isEmpty {
            process.environment = ProcessInfo.processInfo.environment.merging(environment) { _, new in new }
        }
        let out = Pipe(), err = Pipe(), stdin = Pipe()
        process.standardOutput = out
        process.standardError = err
        process.standardInput = input == nil ? FileHandle.nullDevice : stdin
        DispatchQueue.global(qos: .userInitiated).async {
            do { try process.run() } catch {
                DispatchQueue.main.async { completion(Result(status: -1, output: "", error: error.localizedDescription)) }
                return
            }
            if let input {
                stdin.fileHandleForWriting.write(Data(input.utf8))
                try? stdin.fileHandleForWriting.close()
            }
            // Read both pipes fully before waiting, or a chatty child blocks.
            var errorData = Data()
            let group = DispatchGroup()
            group.enter()
            DispatchQueue.global(qos: .utility).async {
                errorData = err.fileHandleForReading.readDataToEndOfFile()
                group.leave()
            }
            let outputData = out.fileHandleForReading.readDataToEndOfFile()
            group.wait()
            process.waitUntilExit()
            let result = Result(status: process.terminationStatus,
                                output: String(decoding: outputData, as: UTF8.self),
                                error: String(decoding: errorData, as: UTF8.self))
            DispatchQueue.main.async { completion(result) }
        }
        return process
    }
}
