import Foundation
import Network
import Darwin

/// The app binary doubles as three small helpers for the terminal:
///
///   OmniHub --proxy-connect <proxy-id> <host> <port>
///       ssh ProxyCommand: tunnels stdin/stdout to host:port through an
///       HTTP(S) CONNECT or SOCKS5 proxy (with optional credentials).
///   OmniHub --telnet <host> <port> [--proxy <proxy-id>]
///       a minimal Telnet client for a terminal tab.
///   (as SSH_ASKPASS, with OMNIHUB_ASKPASS_SECRET set)
///       prints a password from the vault for ssh.
///
/// None of them starts the app; `runIfRequested` never returns when one runs.
enum NetHelpers {
    static func runIfRequested() {
        let arguments = CommandLine.arguments
        if let index = arguments.firstIndex(of: "--proxy-connect"), index + 3 < arguments.count,
           let port = UInt16(arguments[index + 3]) {
            tunnel(proxyID: arguments[index + 1], host: arguments[index + 2], port: port) { connection, leftover in
                pump(connection, leftover: leftover, telnet: false)
            }
            dispatchMain()
        }
        if let index = arguments.firstIndex(of: "--telnet"), index + 2 < arguments.count,
           let port = UInt16(arguments[index + 2]) {
            var proxyID = ""
            if let proxy = arguments.firstIndex(of: "--proxy"), proxy + 1 < arguments.count { proxyID = arguments[proxy + 1] }
            tunnel(proxyID: proxyID, host: arguments[index + 1], port: port) { connection, leftover in
                enterRawMode()
                pump(connection, leftover: leftover, telnet: true)
            }
            dispatchMain()
        }
        if let secretID = ProcessInfo.processInfo.environment["OMNIHUB_ASKPASS_SECRET"],
           !arguments.contains(where: { $0.hasPrefix("--") }) {
            let prompt = arguments.dropFirst().joined(separator: " ").lowercased()
            // Never answer a host-key question on the user's behalf.
            if prompt.contains("yes/no") { exit(1) }
            // Only an ssh that OmniHub itself started may get a password: any
            // other program could otherwise run this binary with the variable
            // set and read the vault without a Keychain prompt.
            guard askedByOwnSSH() else { fail("refusing: not asked by an ssh started by OmniHub") }
            guard let secret = Vault.secret(for: secretID) else { exit(1) }
            print(secret)
            exit(0)
        }
    }

