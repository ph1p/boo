import Foundation

// MARK: - Process Tree Utilities
//
// Shared utilities for walking the macOS process tree via sysctl.
// Used by BooSocketServer to determine process ancestry.

/// Get the parent PID of a process.
/// Returns -1 if the process doesn't exist or on error.
func processParentPID(of pid: pid_t) -> pid_t {
    var info = kinfo_proc()
    var size = MemoryLayout<kinfo_proc>.size
    var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
    guard sysctl(&mib, 4, &info, &size, nil, 0) == 0 else { return -1 }
    return info.kp_eproc.e_ppid
}

/// Check if a PID is a descendant of another PID by walking the process tree.
/// Walks up to 64 levels to prevent infinite loops in case of cycles.
func processIsDescendant(_ pid: pid_t, of ancestor: pid_t) -> Bool {
    var current = pid
    for _ in 0..<64 {
        if current == ancestor { return true }
        if current <= 1 { return false }
        let parent = processParentPID(of: current)
        if parent == current || parent <= 0 { return false }
        current = parent
    }
    return false
}
