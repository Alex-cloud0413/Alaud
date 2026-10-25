import Foundation

/// Three-way field merge: unrelated offline edits survive. Concurrent text alternatives are retained
/// in notes rather than silently discarded. Audio identities are immutable once a meeting is complete.
public enum CloudMeetingMerge {
    public static func merge(base: Meeting?, local: Meeting, remote: Meeting) throws -> Meeting {
        guard local.id == remote.id, local.source == remote.source,
              local.parts.allSatisfy({ part in remote.parts.contains { $0.index == part.index && $0.sha256 == part.sha256 } }),
              !local.isComplete || local.parts.count == remote.parts.count else {
            throw CloudLibraryError.invalidReceipt
        }
        var result = local
        if !local.isComplete {
            result.parts = remote.parts; result.endedAt = remote.endedAt
            result.expectedPartCount = remote.expectedPartCount; result.captureState = remote.captureState; result.gaps = remote.gaps
        }
        var alternatives: [String] = []
        func text(_ local: String, _ remote: String, _ base: String?, label: String) -> String {
            if local == remote || remote == base { return local }
            if local == base || local.isEmpty { return remote }
            if !remote.isEmpty { alternatives.append("\(label)：\n\(remote)") }
            return local
        }
        result.title = text(local.title, remote.title, base?.title, label: "另一台设备的标题")
        result.notes = text(local.notes, remote.notes, base?.notes, label: "另一台设备的备注")
        let localFollow = Dictionary(uniqueKeysWithValues: local.followUps.map { ($0.id, $0) })
        let remoteFollow = Dictionary(uniqueKeysWithValues: remote.followUps.map { ($0.id, $0) })
        let baseFollow = Dictionary(uniqueKeysWithValues: (base?.followUps ?? []).map { ($0.id, $0) })
        result.followUps = []
        let orderedIDs = (local.followUps + remote.followUps).map(\.id).reduce(into: [UUID]()) { if !$0.contains($1) { $0.append($1) } }
        for id in orderedIDs {
            let l = localFollow[id], r = remoteFollow[id], b = baseFollow[id]
            if l == nil, let r {
                if b == nil || r != b { result.followUps.append(r) }
            } else if r == nil, let l {
                if b == nil || l != b { result.followUps.append(l) }
            } else if var l, let r {
                l.title = text(l.title, r.title, b?.title, label: "另一台设备的跟进事项")
                if l.completed == b?.completed { l.completed = r.completed }
                result.followUps.append(l)
            }
        }
        for index in remote.transcribedPartIndices where !local.transcribedPartIndices.contains(index) {
            result.transcript.removeAll { $0.partIndex == index }
            result.transcript += remote.transcript.filter { $0.partIndex == index }
            result.transcribedPartIndices.append(index)
        }
        result.transcribedPartIndices.sort(); result.transcript.sort { $0.offset < $1.offset }
        if result.transcribedPartIndices.count == result.parts.count {
            result.transcriptState = .ready; result.transcriptError = nil
        } else if local.transcriptState != .processing, remote.transcriptState == .ready { result.transcriptState = .waiting }
        if !alternatives.isEmpty {
            let appendix = alternatives.joined(separator: "\n\n")
            if !result.notes.contains(appendix) { result.notes += (result.notes.isEmpty ? "" : "\n\n") + appendix }
        }
        return result
    }
}
