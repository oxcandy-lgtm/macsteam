// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import Darwin.sys.proc

// MARK: - Process identity types

/// Snapshot of a running process identity for ownership verification.
struct ProcessIdentitySnapshot: Sendable, Equatable {
    let pid: Int32
    let canonicalExecutablePath: String
    let startTimeSeconds: UInt64
    let startTimeMicroseconds: UInt64
}

protocol ProcessIdentityProviding: Sendable {
    func identity(forPID pid: Int32) throws -> ProcessIdentitySnapshot
}

enum ProcessIdentityError: Error, Sendable {
    case cannotResolveExecutablePath
    case cannotResolveStartTime
}

// MARK: - Real identity provider (macOS proc_info)

struct RealProcessIdentityProvider: ProcessIdentityProviding {
    func identity(forPID pid: Int32) throws -> ProcessIdentitySnapshot {
        // Get executable path via proc_pidpath
        var buf = [UInt8](repeating: 0, count: 4096)
        let pathLen = proc_pidpath(pid, &buf, UInt32(buf.count))
        guard pathLen > 0 else {
            throw ProcessIdentityError.cannotResolveExecutablePath
        }
        var rawPath = String(cString: buf)
        // Canonicalize via realpath
        if let resolved = rawPath.withCString({ cstr -> String? in
            guard let rp = realpath(cstr, nil) else { return nil }
            let s = String(cString: rp)
            free(rp)
            return s
        }) {
            rawPath = resolved
        }

        // Get process start time via proc_pidinfo
        var info = proc_bsdinfo()
        let infoSize = MemoryLayout<proc_bsdinfo>.size
        let ret = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(infoSize))
        guard ret >= infoSize else {
            throw ProcessIdentityError.cannotResolveStartTime
        }

        return ProcessIdentitySnapshot(
            pid: pid,
            canonicalExecutablePath: rawPath,
            startTimeSeconds: UInt64(info.pbi_start_tvsec),
            startTimeMicroseconds: UInt64(info.pbi_start_tvusec)
        )
    }
}

// MARK: - Process signal sending

protocol ProcessSignalSending: Sendable {
    func sendSignal(_ signal: Int32, to pid: Int32) -> Bool
}

struct DarwinProcessSignalSender: ProcessSignalSending {
    func sendSignal(_ signal: Int32, to pid: Int32) -> Bool {
        kill(pid, signal) == 0
    }
}
