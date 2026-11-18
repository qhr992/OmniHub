import AppKit

/// End-to-end check of the terminal's remote features against throw-away
/// local servers (started by test-remote.sh): vault, profiles, automation,
/// SFTP, transfers, port forwards, proxies, Telnet, reconnect.
/// Runs without showing a window; writes report.txt and PNGs to `directory`.
enum RemoteSelfTest {
    private static var report: [String] = []
    private static var failures = 0
    private static var directory = URL(fileURLWithPath: "/tmp")

    private static func env(_ name: String) -> String { ProcessInfo.processInfo.environment[name] ?? "" }

    private static func check(_ name: String, _ ok: Bool, _ detail: String = "") {
        if !ok { failures += 1 }
        report.append("\(ok ? "PASS" : "FAIL")  \(name)\(detail.isEmpty ? "" : "  — \(detail)")")
    }

    private static func snapshot(_ name: String) {
        FloatingDockPanel.snapshot(to: directory.appendingPathComponent(name))
    }

    /// Polls `condition` until it holds or `timeout` passes.
    private static func wait(_ timeout: TimeInterval, until condition: @escaping () -> Bool, then: @escaping (Bool) -> Void) {
        let deadline = Date().addingTimeInterval(timeout)
        func poll() {
            if condition() { then(true); return }
            if Date() > deadline { then(false); return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: poll)
        }
        poll()
    }

    private static func shell(_ command: String, then: @escaping (String) -> Void) {
        Subprocess.run(["/bin/sh", "-c", command]) { then($0.output.trimmingCharacters(in: .whitespacesAndNewlines)) }
    }

    private static func finish() -> Never {
        // Leave nothing behind: test profiles, proxies and passwords.
        let store = ConnectionStore.shared
        store.profiles.forEach { store.removeProfile($0.id) }
        store.proxies.forEach { store.removeProxy($0.id) }
        store.vault.forEach { store.removeVaultEntry($0.id) }
        TransferCenter.shared.clearFinished()
        FloatingDockPanel.terminateShells()
        report.append(failures == 0 ? "RESULT: all passed" : "RESULT: \(failures) failed")
        let text = report.joined(separator: "\n")
        try? text.write(to: directory.appendingPathComponent("report.txt"), atomically: true, encoding: .utf8)
        print(text)
        exit(failures == 0 ? 0 : 1)
    }

