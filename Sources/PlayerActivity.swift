import Foundation
import IOKit.pwr_mgt

/// Whether a process is sending sound to an output right now. Read from the
/// system power assertions (no permission needed): coreaudiod holds an
/// "audio-out" assertion on behalf of every process that is playing.
enum PlayerActivity {
    static func isProducingAudio(_ pid: pid_t) -> Bool {
        pid > 0 && isProducingAudio(pid, in: assertions())
    }

    /// Pure part (see --dock-selftest).
    static func isProducingAudio(_ pid: pid_t, in assertions: [[String: Any]]) -> Bool {
        assertions.contains { assertion in
            let behalf = (assertion["AssertionOnBehalfOfPID"] as? NSNumber)?.int32Value
            let resources = assertion["ResourcesUsed"] as? [String] ?? []
            return behalf == pid && resources.contains("audio-out")
        }
    }

    static func isRunning(_ pid: pid_t) -> Bool {
        pid > 0 && (kill(pid, 0) == 0 || errno == EPERM)
    }

    private static func assertions() -> [[String: Any]] {
        var raw: Unmanaged<CFDictionary>?
        guard IOPMCopyAssertionsByProcess(&raw) == kIOReturnSuccess,
              let byPID = raw?.takeRetainedValue() as? [NSNumber: [[String: Any]]] else { return [] }
        return byPID.values.flatMap { $0 }
    }
}
