// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import Darwin

/// Identity of a host process owned by (or observed under) a supervised session.
///
/// PID reuse rejection requires more than a PID: a PID alone can be reallocated
/// by the kernel to an unrelated process. Equality therefore includes the
/// process-lifetime-stable components — start seconds, start microseconds, and
/// the executable identity — so a reused PID is never mistaken for an owned
/// process.
struct ProcessIdentity: Sendable, Equatable, Hashable {
    let pid: Int32
    let startSeconds: UInt64
    let startMicroseconds: UInt64
    let executableName: String
    let canonicalExecutable: String

    /// Stable-process comparison used for PID-reuse detection. Start time is
    /// authoritative (allocated once by the kernel); the executable identity is
    /// compared by comm name, which is stable across a process's lifetime
    /// (live and zombie states), unlike a canonical path that is only
    /// resolvable while the process is running.
    func matches(_ other: ProcessIdentity) -> Bool {
        pid == other.pid
            && startSeconds == other.startSeconds
            && startMicroseconds == other.startMicroseconds
            && executableName == other.executableName
    }
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

/// Proof state of a process census.
///
/// A census is fail-closed: it is only `.proven` when the root identity
/// captured at launch is still verifiable and every enumeration step succeeded.
/// Any provider failure, root disappearance, identity drift, or bound
/// violation yields `.incomplete` and the diagnostic reports `notProven`.
enum ProcessCensusState: String, Sendable, Equatable {
    case incomplete
    case proven
}

/// Separated accounting for a supervised session's host process census.
///
/// The categories are deliberately NOT merged: zombies, live orphans, exited
/// processes, and reused PIDs are each reported independently so ownership
/// proof is auditable.
struct ProcessCensusResult: Sendable, Equatable {
    var state: ProcessCensusState
    var liveDescendants: Int
    var liveOrphans: Int
    var zombieCount: Int
    var exitedCount: Int
    var pidReuseCount: Int
    var totalLive: Int
    var error: HostProcessLineage.CensusError?

    static func incomplete(_ error: HostProcessLineage.CensusError) -> ProcessCensusResult {
        ProcessCensusResult(
            state: .incomplete,
            liveDescendants: 0,
            liveOrphans: 0,
            zombieCount: 0,
            exitedCount: 0,
            pidReuseCount: 0,
            totalLive: 0,
            error: error
        )
    }
}

/// The production ownership ledger for one supervised session.
///
/// Seeded once at launch with the root identity captured by
/// `ProcessSupervisor`. It records only processes *observed* as descendants of
/// the root via the full PPID chain. A process is admitted as an orphan only if
/// it was previously observed (recorded in this ledger) — there is no
/// name/executable guessing. The ledger is session-scoped and is reset whenever
/// a new session is launched or a session ends, so stale observations from a
/// previous session are never reused.
struct ProcessCensusLedger: Sendable {
    let rootIdentity: ProcessIdentity
    private(set) var observed: [ProcessIdentity]

    init(rootIdentity: ProcessIdentity) {
        self.rootIdentity = rootIdentity
        self.observed = []
    }

    /// Record (or refresh) an observed descendant identity.
    /// PID reuse is rejected by the stable-identity comparison: a PID whose
    /// identity drifted is never overwritten here.
    mutating func record(_ identity: ProcessIdentity) {
        if let idx = observed.firstIndex(where: { $0.matches(identity) }) {
            observed[idx] = identity
        } else {
            observed.append(identity)
        }
    }

    /// Replace the observed set after a census reconcile (prunes exited and
    /// reused entries so the ledger stays bounded).
    mutating func replaceObserved(with identities: [ProcessIdentity]) {
        observed = identities
    }
}

enum HostProcessLineage {
    enum CensusError: LocalizedError, Sendable, Equatable {
        case censusFailed
        case rootNotFound(Int32)
        case rootIdentityMismatch
        case limitExceeded(Int)
        case noLedger

        var errorDescription: String? {
            switch self {
            case .censusFailed: return "Process census failed"
            case .rootNotFound(let pid): return "Root process not found"
            case .rootIdentityMismatch: return "Root process identity no longer matches the captured launch identity"
            case .limitExceeded(let n): return "Census limit exceeded: \(n)"
            case .noLedger: return "No supervised session ledger for census"
            }
        }
    }

