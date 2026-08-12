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
    /// authoritative (allocated once by the kernel). The canonical executable
    /// identity is a required part of the ownership comparison — a comm name
    /// is never substituted for it, and an **empty** canonical executable can
    /// never satisfy an ownership match. A PID whose canonical executable
    /// differs or whose identity drifted at all is a reused (or unproven) PID.
    func matches(_ other: ProcessIdentity) -> Bool {
        // Fail-closed: an empty canonical executable carries no ownership
        // proof. Two empty-canonical identities must never match (this also
        // forbids the "empty == empty" false positive).
        guard !canonicalExecutable.isEmpty, !other.canonicalExecutable.isEmpty else {
            return false
        }
        return pid == other.pid
            && startSeconds == other.startSeconds
            && startMicroseconds == other.startMicroseconds
            && canonicalExecutable == other.canonicalExecutable
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

/// Outcome of a single-process probe by the production provider.
///
/// Every outcome is accounted for explicitly — a failed probe is never
/// silently dropped, never treated as an exit, and never misrepresented.
enum ProcessProbeOutcome: Sendable, Equatable {
    /// A complete snapshot was obtained for a present process.
    case present(HostProcessSnapshot)
    /// The kernel confirms the PID does not exist — a definitive exit.
    case confirmedExited
    /// The process may exist but its identity could not be established
    /// (provider refused or errored) — ambiguous, never counted as exited.
    case inaccessible
    /// The underlying kernel provider call failed unexpectedly — ambiguous.
    case providerFailure
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
    /// Number of probe outcomes that were ambiguous (inaccessible or provider
    /// failure). A proven census always has zero; any unresolved outcome fails
    /// the census closed.
    var unresolvedOutcomes: Int
    /// Number of snapshot probes silently dropped. Zero by construction —
    /// every probe outcome is explicitly accounted for by the provider.
    var silentSnapshotDrops: Int

    init(
        state: ProcessCensusState,
        liveDescendants: Int,
        liveOrphans: Int,
        zombieCount: Int,
        exitedCount: Int,
        pidReuseCount: Int,
        totalLive: Int,
        error: HostProcessLineage.CensusError?,
        unresolvedOutcomes: Int = 0,
        silentSnapshotDrops: Int = 0
    ) {
        self.state = state
        self.liveDescendants = liveDescendants
        self.liveOrphans = liveOrphans
        self.zombieCount = zombieCount
        self.exitedCount = exitedCount
        self.pidReuseCount = pidReuseCount
        self.totalLive = totalLive
        self.error = error
        self.unresolvedOutcomes = unresolvedOutcomes
        self.silentSnapshotDrops = silentSnapshotDrops
    }

    static func incomplete(
        _ error: HostProcessLineage.CensusError,
        unresolvedOutcomes: Int = 0,
        silentSnapshotDrops: Int = 0
    ) -> ProcessCensusResult {
        ProcessCensusResult(
            state: .incomplete,
            liveDescendants: 0,
            liveOrphans: 0,
            zombieCount: 0,
            exitedCount: 0,
            pidReuseCount: 0,
            totalLive: 0,
            error: error,
            unresolvedOutcomes: unresolvedOutcomes,
            silentSnapshotDrops: silentSnapshotDrops
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
    /// Canonical root of the supervised Wine prefix. When present, the census
    /// additionally admits re-parented Wine processes (wineserver detaches its
    /// children to launchd, so they leave the PPID chain) whose canonical
    /// executable lives under this prefix and which started at/after the root.
    /// Ownership is path-grounded — never name-guessed.
    let prefixRoot: String?
    private(set) var observed: [ProcessIdentity]

    init(rootIdentity: ProcessIdentity, prefixRoot: String? = nil) {
        self.rootIdentity = rootIdentity
        self.prefixRoot = prefixRoot
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
        case rootUnavailable(Int32)
        case rootIdentityMismatch
        case limitExceeded(Int)
        case enumerationTruncated
        case providerOutcomeUnresolved(Int)
        case snapshotUnstable
        case noLedger

        var errorDescription: String? {
            switch self {
            case .censusFailed: return "Process census failed"
            case .rootNotFound(let pid): return "Root process not found"
            case .rootUnavailable(let pid): return "Root process identity could not be established"
            case .rootIdentityMismatch: return "Root process identity no longer matches the captured launch identity"
            case .limitExceeded(let n): return "Census limit exceeded: \(n)"
            case .enumerationTruncated: return "Process enumeration may be truncated"
            case .providerOutcomeUnresolved(let n): return "\(n) ambiguous process probe outcome(s)"
            case .snapshotUnstable: return "Process table never settled to a coherent snapshot"
            case .noLedger: return "No supervised session ledger for census"
            }
        }
    }

    static let maxCensusSize = 4096

    // MARK: - Provider

    /// Probe a single process, separating every outcome.
    ///
    /// `knownIdentity` is the previously observed identity for this PID, if
    /// any. A process that becomes a zombie loses its canonical executable
    /// (macOS can no longer resolve its path); in that case the previously
    /// acquired identity is inherited so ownership is stable — a zombie is
    /// never assigned a fabricated identity. Canonical lookup failure is never
    /// substituted with the comm name.
    static func probe(pid: Int32, knownIdentity: ProcessIdentity? = nil) -> ProcessProbeOutcome {
        var info = proc_bsdinfo()
        let size = proc_pidinfo(
            pid, PROC_PIDTBSDINFO, 0,
            &info, Int32(MemoryLayout<proc_bsdinfo>.size)
        )
        if size > 0 {
            let name = withUnsafeBytes(of: info.pbi_comm) { commName($0) }
            return presentOnlyIfProven(HostProcessSnapshot(
                identity: ProcessIdentity(
                    pid: pid,
                    startSeconds: info.pbi_start_tvsec,
                    startMicroseconds: info.pbi_start_tvusec,
                    executableName: name,
                    canonicalExecutable: inheritedCanonical(
                        pid: pid,
                        startSeconds: info.pbi_start_tvsec,
                        startMicroseconds: info.pbi_start_tvusec,
                        resolved: canonicalExecutablePath(pid),
                        knownIdentity: knownIdentity
                    )
                ),
                ppid: Int32(info.pbi_ppid),
                state: HostProcessState(darwinStatus: info.pbi_status)
            ))
        }
        if size < 0 {
            // Provider error (e.g. permission refusal): the process may or may
            // not exist — ambiguous, never treated as exited.
            return .inaccessible
        }

        // `proc_pidinfo` returned no data: the process is either a reaped-but-
        // unreaped zombie or it is gone. sysctl KERN_PROC_PID still reports a
        // zombie's `p_stat == SZOMB`, PPID, and start time; a missing PID
        // reports no data. This is what makes real POSIX zombie observation
        // possible.
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        var kp = kinfo_proc()
        var len = MemoryLayout<kinfo_proc>.size
        let result = sysctl(&mib, u_int(mib.count), &kp, &len, nil, 0)
if result == 0, len > 0 {
            let name = withUnsafeBytes(of: kp.kp_proc.p_comm) { commName($0) }
            return presentOnlyIfProven(HostProcessSnapshot(
                identity: ProcessIdentity(
                    pid: pid,
                    startSeconds: UInt64(kp.kp_proc.p_starttime.tv_sec),
                    startMicroseconds: UInt64(kp.kp_proc.p_starttime.tv_usec),
                    executableName: name,
                    canonicalExecutable: inheritedCanonical(
                        pid: pid,
                        startSeconds: UInt64(kp.kp_proc.p_starttime.tv_sec),
                        startMicroseconds: UInt64(kp.kp_proc.p_starttime.tv_usec),
                        resolved: canonicalExecutablePath(pid),
                        knownIdentity: knownIdentity
                    )
                ),
                ppid: Int32(kp.kp_eproc.e_ppid),
                state: HostProcessState(darwinStatus: UInt32(kp.kp_proc.p_stat))
            ))
        }
        if result == 0 {
            // Kernel confirms the PID does not exist — a definitive exit.
            return .confirmedExited
        }
        return .providerFailure
    }

    /// Resolve the canonical executable identity, inheriting the previously
    /// observed identity's canonical when it can no longer be resolved (a
    /// zombie loses its path). Canonical lookup failure is never substituted
    /// with the comm name; an unknown zombie keeps an empty (honest) canonical
    /// rather than a fabricated one.
    private static func inheritedCanonical(
        pid: Int32,
        startSeconds: UInt64,
        startMicroseconds: UInt64,
        resolved: String?,
        knownIdentity: ProcessIdentity?
    ) -> String {
        if let resolved, !resolved.isEmpty {
            return resolved
        }
        if let knownIdentity,
           knownIdentity.pid == pid,
           knownIdentity.startSeconds == startSeconds,
           knownIdentity.startMicroseconds == startMicroseconds,
           !knownIdentity.canonicalExecutable.isEmpty {
            return knownIdentity.canonicalExecutable
        }
        return ""
    }

    /// Convenience snapshot of a single process.
    ///
    /// Retained for the one-shot lineage walk and single-PID probes. The
    /// production census uses the coherent native-table provider so every
    /// outcome is explicitly accounted for — a nil here means the process is
    /// absent or its identity could not be established, and callers must treat
    /// it accordingly.
    static func snapshot(pid: Int32) -> HostProcessSnapshot? {
        if case .present(let snap) = probe(pid: pid) { return snap }
        return nil
    }

    /// A process is admitted as `present` only if its canonical executable
    /// identity is non-empty (comm/basename/argv are never substituted). This
    /// holds for zombies too: only a previously captured (same PID + start
    /// tuple) non-empty canonical is inherited; an *unobserved* zombie whose
    /// canonical cannot be resolved is ambiguous (`inaccessible`) — never a
    /// silent exit, never a proven present, and its empty canonical is never
    /// placed into a snapshot, a retry candidate, or the ledger.
    private static func presentOnlyIfProven(_ snap: HostProcessSnapshot) -> ProcessProbeOutcome {
        if snap.identity.canonicalExecutable.isEmpty {
            return .inaccessible
        }
        return .present(snap)
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

    // MARK: - Coherent native-table snapshot (production authority)

    /// One raw row of the native process table, captured in a single
    /// `sysctl(KERN_PROC_ALL)` read so a snapshot generation is topologically
    /// coherent (PID, PPID, state, and start time are all from one read).
    struct NativeProcessRow: Hashable, Sendable {
        var pid: Int32
        var ppid: Int32
        var state: HostProcessState
        var startSeconds: UInt64
        var startMicroseconds: UInt64
        var name: String
    }

    /// Capture the whole process table (PID, PPID, state, start time) in one
    /// `sysctl(KERN_PROC_ALL)` read. Consistently bounded by `maxCensusSize`.
    static func nativeTableSnapshot() -> [Int32: NativeProcessRow] {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0]
        var capacity = 2048
        while capacity <= maxCensusSize {
            var buffer = [kinfo_proc](repeating: kinfo_proc(), count: capacity)
            var size = buffer.count * MemoryLayout<kinfo_proc>.size
            let result = sysctl(&mib, u_int(mib.count), &buffer, &size, nil, 0)
            if result == 0 {
                let n = min(buffer.count, max(0, size) / MemoryLayout<kinfo_proc>.size)
                var rows: [Int32: NativeProcessRow] = [:]
                for i in 0..<n {
                    let kp = buffer[i]
                    let pid = Int32(kp.kp_proc.p_pid)
                    guard pid > 0 else { continue }
                    let name = withUnsafeBytes(of: kp.kp_proc.p_comm) { commName($0) }
                    rows[pid] = NativeProcessRow(
                        pid: pid,
                        ppid: Int32(kp.kp_eproc.e_ppid),
                        state: HostProcessState(darwinStatus: UInt32(kp.kp_proc.p_stat)),
                        startSeconds: UInt64(kp.kp_proc.p_starttime.tv_sec),
                        startMicroseconds: UInt64(kp.kp_proc.p_starttime.tv_usec),
                        name: name
                    )
                }
                return rows
            }
            if capacity >= maxCensusSize {
                return [:]
            }
            capacity = min(capacity * 2, maxCensusSize)
        }
        return [:]
    }

    /// Run a fail-closed census against the session ledger.
    ///
    /// The production authority is a **coherent native snapshot**: the whole
    /// table is captured in one generation; the topology must be byte-identical
    /// on a re-capture before the census is trusted. Ownership is proven only
    /// against the launch-captured identity — never re-acquired at census time.
    ///
    /// - Root identity is the launch-captured identity stored in the ledger. If
    ///   the live root no longer matches (gone, unavailable, PID reused), the
    ///   census is `.incomplete`.
    /// - Descendants are discovered only via the full PPID chain within the
    ///   coherent snapshot. Orphans are admitted only from previously observed
    ///   ledger entries; no name or executable guessing is performed.
    /// - If the table never stabilises (a process repeatedly exits / execs /
    ///   re-sets PID / burps PPID during capture), the attempt is bounded and
    ///   the census fails closed as `.snapshotUnstable`. An owned grandchild is
    ///   never silently dropped behind a proven result.
    /// - An ambiguous (live process whose canonical executable cannot be
    ///   resolved) *owned* row forces `.providerOutcomeUnresolved`. Truncation
    ///   and bound overflow also fail closed.
    static func census(ledger: inout ProcessCensusLedger) -> ProcessCensusResult {
        census(
            ledger: &ledger,
            captureTable: { nativeTableSnapshot() },
            canonicalResolver: { row, known in resolveCanonical(row, known: known) },
            prefixRoot: ledger.prefixRoot
        )
    }

    /// Ownership-bound PID snapshot for window scoping.
    ///
    /// Runs a normal coherent census against the session ledger and, on a
    /// `.proven` result, returns the full set of PIDs proven to belong to
    /// the supervised session (root + descendants + observed orphans).
    /// Returns `nil` on any non-proven outcome — the caller must fail closed.
    ///
    /// Reuses the production `census(ledger:)` authority (two independent
    /// captures, coherence gate, bounded retry). Introduces no new process-
    /// tree enumeration. The ledger is updated in place.
    static func ownedProcessIDs(
        ledger: inout ProcessCensusLedger
    ) -> Set<Int32>? {
        let result = census(ledger: &ledger)
        guard result.state == .proven else { return nil }
        return Set(ledger.observed.map(\.pid))
    }

    /// Retries before a census is declared unstable/incomplete.
    static let maxTableRetries = 3

    /// Internal seam used by the production census; the coherent-table provider
    /// and canonical resolver are injectable so the stability / ambiguity
    /// behavior can be tested deterministically. Production uses `census(ledger:)`.
    ///
    /// `prefixRoot` (canonical prefix root) enables re-parented-Wine admission:
    /// Wine's wineserver detaches its children to launchd (PPID 1), so a pure
    /// PPID-chain walk loses steamwebhelper / steamservice / winedevice even
    /// though they belong to the supervised session. A process is admitted as
    /// owned when its canonical executable path is under the prefix root and
    /// its start time is at/after the root's — identity-path grounding, never
    /// name/executable guessing. Defaults to `nil` (pure PPID-chain behavior)
    /// so existing callers and deterministic tests are unchanged.
    static func census(
        ledger: inout ProcessCensusLedger,
        captureTable: @escaping () -> [Int32: NativeProcessRow],
        canonicalResolver: (NativeProcessRow, ProcessIdentity?) -> String = { _, _ in "" },
        prefixRoot: String? = nil
    ) -> ProcessCensusResult {
        var attemptNumber = 0
        // Identities discovered during an attempt that later proved unstable are
        // carried forward so a descendant once seen is never forgotten on a
        // retry. Everything in `ledger.observed`, the current reachable set, and
        // these carried candidates is resolved by the final stable attempt.
        var carriedCandidates: [ProcessIdentity] = []
        while attemptNumber < maxTableRetries {
            attemptNumber += 1

            let first = captureTable()
            guard !first.isEmpty else {
                if attemptNumber >= maxTableRetries {
                    return .incomplete(.censusFailed)
                }
                continue
            }
            if first.count > maxCensusSize {
                return .incomplete(.limitExceeded(first.count))
            }

            // 1. Root must be present and its canonical identity revalidated.
            guard let rootRow = first[ledger.rootIdentity.pid] else {
                return .incomplete(.rootNotFound(ledger.rootIdentity.pid))
            }
            let knownRoot = ledger.rootIdentity
            let rootCanonical = canonicalResolver(rootRow, knownRoot)
            let rootSnapshot = makeSnapshot(row: rootRow, canonical: rootCanonical)
            if rootRow.state != .zombie && rootCanonical.isEmpty {
                // The live root's canonical executable could not be established.
                return .incomplete(.rootUnavailable(ledger.rootIdentity.pid))
            }
            guard rootSnapshot.identity.matches(ledger.rootIdentity) else {
                return .incomplete(.rootIdentityMismatch)
            }

            // 2. Reachable set via the full PPID chain over the coherent table.
            var reachable: Set<Int32> = [ledger.rootIdentity.pid]
            var stack: [Int32] = [ledger.rootIdentity.pid]
            while let pid = stack.popLast() {
                for (childPID, childRow) in first where childRow.ppid == pid {
                    if reachable.insert(childPID).inserted {
                        stack.append(childPID)
                    }
                }
            }

            // 2b. Re-parented Wine family: processes under the canonical prefix
            //     that were detached from the root (PPID 1) by wineserver.
            //     Admission requires a resolvable canonical path under the
            //     prefix root AND a start at/after the root — stale processes
            //     from a previous session in the same prefix are never admitted.
            if let prefixRoot, !prefixRoot.isEmpty {
                let normalizedPrefix = URL(fileURLWithPath: prefixRoot)
                    .resolvingSymlinksInPath().path
                let rootStart = rootRow.startSeconds
                for (pid, row) in first where row.ppid == 1 {
                    guard row.state != .zombie else { continue }
                    guard row.startSeconds >= rootStart else { continue }
                    guard let resolved = canonicalExecutablePath(pid), !resolved.isEmpty else { continue }
                    let normalized = URL(fileURLWithPath: resolved)
                        .resolvingSymlinksInPath().path
                    guard normalized.hasPrefix(normalizedPrefix) else { continue }
                    reachable.insert(pid)
                }
            }

            // 3. Resolve the identity of every relevant row: the current reachable
            //    descendants ∪ the ledger's observed identities ∪ the candidates
            //    carried forward from a previous unstable attempt. Every live row
            //    — and every row (including an *unobserved* zombie) whose canonical
            //    is unresolvable — is ambiguous and fails the census closed. An
            //    empty canonical is never placed into a snapshot, a candidate, or
            //    the ledger.
            var snapshots: [Int32: HostProcessSnapshot] = [:]
            snapshots.reserveCapacity(reachable.count + ledger.observed.count + carriedCandidates.count)
            var unresolved = 0
            var relevant: Set<Int32> = reachable
                .union(ledger.observed.map(\.pid))
                .union(carriedCandidates.map(\.pid))
            for pid in relevant {
                guard let row = first[pid] else { continue }
                let known = ledger.observed.first(where: { $0.pid == pid })
                let canonical = canonicalResolver(row, known)
                if canonical.isEmpty {
                    unresolved += 1
                    continue
                }
                snapshots[pid] = makeSnapshot(row: row, canonical: canonical)
            }
            if unresolved > 0 {
                return .incomplete(.providerOutcomeUnresolved(unresolved), unresolvedOutcomes: unresolved)
            }

            // 4. Coherence gate: every relevant (owned) row must be identical on
            //    a re-capture (no exit/exec/PID-reuse/reparent during
            //    resolution), otherwise the attempt is unstable. Carry its
            //    resolved identities forward so a descendant discovered mid-
            //    transition is retained by the next retry, then retry within the
            //    bound. Unrelated system churn is ignored — only ownership-
            //    relevant topology is compared.
            let second = captureTable()
            var coherent = true
            for pid in relevant {
                if first[pid] != second[pid] {
                    coherent = false
                    break
                }
            }
            if !coherent {
                for snap in snapshots.values where !ledger.observed.contains(where: { $0.matches(snap.identity) }) {
                    if !carriedCandidates.contains(where: { $0.matches(snap.identity) }) {
                        if carriedCandidates.count >= maxCensusSize {
                            return .incomplete(.limitExceeded(carriedCandidates.count + 1))
                        }
                        carriedCandidates.append(snap.identity)
                    }
                }
                if attemptNumber >= maxTableRetries {
                    return .incomplete(.snapshotUnstable)
                }
                continue
            }

            // 5. Stable, coherent generation -> reconcile ownership accounting,
            //    resolving every carried candidate (descendant / orphan /
            //    confirmed-exited / PID-reuse) before provenance is granted.
            return reconcile(
                ledger: &ledger,
                root: rootSnapshot,
                all: snapshots,
                carriedCandidates: carriedCandidates,
                silentSnapshotDrops: 0
            )
        }
        return .incomplete(.snapshotUnstable)
    }

    /// Resolve the canonical executable identity for a table row, inheriting the
    /// previously observed canonical for a known zombie. An empty result means
    /// the identity could not be established — never substituted with comm name.
    private static func resolveCanonical(_ row: NativeProcessRow, known: ProcessIdentity?) -> String {
        if let resolved = canonicalExecutablePath(row.pid), !resolved.isEmpty {
            return resolved
        }
        if row.state == .zombie, let known,
           known.pid == row.pid,
           known.startSeconds == row.startSeconds,
           known.startMicroseconds == row.startMicroseconds,
           !known.canonicalExecutable.isEmpty {
            return known.canonicalExecutable
        }
        return ""
    }

    /// Build a `HostProcessSnapshot` for a row carrying the resolved canonical.
    private static func makeSnapshot(row: NativeProcessRow, canonical: String) -> HostProcessSnapshot {
        HostProcessSnapshot(
            identity: ProcessIdentity(
                pid: row.pid,
                startSeconds: row.startSeconds,
                startMicroseconds: row.startMicroseconds,
                executableName: row.name,
                canonicalExecutable: canonical
            ),
            ppid: row.ppid,
            state: row.state
        )
    }

    /// Reconcile the ledger against a snapshot table.
    ///
    /// Exposed separately so the accounting rules can be tested deterministically
    /// with synthetic snapshots; `census(ledger:)` is the live provider wrapper.
    ///
    /// `carriedCandidates` are identities discovered during a previous unstable
    /// attempt that must be resolved before provenance is granted: each is
    /// accounted as a descendant (if reachable), an orphan (if present with a
    /// matching identity but no longer reachable), confirmed-exited (if absent
    /// from the table), or PID-reuse (if a different identity now occupies its
    /// PID). A carried candidate is never silently dropped.
    static func reconcile(
        ledger: inout ProcessCensusLedger,
        root: HostProcessSnapshot,
        all: [Int32: HostProcessSnapshot],
        carriedCandidates: [ProcessIdentity] = [],
        silentSnapshotDrops: Int = 0
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

        // Previously observed ledger entries that are no longer reachable,
        // plus carried candidates that must resolve before provenance is granted.
        var considered = ledger.observed
        for candidate in carriedCandidates
        where !considered.contains(where: { $0.matches(candidate) }) {
            considered.append(candidate)
        }
        for entry in considered {
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
            error: nil,
            unresolvedOutcomes: 0,
            silentSnapshotDrops: silentSnapshotDrops
        )
    }
}
