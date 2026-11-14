import Foundation

/// Lines about plans for the diagnostic report a user can send (I16): states, counts and
/// reason codes only. No album or folder names, no photo identifiers, no places: what
/// leaves the device must not say anything about the photos.
public enum PlanDiagnostics {
    /// Reason codes written by `ChangeExecutor`; anything else (a system error text) is
    /// reduced to its error domain and code.
    static let knownReasons: Set<String> = StepState.dependencyReasons.union([
        "interrupted", "a collection with this title appeared meanwhile", "parent folder no longer exists",
        "created collection could not be verified", "album no longer exists", "added media could not be verified",
        "rename could not be verified", "move could not be verified", "removal could not be verified",
        "deletion could not be verified", "folder is not empty", StepState.leftByUserReason,
        "kept: the album holds photos added meanwhile; only Albumist's photos were taken out",
    ])

    public static func reasonCode(_ reason: String) -> String {
        if knownReasons.contains(reason) { return reason }
        // "Error Domain=PHPhotosErrorDomain Code=3300 …" → "PHPhotosErrorDomain 3300".
        let domain = reason.range(of: #"Domain=([A-Za-z0-9_.]+)"#, options: .regularExpression)
            .map { String(reason[$0].dropFirst("Domain=".count)) }
        let code = reason.range(of: #"Code=(-?[0-9]+)"#, options: .regularExpression)
            .map { String(reason[$0].dropFirst("Code=".count)) }
        if let domain { return "error \(domain) \(code ?? "?")" }
        return "error (other)"
    }

    public static func describe(_ plan: ChangePlan) -> String {
        var ok = 0, failed = 0, skipped = 0, open = 0
        var reasons: [String: Int] = [:]
        var ops: [String: Int] = [:]
        var photos = 0
        for step in plan.steps {
            switch step.state {
            case .succeeded: ok += 1
            case .failed(let r): failed += 1; reasons[reasonCode(r), default: 0] += 1
            case .skipped(let r): skipped += 1; reasons[reasonCode(r), default: 0] += 1
            case .pending, .running: open += 1
            }
            switch step.operation {
            case .createFolder: ops["folder", default: 0] += 1
            case .createAlbum: ops["album", default: 0] += 1
            case .addAssets(_, let assets): ops["add", default: 0] += 1; photos += assets.count
            case .renameCollection: ops["rename", default: 0] += 1
            case .moveCollection: ops["move", default: 0] += 1
            case .removeAssets(_, let assets): ops["remove", default: 0] += 1; photos += assets.count
            case .deleteCollection: ops["delete", default: 0] += 1
            }
        }
        let date = ISO8601DateFormatter().string(from: plan.confirmedAt ?? plan.createdAt)
        var parts = ["plan \(plan.id.rawValue.prefix(8))", date, plan.status.rawValue]
        if let reverts = plan.reverts { parts.append("undo of \(reverts.rawValue.prefix(8))") }
        parts.append("steps \(plan.steps.count): \(ok) ok, \(failed) failed, \(skipped) skipped, \(open) open")
        if let record = plan.record {
            parts.append("unverified \(record.unverified.count), adopted \(record.adoptedKeys.count), unavailable \(record.unavailable.values.reduce(0, +))")
        } else {
            parts.append("no journal")
        }
        parts.append("ops " + ops.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" }.joined(separator: ", ") + " (\(photos) photo refs)")
        if !reasons.isEmpty {
            parts.append("reasons " + reasons.sorted { $0.key < $1.key }.map { "\($0.key) ×\($0.value)" }.joined(separator: "; "))
        }
        if plan.finalizedAt == nil && (plan.status == .completed || plan.status == .completedWithErrors) { parts.append("not finalized") }
        return parts.joined(separator: " · ")
    }
}