    static let maxCensusSize = 4096

    // MARK: - Snapshot

    /// Snapshot a single process.
    ///
    /// Primary path is `proc_pidinfo`; when it reports no data (macOS returns
    /// zero for a reaped-but-unreaped zombie), fall back to `sysctl
    /// KERN_PROC_PID`, which still reports a zombie's `p_stat == SZOMB`, its
    /// PPID, and its start time. This is what makes real POSIX zombie
    /// observation possible.
    static func snapshot(pid: Int32) -> HostProcessSnapshot? {
        if let viaProcInfo = procInfoSnapshot(pid: pid) {
            return viaProcInfo
        }
        return sysctlSnapshot(pid: pid)
    }

    private static func procInfoSnapshot(pid: Int32) -> HostProcessSnapshot? {
        var info = proc_bsdinfo()
        let size = proc_pidinfo(
            pid, PROC_PIDTBSDINFO, 0,
            &info, Int32(MemoryLayout<proc_bsdinfo>.size)
        )
        guard size > 0 else { return nil }
        let name = withUnsafeBytes(of: info.pbi_comm) { commName($0) }
        return HostProcessSnapshot(
            identity: ProcessIdentity(
                pid: pid,
                startSeconds: info.pbi_start_tvsec,
                startMicroseconds: info.pbi_start_tvusec,
                executableName: name,
                canonicalExecutable: canonicalExecutablePath(pid) ?? name
            ),
            ppid: Int32(info.pbi_ppid),
            state: HostProcessState(darwinStatus: info.pbi_status)
        )
    }

    private static func sysctlSnapshot(pid: Int32) -> HostProcessSnapshot? {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        var kp = kinfo_proc()
        var len = MemoryLayout<kinfo_proc>.size
        let result = sysctl(&mib, u_int(mib.count), &kp, &len, nil, 0)
        guard result == 0, len > 0 else { return nil }
        let name = withUnsafeBytes(of: kp.kp_proc.p_comm) { commName($0) }
        return HostProcessSnapshot(
            identity: ProcessIdentity(
                pid: pid,
                startSeconds: UInt64(kp.kp_proc.p_starttime.tv_sec),
                startMicroseconds: UInt64(kp.kp_proc.p_starttime.tv_usec),
                executableName: name,
                canonicalExecutable: canonicalExecutablePath(pid) ?? name
            ),
            ppid: Int32(kp.kp_eproc.e_ppid),
            state: HostProcessState(darwinStatus: UInt32(kp.kp_proc.p_stat))
        )
    }

    private static func commName(_ raw: UnsafeRawBufferPointer) -> String {
        let buf = raw.bindMemory(to: CChar.self)
        return String(cString: buf.baseAddress!)
    }

    private static func canonicalExecutablePath(_ pid: Int32) -> String? {
        var buffer = [CChar](repeating: 0, count: 4096)
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard length > 0 else { return nil }
        let path = String(cString: buffer)
        return URL(fileURLWithPath: path).resolvingSymlinksInPath().path
    }

    // MARK: - One-shot lineage (retained for compatibility)

    /// One-shot PPID-chain lineage rooted at `root`.
    ///
    /// A one-shot walk has no persistent ledger, so it cannot admit orphans:
    /// orphans require prior observation, which only the session-scoped ledger
    /// provides. `orphanCount` is therefore always zero here — ownership is
    /// never guessed from names or executables.
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

        let descendantSnaps = descendants.compactMap { snapshots[$0] }
        let zombieCount = descendantSnaps.filter { $0.isZombie }.count
        let liveCount = descendantSnaps.filter { !$0.isZombie }.count

        return LineageResult(
            rootIdentity: rootSnap.identity,
            descendantCount: descendants.count - 1,
            zombieCount: zombieCount,
            orphanCount: 0,
            totalLive: liveCount
        )
    }

    // MARK: - Production census