    /// Parent is /usr/bin/ssh (or sftp), and that one's parent is this same
    /// executable (the running app).
    static func askedByOwnSSH() -> Bool {
        let ssh = getppid()
        guard ["/usr/bin/ssh", "/usr/bin/sftp"].contains(executablePath(of: ssh)),
              let app = parentPID(of: ssh), app > 1 else { return false }
        let mine = (Bundle.main.executablePath.map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path }) ?? ""
        return !mine.isEmpty && executablePath(of: app) == mine
    }

    private static func executablePath(of pid: pid_t) -> String {
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard length > 0 else { return "" }
        return URL(fileURLWithPath: String(cString: buffer)).resolvingSymlinksInPath().path
    }

    private static func parentPID(of pid: pid_t) -> pid_t? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0 else { return nil }
        return info.kp_eproc.e_ppid
    }

    private static func fail(_ message: String) -> Never {
        FileHandle.standardError.write(Data("omnihub: \(message)\n".utf8))
        exit(1)
    }

    // MARK: Tunnel

    /// Connects to host:port — directly, or through the named proxy — and
    /// calls `ready` with the open connection plus any bytes that arrived
    /// together with the proxy's reply.
    private static func tunnel(proxyID: String, host: String, port: UInt16,
                               ready: @escaping (NWConnection, Data) -> Void) {
        let proxy = ConnectionStore.shared.proxy(proxyID)
        if !proxyID.isEmpty, proxy == nil { fail("proxy not found (\(proxyID))") }
        let endpointHost = proxy?.host ?? host
        let endpointPort = proxy.map { UInt16(clamping: $0.port) } ?? port
        guard let nwPort = NWEndpoint.Port(rawValue: endpointPort) else { fail("invalid port") }
        let parameters: NWParameters = proxy?.kind == "https" ? .tls : .tcp
        let connection = NWConnection(host: NWEndpoint.Host(endpointHost), port: nwPort, using: parameters)
        connection.stateUpdateHandler = { state in
            switch state {
            case .ready:
                connection.stateUpdateHandler = { later in
                    if case .failed = later { exit(1) }
                    if case .cancelled = later { exit(0) }
                }
                guard let proxy else { ready(connection, Data()); return }
                let password = Vault.secret(for: proxy.secretID) ?? ""
                if proxy.kind == "socks5" {
                    socks5(connection, host: host, port: port, user: proxy.username, password: password, ready: ready)
                } else {
                    httpConnect(connection, host: host, port: port, user: proxy.username, password: password, ready: ready)
                }
            case .failed(let error): fail("connecting to \(endpointHost):\(endpointPort) failed: \(error.localizedDescription)")
            case .waiting(let error): fail("cannot reach \(endpointHost):\(endpointPort): \(error.localizedDescription)")
            default: break
            }
        }
        connection.start(queue: .main)
    }

    private static func send(_ connection: NWConnection, _ data: Data, then: @escaping () -> Void) {
        connection.send(content: data, completion: .contentProcessed { error in
            if let error { fail("send failed: \(error.localizedDescription)") }
            then()
        })
    }

    /// Reads until at least `count` bytes are buffered.
    private static func read(_ connection: NWConnection, atLeast count: Int, buffer: Data = Data(),
                             then: @escaping (Data) -> Void) {
        if buffer.count >= count { then(buffer); return }
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, done, error in
            var buffer = buffer
            if let data { buffer.append(data) }
            if buffer.count >= count { then(buffer); return }
            if done || error != nil { fail("the proxy closed the connection") }
            read(connection, atLeast: count, buffer: buffer, then: then)
        }
    }

    private static func httpConnect(_ connection: NWConnection, host: String, port: UInt16, user: String,
                                    password: String, ready: @escaping (NWConnection, Data) -> Void) {
        var request = "CONNECT \(host):\(port) HTTP/1.1\r\nHost: \(host):\(port)\r\n"
        if !user.isEmpty {
            let token = Data("\(user):\(password)".utf8).base64EncodedString()
            request += "Proxy-Authorization: Basic \(token)\r\n"
        }
        request += "\r\n"
        send(connection, Data(request.utf8)) {
            func readHeader(_ buffer: Data) {
                if let end = buffer.range(of: Data("\r\n\r\n".utf8)) {
                    let header = String(decoding: buffer[..<end.lowerBound], as: UTF8.self)
                    let status = header.split(separator: "\r\n").first.map(String.init) ?? ""
                    let parts = status.split(separator: " ")
                    guard parts.count >= 2, parts[1] == "200" else { fail("the proxy refused: \(status)") }
                    ready(connection, Data(buffer[end.upperBound...]))
                    return
                }
                if buffer.count > 16384 { fail("the proxy did not answer in HTTP") }
                read(connection, atLeast: buffer.count + 1, buffer: buffer, then: readHeader)
            }
            read(connection, atLeast: 1, then: readHeader)
        }
    }

    private static func socks5(_ connection: NWConnection, host: String, port: UInt16, user: String,
                               password: String, ready: @escaping (NWConnection, Data) -> Void) {
        func request() {
            let name = Array(host.utf8.prefix(255))
            var packet = Data([0x05, 0x01, 0x00, 0x03, UInt8(name.count)])
            packet.append(contentsOf: name)
            packet.append(contentsOf: [UInt8(port >> 8), UInt8(port & 0xFF)])
            send(connection, packet) {
                read(connection, atLeast: 5) { head in
                    guard head[head.startIndex + 1] == 0x00 else {
                        fail("the SOCKS5 proxy cannot reach the target (code \(head[head.startIndex + 1]))")
                    }
                    let addressLength: Int
                    switch head[head.startIndex + 3] {
                    case 0x01: addressLength = 4
                    case 0x04: addressLength = 16
                    default: addressLength = Int(head[head.startIndex + 4]) + 1
                    }
                    let total = 4 + addressLength + 2
                    read(connection, atLeast: total, buffer: head) { reply in
                        ready(connection, Data(reply.dropFirst(total)))
                    }
                }
            }
        }
        let methods: [UInt8] = user.isEmpty ? [0x05, 0x01, 0x00] : [0x05, 0x02, 0x00, 0x02]
        send(connection, Data(methods)) {
            read(connection, atLeast: 2) { choice in
                switch choice[choice.startIndex + 1] {
                case 0x00: request()
                case 0x02:
                    let name = Array(user.utf8.prefix(255)), secret = Array(password.utf8.prefix(255))
                    var packet = Data([0x01, UInt8(name.count)])
                    packet.append(contentsOf: name)
                    packet.append(UInt8(secret.count))
                    packet.append(contentsOf: secret)
                    send(connection, packet) {
                        read(connection, atLeast: 2) { result in
                            guard result[result.startIndex + 1] == 0x00 else { fail("the SOCKS5 proxy rejected the user name or password") }
                            request()
                        }
                    }
                default: fail("the SOCKS5 proxy accepts none of our auth methods")
                }
            }
        }
    }

    // MARK: Pump

    private static var savedTermios: termios?

    /// Telnet servers echo and edit the line themselves.
    private static func enterRawMode() {
        var attributes = termios()
        guard tcgetattr(STDIN_FILENO, &attributes) == 0 else { return }
        savedTermios = attributes
        cfmakeraw(&attributes)
        tcsetattr(STDIN_FILENO, TCSANOW, &attributes)
        atexit {
            if var saved = NetHelpers.savedTermios { tcsetattr(STDIN_FILENO, TCSANOW, &saved) }
        }
    }

    private static func writeOut(_ data: Data) {
        guard !data.isEmpty else { return }
        data.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                let written = Darwin.write(STDOUT_FILENO, raw.baseAddress! + offset, raw.count - offset)
                if written <= 0 { exit(0) }
                offset += written
            }
        }
    }

    private static func pump(_ connection: NWConnection, leftover: Data, telnet: Bool) {
        var filter = TelnetFilter()
        func deliver(_ data: Data) {
            guard telnet else { writeOut(data); return }
            let (text, reply) = filter.process(data)
            writeOut(text)
            if !reply.isEmpty { connection.send(content: reply, completion: .contentProcessed { _ in }) }
        }
        deliver(leftover)

        func receive() {
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, done, error in
                if let data { deliver(data) }
                if done || error != nil {
                    if telnet { writeOut(Data("\r\n[Connection closed]\r\n".utf8)) }
                    exit(0)
                }
                receive()
            }
        }
        receive()

        // stdin → remote, on its own thread so a blocked read never stalls
        // the network side.
        Thread.detachNewThread {
            var buffer = [UInt8](repeating: 0, count: 16384)
            while true {
                let count = Darwin.read(STDIN_FILENO, &buffer, buffer.count)
                if count <= 0 {
                    connection.send(content: nil, contentContext: .finalMessage, isComplete: true,
                                    completion: .contentProcessed { _ in exit(0) })
                    return
                }
                var data = Data(buffer[0..<count])
                if telnet {
                    // A literal 0xFF must be doubled; Return is CR NUL.
                    var escaped = Data()
                    for byte in data {
                        escaped.append(byte)
                        if byte == 0xFF { escaped.append(0xFF) }
                        if byte == 0x0D { escaped.append(0x00) }
                    }
                    data = escaped
                }
                let semaphore = DispatchSemaphore(value: 0)
                connection.send(content: data, completion: .contentProcessed { _ in semaphore.signal() })
                semaphore.wait()
            }
        }
    }
}

