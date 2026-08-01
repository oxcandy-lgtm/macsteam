// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import Darwin

struct ProcessIdentity: Sendable, Equatable, Hashable {
    let pid: Int32
    let startSeconds: UInt64
    let startMicroseconds: UInt64
    let executableName: String
}

enum HostProcessState: String, Sendable, Equatable {
    case running
    case sleeping
    case zombie
    case stopped
    case idle
    case unknown

    init(darwinStatus: UInt32) {
        switch darwinStatus {
        case UInt32(SRUN): self = .running
        case UInt32(SSLEEP): self = .sleeping
        case UInt32(SZOMB): self = .zombie
        case UInt32(SSTOP): self = .stopped
        case UInt32(SIDL): self = .idle
        default: self = .unknown
        }
    }
}

struct HostProcessSnapshot: Sendable, Equatable {
    let identity: ProcessIdentity
    let ppid: Int32
    let state: HostProcessState

    var isZombie: Bool { state == .zombie }
}

struct LineageResult: Sendable, Equatable {
    let rootIdentity: ProcessIdentity
    let descendantCount: Int
    let zombieCount: Int
    let orphanCount: Int
    let totalLive: Int
}

enum HostProcessLineage {
    enum CensusError: LocalizedError, Sendable {
        case censusFailed
        case rootNotFound(Int32)
        case limitExceeded(Int)

        var errorDescription: String? {
            switch self {
            case .censusFailed: return "Process census failed"
            case .rootNotFound(let pid): return "Root process not found"
            case .limitExceeded(let n): return "Census limit exceeded: \(n)"
            }
        }
    }

    static let maxCensusSize = 4096

    static func snapshot(pid: Int32) -> HostProcessSnapshot? {
        var info = proc_bsdinfo()
        let size = proc_pidinfo(
            pid, PROC_PIDTBSDINFO, 0,
            &info, Int32(MemoryLayout<proc_bsdinfo>.size)
        )
        guard size > 0 else { return nil }
        let name = withUnsafeBytes(of: info.pbi_comm) { raw -> String in
            let bytes = raw.bindMemory(to: CChar.self)
            return String(cString: bytes.baseAddress!)
        }
        return HostProcessSnapshot(
            identity: ProcessIdentity(
                pid: pid,
                startSeconds: info.pbi_start_tvsec,
                startMicroseconds: info.pbi_start_tvusec,
                executableName: name
            ),
            ppid: Int32(info.pbi_ppid),
            state: HostProcessState(darwinStatus: info.pbi_status)
        )
    }

    static func lineage(from root: Int32) throws -> LineageResult {
        guard let rootSnap = snapshot(pid: root) else {
            throw CensusError.rootNotFound(root)
        }

        var allPIDs: [Int32] = Array(repeating: 0, count: maxCensusSize)
        let count = proc_listallpids(&allPIDs, Int32(maxCensusSize * MemoryLayout<Int32>.size))
        guard count > 0 else {
            throw CensusError.censusFailed
        }
        if Int(count) >= maxCensusSize {
            throw CensusError.limitExceeded(Int(count))
        }

        var snapshots: [Int32: HostProcessSnapshot] = [:]
        snapshots.reserveCapacity(Int(count))
        for i in 0..<Int(count) {
            let pid = allPIDs[i]
            if pid > 0, let snap = snapshot(pid: pid) {
                snapshots[pid] = snap
            }
        }

        var descendants: Set<Int32> = [root]
        var stack: [Int32] = [root]
        while let pid = stack.popLast() {
            for (childPID, childSnap) in snapshots where childSnap.ppid == pid {
                if descendants.insert(childPID).inserted {
                    stack.append(childPID)
                }
            }
        }

        let rootStartTime = rootSnap.identity.startSeconds
        var orphans: [Int32] = []
        for (pid, snap) in snapshots where !descendants.contains(pid) && pid != root {
            if snap.identity.executableName == rootSnap.identity.executableName,
               snap.identity.startSeconds >= rootStartTime {
                orphans.append(pid)
            }
        }

        let descendantSnaps = descendants.compactMap { snapshots[$0] }
        let zombieCount = descendantSnaps.filter { $0.isZombie }.count
        let liveCount = descendantSnaps.filter { !$0.isZombie }.count

        return LineageResult(
            rootIdentity: rootSnap.identity,
            descendantCount: descendants.count - 1,
            zombieCount: zombieCount,
            orphanCount: orphans.count,
            totalLive: liveCount
        )
    }
}
