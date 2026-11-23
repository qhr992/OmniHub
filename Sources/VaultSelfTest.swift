import Foundation
import Security

/// Keychain checks of the vault (`OmniHub --vault-selftest`), in a Keychain
/// service of its own — the real vault is never touched. Passwords share one
/// item; items an older version saved one per password are moved into it and
/// deleted; a fresh read returns what was set, changed and removed.
enum VaultSelfTest {
    private static var failures = 0
    private static let sharedAccount = "omnihub-vault"     // as in Vault

    private static func check(_ name: String, _ ok: Bool, _ detail: String = "") {
        if !ok { failures += 1 }
        print("\(ok ? "PASS" : "FAIL")  \(name)\(ok || detail.isEmpty ? "" : "  — \(detail)")")
    }

    static func run() {
        Vault.service = "com.local.omnihub.vault.selftest-\(getpid())"
        removeAll()

        // ---- an older version: one item per password
        for (id, secret) in [("old-a", "pass-a"), ("old-b", "pass-b")] {
            let item: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                       kSecAttrService as String: Vault.service,
                                       kSecAttrAccount as String: id,
                                       kSecValueData as String: Data(secret.utf8)]
            SecItemAdd(item as CFDictionary, nil)
        }
        check("an older version's passwords are still read",
              Vault.secret(for: "old-a") == "pass-a" && Vault.secret(for: "old-b") == "pass-b")
        check("… and now live in one shared item, the old items deleted",
              accounts() == [sharedAccount], "\(accounts())")

        // ---- new, changed, removed
        Vault.set("pass-c", for: "new-c")
        Vault.set("pass-d", for: "new-d")
        Vault.set("pass-c2", for: "new-c")
        Vault.remove("old-b")
        check("new passwords go into the same item", accounts() == [sharedAccount], "\(accounts())")
        Vault.debugForget()
        let fresh = ["old-a", "old-b", "new-c", "new-d"].map { Vault.secret(for: $0) ?? "-" }
        check("read back from the Keychain: kept, changed and removed as set",
              fresh == ["pass-a", "-", "pass-c2", "pass-d"], "\(fresh)")
        check("an empty id has no password and stores nothing",
              Vault.secret(for: "") == nil && !Vault.set("x", for: ""))

        removeAll()
        check("test items removed again", accounts().isEmpty, "\(accounts())")
        print(failures == 0 ? "RESULT: all passed" : "RESULT: \(failures) failed")
        exit(failures == 0 ? 0 : 1)
    }

    private static func accounts() -> [String] { Vault.debugAccounts }

    private static func removeAll() { Vault.debugDeleteAll() }
}