    /// Run a fail-closed census against the session ledger.
    ///
    /// - Root identity is the launch-captured identity stored in the ledger —
    ///   it is never re-acquired at census time. If the live root no longer
    ///   matches (gone, or PID reused), the census is `.incomplete`.
    /// - Descendants are discovered only via the full PPID chain from the
    ///   root. Orphans are admitted only from previously observed ledger
    ///   entries; no name or executable guessing is performed.
    /// - Any provider failure, enumeration bound, or ledger bound yields
    ///   `.incomplete` (never a proven zero).
    static func census(ledger: inout ProcessCensusLedger) -> ProcessCensusResult {
        guard let rootSnap = snapshot(pid: ledger.rootIdentity.pid) else {
            return .incomplete(.rootNotFound(ledger.rootIdentity.pid))
        }
        guard rootSnap.identity.matches(ledger.rootIdentity) else {
            return .incomplete(.rootIdentityMismatch)
        }

        var allPIDs: [Int32] = Array(repeating: 0, count: maxCensusSize)
        let count = proc_listallpids(&allPIDs, Int32(maxCensusSize * MemoryLayout<Int32>.size))
        guard count > 0 else {
            return .incomplete(.censusFailed)
        }
        if Int(count) >= maxCensusSize {
            return .incomplete(.limitExceeded(Int(count)))
        }

        var snapshots: [Int32: HostProcessSnapshot] = [:]
        snapshots.reserveCapacity(Int(count))
        for i in 0..<Int(count) {
            let pid = allPIDs[i]
            if pid > 0, let snap = snapshot(pid: pid) {
                snapshots[pid] = snap
            }
        }

        return reconcile(ledger: &ledger, root: rootSnap, all: snapshots)
    }

    /// Reconcile the ledger against a snapshot table.
    ///
    /// Exposed separately so the accounting rules can be tested deterministically
    /// with synthetic snapshots; `census(ledger:)` is the live provider wrapper.
    static func reconcile(
        ledger: inout ProcessCensusLedger,
        root: HostProcessSnapshot,
        all: [Int32: HostProcessSnapshot]
    ) -> ProcessCensusResult {
        guard root.identity.matches(ledger.rootIdentity) else {
            return .incomplete(.rootIdentityMismatch)
        }

        var reachable: Set<Int32> = [root.identity.pid]
        var stack: [Int32] = [root.identity.pid]
        while let pid = stack.popLast() {
            for (childPID, childSnap) in all where childSnap.ppid == pid {
                if reachable.insert(childPID).inserted {
                    stack.append(childPID)
                }
            }
        }

        var liveDescendants = 0
        var liveOrphans = 0
        var zombieCount = 0
        var exitedCount = 0
        var pidReuseCount = 0
        var surviving: [ProcessIdentity] = []
        var reusedPIDs: Set<Int32> = []

        // Reachable descendants: only the full PPID chain from the captured root.
        for pid in reachable {
            guard let snap = all[pid] else { continue }
            if let recorded = ledger.observed.first(where: { $0.pid == pid }),
               !recorded.matches(snap.identity) {
                pidReuseCount += 1
                reusedPIDs.insert(pid)
                continue
            }
            surviving.append(snap.identity)
            if pid == root.identity.pid { continue }
            if snap.isZombie {
                zombieCount += 1
            } else {
                liveDescendants += 1
            }
        }

        // Previously observed ledger entries that are no longer reachable.
        for entry in ledger.observed {
            if surviving.contains(where: { $0.matches(entry) }) { continue }
            if reusedPIDs.contains(entry.pid) { continue }
            guard let snap = all[entry.pid] else {
                exitedCount += 1
                continue
            }
            if snap.identity.matches(entry) {
                if !reachable.contains(entry.pid) {
                    if snap.isZombie {
                        zombieCount += 1
                    } else {
                        liveOrphans += 1
                    }
                    surviving.append(entry)
                }
            } else {
                pidReuseCount += 1
                reusedPIDs.insert(entry.pid)
            }
        }

        if surviving.count > maxCensusSize {
            return .incomplete(.limitExceeded(surviving.count))
        }

        ledger.replaceObserved(with: surviving)
        return ProcessCensusResult(
            state: .proven,
            liveDescendants: liveDescendants,
            liveOrphans: liveOrphans,
            zombieCount: zombieCount,
            exitedCount: exitedCount,
            pidReuseCount: pidReuseCount,
            totalLive: liveDescendants + liveOrphans,
            error: nil
        )
    }
}