    static func run(into directory: URL) {
        self.directory = directory
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        CalendarSource.allowPrompt = false
        FloatingDockPanel.headless = true
        // Whatever goes wrong, the run ends.
        DispatchQueue.main.asyncAfter(deadline: .now() + 150) {
            check("finished in time", false, "timed out")
            finish()
        }

        let sshPort = Int(env("OMNIHUB_TEST_SSH_PORT")) ?? 0
        let user = NSUserName()
        let store = ConnectionStore.shared

        // ---- vault
        var keyPass = VaultEntry(); keyPass.name = "测试私钥口令"; keyPass.account = NSUserName()
        store.upsert(keyPass, secret: env("OMNIHUB_TEST_KEY_PASSPHRASE"))
        var sudoPass = VaultEntry(); sudoPass.name = "测试二次密码"; sudoPass.account = "root"
        store.upsert(sudoPass, secret: "s3cret-9chars")
        var proxyPass = VaultEntry(); proxyPass.name = "测试代理密码"
        store.upsert(proxyPass, secret: env("OMNIHUB_TEST_PROXY_PASSWORD"))
        check("vault stores and returns a password", Vault.secret(for: sudoPass.id) == "s3cret-9chars")
        check("connections.json holds no password",
              !((try? String(contentsOf: Store.url("connections.json"), encoding: .utf8)) ?? "").contains("s3cret"))

        // ---- proxies
        var http = ProxyConfig(); http.name = "测试 HTTP 代理"; http.kind = "http"; http.host = "127.0.0.1"
        http.port = Int(env("OMNIHUB_TEST_HTTP_PROXY_PORT")) ?? 0
        http.username = "proxyuser"; http.secretID = proxyPass.id
        store.upsert(http)
        var socks = ProxyConfig(); socks.name = "测试 SOCKS5 代理"; socks.kind = "socks5"; socks.host = "127.0.0.1"
        socks.port = 18082
        store.upsert(socks)

        // ---- profile: key with a passphrase from the vault + automation
        var main = ConnectionProfile()
        main.name = "测试服务器"; main.group = "测试组"; main.host = "127.0.0.1"; main.port = sshPort; main.user = user
        main.keyPath = env("OMNIHUB_TEST_KEY"); main.secretID = keyPass.id
        // The user's case: a command that asks for a password after a moment
        // (like `security unlock-keychain`), answered from the vault; then a
        // (yes/no) question answered with plain text; then a plain command.
        main.steps = [
            AutoStep(send: "sleep 1; read -s \"?password to unlock keychain: \" p; echo; echo UNLOCK-LEN-${#p}", secretID: sudoPass.id),
            AutoStep(send: "read \"?continue? (yes/no) \" a; echo GOT-$a", expect: "(yes/no)", reply: "yes"),
            AutoStep(send: "echo LAST-$((6*7))")
        ]
        store.upsert(main)

        _ = FloatingDockPanel.debugRender(to: directory.appendingPathComponent("remote-0-terminal.png"),
                                          x: 0.5, y: 1, expanded: true, page: "terminal")
        let terminal = FloatingDockPanel.terminal

        // The picker lists the profile under its group and filters as you type.
        terminal.debugToggle("connections")
        snapshot("remote-1-picker.png")
        terminal.debugToggle("connections")
        let picker = ConnectionPickerView()
        check("picker lists the profile under its group", picker.debugRows.first == "[测试组]" && picker.debugRows.count == 2,
              "\(picker.debugRows)")
        picker.debugType("otherhost")
        // A word that matches no profile is offered as a host to connect to.
        check("picker filter hides non-matching profiles", picker.debugRows == ["→ ssh otherhost"], "\(picker.debugRows)")
        picker.debugType("测试服")
        check("picker filter keeps matching profiles", picker.debugRows.count == 2, "\(picker.debugRows)")
        picker.debugType("ssh -p 2200 root@10.1.2.3")
        check("picker offers a typed ssh command", picker.debugRows == ["→ ssh -p 2200 root@10.1.2.3"], "\(picker.debugRows)")
        let parsed = RemoteTarget(commandLine: "ssh -p 2200 -i ~/.ssh/k root@10.1.2.3 uptime")
        check("ssh command line is parsed", parsed?.display == "root@10.1.2.3:2200", parsed?.display ?? "nil")
        check("user@host:port shorthand is parsed", RemoteTarget(commandLine: "bob@example.com:2222")?.display == "bob@example.com:2222")
        check("telnet command line is parsed", RemoteTarget(commandLine: "telnet 10.0.0.9 2323")?.display.hasSuffix("@10.0.0.9:2323") == true)

        terminal.debugConnect(profile: main)
        guard let session = terminal.activeSession else { check("tab opened", false); finish() }
        wait(25, until: { session.link == .connected }) { connected in
            check("ssh login with key passphrase from the vault (askpass)", connected, terminal.debugTabs)
            guard connected else { report.append(terminal.debugText); finish() }
            check("connection info shows user@host:port", terminal.debugTabs.contains("info = \"\(user)@127.0.0.1:\(sshPort)\""),
                  terminal.debugTabs)
            wait(25, until: {
                let text = terminal.debugText
                return text.contains("UNLOCK-LEN-13") && text.contains("GOT-yes") && text.contains("LAST-42")
            }) { ok in
                check("automation: command → waits for its password prompt → vault password; (yes/no) reply; plain command", ok,
                      String(terminal.debugText.suffix(420)).replacingOccurrences(of: "\n", with: " ⏎ "))
                check("the vault password is not echoed on screen", !terminal.debugText.contains("s3cret"))
                snapshot("remote-2-connected.png")
                sftp(terminal, session, http: http, socks: socks, user: user, sshPort: sshPort)
            }
        }
    }

