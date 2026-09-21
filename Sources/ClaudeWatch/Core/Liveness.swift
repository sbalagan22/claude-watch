import Darwin
import Foundation

/// Whether a process is still alive. Protocol-shaped so tests can drive it
/// without spawning real processes.
protocol LivenessChecking: Sendable {
    func isAlive(_ pid: pid_t) -> Bool
}

/// `kill(pid, 0)` sends no signal; it only performs the existence and
/// permission checks. This is the accurate liveness signal the brief asks for:
/// a session whose process is gone is dead immediately, regardless of how
/// recently it fired an event.
struct ProcessLiveness: LivenessChecking {
    func isAlive(_ pid: pid_t) -> Bool {
        guard pid > 0 else { return false }
        if kill(pid, 0) == 0 { return true }
        // EPERM means the process exists but belongs to another user. For our
        // own Claude Code processes this should not happen, but treating it as
        // alive is the safe direction: we would rather show a stale row briefly
        // than delete a live session's row.
        return errno == EPERM
    }
}

/// Test double.
struct FixedLiveness: LivenessChecking {
    let alive: Set<pid_t>
    func isAlive(_ pid: pid_t) -> Bool { alive.contains(pid) }
}
