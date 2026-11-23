import Foundation

/// A port forward that already exists on the server, found by looking at it
/// over the tab's connection: ssh clients running there with -L/-R/-D,
/// ports sshd listens on for remote forwards, and forwards written in the
/// server's ~/.ssh/config.
struct ServerTunnel: Equatable {
    enum Source: String { case process, listener, config }

    let source: Source
    /// "L", "R", "D", or "" for a bare listener.
    let kind: String
    let spec: String
    /// pid / user / destination host, as far as known.
    let detail: String

    var summary: String {
        switch source {
        case .process:
            let flag = kind.isEmpty ? "" : "-\(kind) "
            return "ssh \(flag)\(spec)"
        case .listener: return "sshd listening \(spec)"
        case .config: return "\(kind == "D" ? "DynamicForward" : kind == "R" ? "RemoteForward" : "LocalForward") \(spec)"
        }
    }

    var state: String {
        switch source {
        case .process: return L("Running · %@", detail)
        case .listener: return L("Remote forward · %@", detail)
        case .config: return L("Configured · %@", detail)
        }
    }

    /// Listening port of the forward (for matching), if it has one.
    var listenPort: Int? {
        let first = spec.split(separator: " ").first.map(String.init) ?? spec
        if source == .listener { return first.split(separator: ":").last.flatMap { Int($0) } }
        let parts = first.split(separator: ":").map(String.init)
        // [bind:]port[:host:hostport]
        switch parts.count {
        case 1, 3: return Int(parts[0])
        case 2, 4: return Int(parts[1])
        default: return nil
        }
    }
}

enum ServerTunnels {
    /// Shell script run on the server. Every section is optional: whatever
    /// the system has (ps, ss / lsof / netstat) answers.
    static let probeScript = """
    echo '@@PS'
    ps -axww -o pid= -o user= -o command= 2>/dev/null || ps -eww -o pid= -o user= -o args= 2>/dev/null
    echo '@@LISTEN'
    if command -v ss >/dev/null 2>&1; then ss -Htlnp 2>/dev/null
    elif command -v lsof >/dev/null 2>&1; then lsof -nP -iTCP -sTCP:LISTEN 2>/dev/null
    else netstat -tlnp 2>/dev/null; fi
    echo '@@CONFIG'
    cat ~/.ssh/config 2>/dev/null
    echo '@@END'
    """

    /// Looks at the server behind `target` (over its live connection).
    static func load(_ target: RemoteTarget, completion: @escaping (Result<[ServerTunnel], Error>) -> Void) {
        let arguments = target.muxArguments([target.host, "sh", "-s"])
        Subprocess.run(arguments, input: probeScript) { result in
            guard result.ok || result.output.contains("@@END") else {
                completion(.failure(NSError(domain: "OmniHub", code: Int(result.status),
                                            userInfo: [NSLocalizedDescriptionKey: result.message])))
                return
            }
            completion(.success(parse(result.output, sshPort: target.port)))
        }
    }

    // MARK: Parsing