    // MARK: SFTP + transfers

    private static func sftp(_ terminal: TerminalPane, _ session: TerminalSession, http: ProxyConfig, socks: ProxyConfig,
                             user: String, sshPort: Int) {
        let remote = env("OMNIHUB_TEST_REMOTE_DIR")
        let downloads = directory.appendingPathComponent("downloads", isDirectory: true)
        terminal.debugToggle("sftp")
        guard let browser = terminal.debugSFTP else { check("sftp drawer opens", false); finish() }
        wait(15, until: { browser.path != "." }) { ok in
            check("sftp opens in the login directory", ok && browser.path == NSHomeDirectory(), browser.debugState)
            browser.load(remote) {
                let names = browser.debugEntries.map { $0.isDirectory ? $0.name + "/" : $0.name }
                check("sftp lists a folder, folders first", names == ["sub folder/", "big.bin", "hello world.txt"], "\(names)")
                snapshot("remote-3-sftp.png")
                browser.createFolder(named: "made by omnihub") {
                    check("sftp creates a folder", FileManager.default.fileExists(atPath: remote + "/made by omnihub"),
                          browser.debugState)
                    // Upload.
                    let local = directory.appendingPathComponent("upload me.txt")
                    try? "uploaded".write(to: local, atomically: true, encoding: .utf8)
                    let upload = TransferCenter.shared.upload(session.target!, local: local, remoteDirectory: remote)
                    wait(15, until: { upload.state != .running }) { _ in
                        check("sftp uploads a file",
                              (try? String(contentsOfFile: remote + "/upload me.txt", encoding: .utf8)) == "uploaded",
                              "\(upload.state) \(upload.message)")
                        // Download a large file and a folder; watch the bar move.
                        guard let big = browser.debugEntries.first(where: { $0.name == "big.bin" }),
                              let folder = browser.debugEntries.first(where: { $0.name == "sub folder" }) else {
                            check("entries to download exist", false); finish()
                        }
                        let fileItem = browser.download(big, to: downloads)!
                        let folderItem = browser.download(folder, to: downloads)!
                        var sawPartial = false
                        var midRow = ""
                        terminal.debugToggle("transfers")
                        wait(40, until: {
                            if fileItem.state == .running, let fraction = fileItem.fraction, fraction > 0.02, fraction < 0.98, !sawPartial {
                                sawPartial = true
                                midRow = TransferRow(item: fileItem).debugText
                                snapshot("remote-4-downloading.png")
                            }
                            return fileItem.state != .running && folderItem.state != .running
                        }) { _ in
                            let got = TransferCenter.size(of: downloads.appendingPathComponent("big.bin").path)
                            check("download of a file completes", fileItem.state == .done && got == big.size,
                                  "\(fileItem.state) \(fileItem.message) \(got)/\(big.size)")
                            check("progress bar showed a partial download", sawPartial, midRow)
                            let inner = downloads.appendingPathComponent("sub folder/inner.txt").path
                            check("download of a folder completes",
                                  folderItem.state == .done && (try? String(contentsOfFile: inner, encoding: .utf8)) == "inner\n",
                                  "\(folderItem.state) \(folderItem.message)")
                            snapshot("remote-5-downloads-done.png")
                            terminal.debugToggle("transfers")
                            terminal.debugToggle("sftp")
                            forwards(terminal, session, http: http, socks: socks, user: user, sshPort: sshPort)
                        }
                    }
                }
            }
        }
    }

    // MARK: Port forwards

