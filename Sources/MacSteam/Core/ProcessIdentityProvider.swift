// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import Darwin.sys.proc

/// Real process identity provider using macOS proc_info APIs.
struct RealProcessIdentityProvider: ProcessIdentityProviding {
    func identity(forPID pid: Int32) throws -> ProcessIdentitySnapshot {
        // Get executable path via proc_pidpath
        var buf = [UInt8](repeating: 0, count: 4096) // PROC_PIDPATH_SIZE_MAX
        let pathLen = proc_pidpath(pid, &buf, UInt32(buf.count))
        guard pathLen > 0 else {
            throw ProcessIdentityError.cannotResolveExecutablePath
        }
        let execPath = String(cString: buf)

        // Get process start time via proc_pidinfo
        var info = proc_bsdinfo()
        let infoSize = MemoryLayout<proc_bsdinfo>.size
        let ret = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(infoSize))
        guard ret >= infoSize else {
            throw ProcessIdentityError.cannotResolveStartTime
        }

        return ProcessIdentitySnapshot(
            pid: pid,
            executablePath: execPath,
            startTimeSeconds: UInt64(info.pbi_start_tvsec),
            startTimeMicroseconds: UInt64(info.pbi_start_tvusec)
        )
    }
}

enum ProcessIdentityError: Error, Sendable {
    case cannotResolveExecutablePath
    case cannotResolveStartTime
}