    static func parse(_ output: String, sshPort: Int = 22) -> [ServerTunnel] {
        var sections: [String: [String]] = [:]
        var current = ""
        for raw in output.components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("@@") { current = String(line.dropFirst(2)); continue }
            if !line.isEmpty { sections[current, default: []].append(line) }
        }
        var result = (sections["PS"] ?? []).flatMap(processTunnels)
        var seen = Set<String>()
        for listener in (sections["LISTEN"] ?? []).compactMap({ listener($0, sshPort: sshPort) })
        where seen.insert(listener.spec).inserted {
            result.append(listener)
        }
        result += configTunnels(sections["CONFIG"] ?? [])
        return result
    }

    /// Options of ssh(1) that take a value.
    private static let valued = Set("BbcDEeFIiJLlmOoPpQRSWw".map { String($0) })

    /// "1234 root ssh -N -L 8080:db:5432 user@bastion" → its forwards.
    static func processTunnels(_ line: String) -> [ServerTunnel] {
        let fields = line.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true).map(String.init)
        guard fields.count == 3, let pid = Int(fields[0]) else { return [] }
        let user = fields[1]
        let tokens = RemoteTarget.tokenize(fields[2])
        guard let program = tokens.first.map({ ($0 as NSString).lastPathComponent }),
              program == "ssh" || program == "autossh" else { return [] }

        // autossh's -M takes a port; ssh's -M (master mode) takes nothing.
        let takesValue = program == "autossh" ? valued.union(["M"]) : valued
        var forwards: [(String, String)] = []
        var destination = ""
        var index = 1
        while index < tokens.count {
            let token = tokens[index]
            index += 1
            guard token.hasPrefix("-"), token.count >= 2 else {
                if destination.isEmpty { destination = token }
                continue
            }
            // Flags may be bundled: "-fNL" + value, "-L8080:…".
            var flags = Array(token.dropFirst())
            while !flags.isEmpty {
                let flag = String(flags.removeFirst())
                guard takesValue.contains(flag) else { continue }
                var value = String(flags)
                flags = []
                if value.isEmpty, index < tokens.count { value = tokens[index]; index += 1 }
                if ["L", "R", "D"].contains(flag) { forwards.append((flag, value)) }
                if flag == "o", let found = optionForward(value) {
                    let kind = found.0
                    var spec = found.1
                    // ps prints "-o LocalForward=9000 db:5432" with the
                    // option's own space: the target is the next word.
                    if kind != "D", !spec.contains(" "), spec.split(separator: ":").count <= 2,
                       index < tokens.count, tokens[index].contains(":"), !tokens[index].hasPrefix("-") {
                        spec += " " + tokens[index]
                        index += 1
                    }
                    forwards.append((kind, spec))
                }
            }
        }
        let detail = "pid \(pid), \(user)" + (destination.isEmpty ? "" : " → \(destination)")
        return forwards.map { ServerTunnel(source: .process, kind: $0.0, spec: $0.1, detail: detail) }
    }

    /// "-o LocalForward=8080 db:5432".
    private static func optionForward(_ value: String) -> (String, String)? {
        let parts = value.split(maxSplits: 1, whereSeparator: { $0 == "=" || $0 == " " }).map(String.init)
        guard parts.count == 2 else { return nil }
        switch parts[0].lowercased() {
        case "localforward": return ("L", parts[1].trimmingCharacters(in: .whitespaces))
        case "remoteforward": return ("R", parts[1].trimmingCharacters(in: .whitespaces))
        case "dynamicforward": return ("D", parts[1].trimmingCharacters(in: .whitespaces))
        default: return nil
        }
    }

    /// A listening socket owned by sshd (ss / lsof / netstat line).
    static func listener(_ line: String, sshPort: Int) -> ServerTunnel? {
        guard line.contains("sshd") else { return nil }
        let fields = line.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
        var address: String?
        var pid = ""
        if line.contains("users:((") {
            // ss: LISTEN 0 128 127.0.0.1:8080 0.0.0.0:* users:(("sshd",pid=12,fd=9))
            address = fields.first { $0.contains(":") && !$0.hasPrefix("users:") && !$0.hasSuffix(":*") && $0 != "*:*" }
            if let range = line.range(of: "pid=") {
                pid = String(line[range.upperBound...].prefix { $0.isNumber })
            }
        } else if line.hasSuffix("(LISTEN)") {
            // lsof: sshd 12 user 9u IPv4 0x… 0t0 TCP 127.0.0.1:8080 (LISTEN)
            address = fields.dropLast().last
            if fields.count > 1 { pid = fields[1] }
        } else if fields.first?.hasPrefix("tcp") == true, fields.count >= 4 {
            // netstat: tcp 0 0 127.0.0.1:8080 0.0.0.0:* LISTEN 12/sshd: user
            address = fields[3]
            pid = fields.first { $0.hasSuffix("/sshd") || $0.contains("/sshd") }?
                .split(separator: "/").first.map(String.init) ?? ""
        }
        guard let address, let port = address.split(separator: ":").last.flatMap({ Int($0) }),
              port != sshPort else { return nil }
        return ServerTunnel(source: .listener, kind: "", spec: address,
                            detail: pid.isEmpty ? "sshd" : "sshd pid \(pid)")
    }

    /// LocalForward / RemoteForward / DynamicForward lines of ~/.ssh/config.
    static func configTunnels(_ lines: [String]) -> [ServerTunnel] {
        var host = ""
        var result: [ServerTunnel] = []
        for line in lines where !line.hasPrefix("#") {
            let parts = line.split(maxSplits: 1, whereSeparator: { $0 == " " || $0 == "\t" || $0 == "=" }).map(String.init)
            guard parts.count == 2 else { continue }
            let value = parts[1].trimmingCharacters(in: .whitespaces)
            switch parts[0].lowercased() {
            case "host": host = value
            case "localforward": result.append(ServerTunnel(source: .config, kind: "L", spec: value, detail: "Host \(host)"))
            case "remoteforward": result.append(ServerTunnel(source: .config, kind: "R", spec: value, detail: "Host \(host)"))
            case "dynamicforward": result.append(ServerTunnel(source: .config, kind: "D", spec: value, detail: "Host \(host)"))
            default: break
            }
        }
        return result
    }
}