    private static func forwards(_ terminal: TerminalPane, _ session: TerminalSession, http: ProxyConfig, socks: ProxyConfig,
                                 user: String, sshPort: Int) {
        let webPort = Int(env("OMNIHUB_TEST_WEB_PORT")) ?? 0
        session.addForward(kind: "L", bind: "", listenPort: 18081, targetHost: "127.0.0.1", targetPort: webPort, proxyID: "")
        session.addForward(kind: "D", bind: "", listenPort: 18082, targetHost: "", targetPort: 0, proxyID: "")
        // One more, carried by its own connection through the HTTP proxy.
        session.addForward(kind: "L", bind: "", listenPort: 18083, targetHost: "127.0.0.1", targetPort: webPort, proxyID: http.id)
        wait(15, until: { session.forwards.allSatisfy { $0.active || $0.state.hasPrefix("Failed") || $0.state.hasPrefix("Stopped") } }) { _ in
            check("forwards are established", session.forwards.allSatisfy(\.active), "\(session.forwards.map { "\($0.summary): \($0.state)" })")
            terminal.debugToggle("forwards")
            snapshot("remote-6-forwards.png")
            terminal.debugToggle("forwards")
            shell("curl -s -m 5 http://127.0.0.1:18081/hello%20world.txt; echo; curl -s -m 5 http://127.0.0.1:18083/hello%20world.txt; echo; "
                  + "curl -s -m 5 --socks5-hostname 127.0.0.1:18082 http://127.0.0.1:\(webPort)/hello%20world.txt") { output in
                check("local forward, forward through a proxy, and SOCKS forward all carry traffic",
                      output == "hello\n\nhello\n\nhello".replacingOccurrences(of: "\n\n", with: "\n") || output.components(separatedBy: "hello").count == 4,
                      output.replacingOccurrences(of: "\n", with: " ⏎ "))
                let first = session.forwards[0].id
                session.removeForward(first)
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                    shell("curl -s -m 3 -o /dev/null -w '%{http_code}' http://127.0.0.1:18081/ ; true") { code in
                        check("a removed forward stops listening", code == "000", "http \(code)")
                        serverTunnels(terminal, session, webPort: webPort, user: user, sshPort: sshPort) {
                            proxies(terminal, session, http: http, socks: socks, user: user, sshPort: sshPort)
                        }
                    }
                }
            }
        }
    }

    /// Tunnels opened on the server by someone else (here: a separate ssh
    /// with -L and one with -R) show up in the Port Forwarding drop-down.
    private static func serverTunnels(_ terminal: TerminalPane, _ session: TerminalSession, webPort: Int,
                                      user: String, sshPort: Int, then: @escaping () -> Void) {
        func tunnel(_ spec: [String]) -> Process {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
            process.arguments = ["-N", "-o", "BatchMode=yes", "-o", "StrictHostKeyChecking=accept-new",
                                 "-p", "\(sshPort)", "-i", env("OMNIHUB_TEST_PLAIN_KEY")] + spec + ["\(user)@127.0.0.1"]
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try? process.run()
            return process
        }
        let local = tunnel(["-L", "18091:127.0.0.1:\(webPort)"])
        let remote = tunnel(["-R", "127.0.0.1:18092:127.0.0.1:\(webPort)"])
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
            let view = ForwardsView(session: session)
            wait(15, until: { !view.serverStatus.hasPrefix("Looking") }) { _ in
                let rows = view.debugServerRows
                check("port forwarding lists the server's existing ssh -L tunnel",
                      rows.contains { $0.hasPrefix("ssh -L 18091:127.0.0.1:\(webPort) | Running") }, "\(rows) \(view.serverStatus)")
                check("port forwarding lists the server's sshd listener of a remote forward",
                      rows.contains { $0.hasPrefix("sshd listening 127.0.0.1:18092") }, "\(rows)")
                check("the server's own ssh port is not listed as a forward",
                      !rows.contains { $0.contains(":\(sshPort) |") }, "\(rows)")
                terminal.debugToggle("forwards")
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                    snapshot("remote-6b-server-forwards.png")
                    terminal.debugToggle("forwards")
                    local.terminate()
                    remote.terminate()
                    then()
                }
            }
        }
    }

    // MARK: Proxies, Telnet, reconnect

    private static func proxies(_ terminal: TerminalPane, _ first: TerminalSession, http: ProxyConfig, socks: ProxyConfig,
                                user: String, sshPort: Int) {
        var viaSocks = ConnectionProfile()
        viaSocks.name = "经 SOCKS5"; viaSocks.host = "127.0.0.1"; viaSocks.port = sshPort; viaSocks.user = user
        viaSocks.keyPath = env("OMNIHUB_TEST_PLAIN_KEY"); viaSocks.proxyID = socks.id
        viaSocks.steps = [AutoStep(send: "echo VIA-$((40+2))-SOCKS")]
        var viaHTTP = viaSocks
        viaHTTP.id = UUID().uuidString; viaHTTP.name = "经 HTTP 代理"; viaHTTP.proxyID = http.id
        viaHTTP.steps = [AutoStep(send: "echo VIA-$((40+2))-HTTP")]
        ConnectionStore.shared.upsert(viaSocks)
        ConnectionStore.shared.upsert(viaHTTP)

        terminal.debugConnect(profile: viaSocks)
        wait(25, until: { terminal.debugText.contains("VIA-42-SOCKS") }) { ok in
            check("ssh through a SOCKS5 proxy", ok, String(terminal.debugText.suffix(200)).replacingOccurrences(of: "\n", with: " ⏎ "))
            terminal.debugConnect(profile: viaHTTP)
            wait(25, until: { terminal.debugText.contains("VIA-42-HTTP") }) { ok in
                check("ssh through an HTTP proxy with user name and password", ok,
                      String(terminal.debugText.suffix(200)).replacingOccurrences(of: "\n", with: " ⏎ "))
                shell("cat '\(env("OMNIHUB_TEST_PROXY_LOG"))'") { log in
                    check("the HTTP proxy saw the credentials", log.contains("auth-ok"), log.replacingOccurrences(of: "\n", with: " ⏎ "))
                    telnet(terminal, first, user: user, sshPort: sshPort)
                }
            }
        }
    }

    private static func telnet(_ terminal: TerminalPane, _ first: TerminalSession, user: String, sshPort: Int) {
        var profile = ConnectionProfile()
        profile.name = "测试 Telnet"; profile.kind = "telnet"; profile.host = "127.0.0.1"
        profile.port = Int(env("OMNIHUB_TEST_TELNET_PORT")) ?? 0
        let password = ConnectionStore.shared.vault.first { $0.name == "测试二次密码" }.flatMap { Vault.secret(for: $0.id) } ?? ""
        profile.user = "bob"
        ConnectionStore.shared.upsert(profile)
        ConnectionStore.shared.setOwnPassword(password, for: profile.id)
        profile = ConnectionStore.shared.profile(profile.id) ?? profile
        terminal.debugConnect(profile: profile)
        wait(20, until: { terminal.debugText.contains("WELCOME bob 13") }) { ok in
            check("telnet: option negotiation, login and password typed automatically", ok,
                  terminal.debugText.replacingOccurrences(of: "\n", with: " ⏎ "))
            check("telnet tab shows its address", terminal.debugTabs.contains("bob@127.0.0.1:\(profile.port)  (Telnet)"), terminal.debugTabs)
            snapshot("remote-7-telnet.png")

            // Quick connect with a typed command (key without passphrase).
            let typed = "ssh -p \(sshPort) -i \(env("OMNIHUB_TEST_PLAIN_KEY")) -o StrictHostKeyChecking=accept-new \(user)@127.0.0.1"
            check("typed ssh command opens a tab", terminal.debugConnect(typed))
            guard let quick = terminal.activeSession else { finish() }
            wait(20, until: { quick.link == .connected }) { ok in
                check("typed ssh command connects", ok, terminal.debugTabs)
                // Reconnect.
                quick.reconnect()
                check("reconnect drops the connection first", quick.link == .connecting)
                wait(20, until: { quick.link == .connected }) { ok in
                    check("reconnect logs in again", ok && terminal.debugText.contains("Reconnecting"), terminal.debugTabs)
                    quick.write(Data("exit\n".utf8))
                    wait(10, until: { quick.link == .closed }) { ok in
                        check("a closed remote tab stays and says so", ok && terminal.debugText.contains("Connection closed"), terminal.debugTabs)
                        settings(terminal)
                    }
                }
            }
        }
    }

    // MARK: Settings panel

    private static func settings(_ terminal: TerminalPane) {
        terminal.openSettings(tab: 0)
        guard let panel = terminal.debugSettings else { check("settings panel opens", false); finish() }
        snapshot("remote-8-settings-profiles.png")
        // Test Connection on the selected profile, and on one that cannot work.
        guard let editor = panel.debugEditor as? ProfilesEditor else { finish() }
        editor.refresh(select: ConnectionStore.shared.profiles.first { $0.name == "测试服务器" }?.id)
        editor.debugTest()
        wait(20, until: { !editor.debugTestResult.isEmpty && editor.debugTestResult != "Testing…" }) { _ in
            check("Test Connection succeeds for a working profile", editor.debugTestResult.hasPrefix("Connected"), editor.debugTestResult)
            snapshot("remote-8b-test-connection.png")
            var broken = ConnectionProfile()
            broken.name = "坏的"; broken.host = "127.0.0.1"; broken.port = 1; broken.user = "nobody"
            ConnectionStore.shared.upsert(broken)
            editor.refresh(select: broken.id)
            editor.debugTest()
            wait(20, until: { !editor.debugTestResult.isEmpty && editor.debugTestResult != "Testing…" }) { _ in
                check("Test Connection reports a failure", editor.debugTestResult.hasPrefix("Failed"), editor.debugTestResult)
                ConnectionStore.shared.removeProfile(broken.id)
                editor.refresh()
                settingsRest(terminal, panel)
            }
        }
    }

    private static func settingsRest(_ terminal: TerminalPane, _ panel: TerminalSettingsView) {
        let before = ConnectionStore.shared.profiles.count
        panel.debugEditor.debugClone()
        check("clone adds a copy of the profile", ConnectionStore.shared.profiles.count == before + 1
              && ConnectionStore.shared.profiles.contains { $0.name.hasSuffix(" copy") }, "\(panel.debugEditor.debugList)")
        panel.debugEditor.debugDelete()
        check("delete removes it again", ConnectionStore.shared.profiles.count == before)
        panel.debugEditor.debugAdd()
        check("add creates a new profile", ConnectionStore.shared.profiles.count == before + 1)
        check("profiles are listed under their group", panel.debugEditor.debugList.contains("[测试组]") && panel.debugEditor.debugList.contains("[Ungrouped]"),
              "\(panel.debugEditor.debugList)")
        panel.select(tab: 1)
        snapshot("remote-9-settings-vault.png")
        panel.debugEditor.debugAdd()
        (panel.debugEditor as? VaultEditor)?.debugSet(name: "新增的密码", password: "typed-in-form")
        let added = ConnectionStore.shared.vault.first { $0.name == "新增的密码" }
        check("vault form saves a password to the keychain", added.flatMap { Vault.secret(for: $0.id) } == "typed-in-form")
        panel.select(tab: 2)
        snapshot("remote-10-settings-proxies.png")
        check("proxies are listed", panel.debugEditor.debugList.count == 2, "\(panel.debugEditor.debugList)")
        ownPassword(terminal, panel)
    }

    /// Credential: Username & Password typed in the form (kept in the
    /// Keychain for this connection), or a Vault entry that brings its own
    /// Username (none = no account name is sent).
    private static func ownPassword(_ terminal: TerminalPane, _ panel: TerminalSettingsView) {
        panel.select(tab: 0)
        guard let editor = panel.debugEditor as? ProfilesEditor else { finish() }
        editor.debugAdd()
        guard let id = editor.selectedID, let created = ConnectionStore.shared.profile(id) else {
            check("a profile to set a password on", false); finish()
        }
        check("a new connection starts on Username & Password with both fields shown",
              editor.debugCredentialChoice == "Username & Password" && editor.debugPasswordFieldsShown, editor.debugCredentialChoice)
        let columns = panel.debugEditor.debugColumns
        check("connections: list and details are 2 : 5", abs(columns.list / columns.form - 0.4) < 0.03,
              "list=\(Int(columns.list)) form=\(Int(columns.form))")
        editor.debugCredential(user: "alice", password: "own-pass-7")
        let saved = ConnectionStore.shared.profile(id)
        check("the typed password is kept in the keychain for this connection",
              Vault.secret(for: created.ownSecretID) == "own-pass-7" && saved?.secretID == created.ownSecretID
                && saved?.loginUser == "alice",
              "secretID=\(saved?.secretID ?? "-") user=\(saved?.loginUser ?? "-")")
        check("connections.json holds no typed password",
              !((try? String(contentsOf: Store.url("connections.json"), encoding: .utf8)) ?? "").contains("own-pass-7"))
        snapshot("remote-11-own-password.png")
        editor.debugCredential(user: "alice", password: "")
        check("clearing the password means ask when connecting",
              ConnectionStore.shared.profile(id)?.secretID == "" && Vault.secret(for: created.ownSecretID) == nil)
        let withUser = ConnectionStore.shared.vault.first { $0.name == "测试二次密码" }
        if let withUser {
            editor.debugCredential(vaultID: withUser.id)
            let viaVault = ConnectionStore.shared.profile(id)
            check("a Vault credential hides the fields and logs in as its Username",
                  !editor.debugPasswordFieldsShown && viaVault?.loginUser == withUser.account
                    && viaVault?.destination.hasPrefix("\(withUser.account)@") == true,
                  "note=\(editor.debugVaultNote) dest=\(viaVault?.destination ?? "-")")
        }
        var bare = VaultEntry(); bare.name = "无用户名"
        ConnectionStore.shared.upsert(bare, secret: "pw-only")
        editor.refresh()
        editor.debugCredential(vaultID: bare.id)
        let noUser = ConnectionStore.shared.profile(id)
        check("a Vault entry without a Username sends no account name",
              noUser?.loginUser == "" && noUser?.destination == noUser?.host && editor.debugVaultNote.hasPrefix("No username"),
              "dest=\(noUser?.destination ?? "-") note=\(editor.debugVaultNote)")
        snapshot("remote-11b-vault-credential.png")
        ConnectionStore.shared.removeVaultEntry(bare.id)
        editor.debugCredential(user: "alice", password: "own-pass-7")
        let copy = ConnectionStore.shared.clone(id)
        check("a duplicate keeps its own copy of the password",
              copy.map { $0.secretID == $0.ownSecretID && Vault.secret(for: $0.ownSecretID) == "own-pass-7" } == true)
        copy.map { ConnectionStore.shared.removeProfile($0.id) }
        ConnectionStore.shared.removeProfile(id)
        check("deleting the connection deletes its password",
              Vault.secret(for: created.ownSecretID) == nil && copy.map { Vault.secret(for: $0.ownSecretID) == nil } == true)
        editor.refresh()

        // Closing the card takes the settings panel with it.
        FloatingDockPanel.closeCard()
        check("terminal settings close together with the card", terminal.debugSettings == nil)
        _ = FloatingDockPanel.debugRender(to: directory.appendingPathComponent("remote-12-terminal-reopened.png"),
                                          x: 0.5, y: 1, expanded: true, page: "terminal")
        check("reopening the terminal shows the terminal, not its settings", terminal.debugSettings == nil)
        finish()
    }
}