/// Strips Telnet option negotiation out of the byte stream and produces the
/// replies: the server may echo and suppress go-ahead, everything else is
/// declined.
struct TelnetFilter {
    private enum State { case data, iac, option(UInt8), subnegotiation, subnegotiationIAC }
    private var state = State.data

    mutating func process(_ input: Data) -> (text: Data, reply: Data) {
        var text = Data(), reply = Data()
        let iac: UInt8 = 255, dont: UInt8 = 254, doIt: UInt8 = 253, wont: UInt8 = 252, will: UInt8 = 251
        for byte in input {
            switch state {
            case .data:
                if byte == iac { state = .iac } else { text.append(byte) }
            case .iac:
                switch byte {
                case iac: text.append(iac); state = .data
                case will, wont, doIt, dont: state = .option(byte)
                case 250: state = .subnegotiation
                default: state = .data
                }
            case .option(let verb):
                let option = byte
                if verb == will {
                    // 1 = echo, 3 = suppress go-ahead.
                    reply.append(contentsOf: [iac, (option == 1 || option == 3) ? doIt : dont, option])
                } else if verb == doIt {
                    reply.append(contentsOf: [iac, option == 3 ? will : wont, option])
                }
                state = .data
            case .subnegotiation:
                if byte == iac { state = .subnegotiationIAC }
            case .subnegotiationIAC:
                state = byte == 240 ? .data : .subnegotiation
            }
        }
        return (text, reply)
    }
}
