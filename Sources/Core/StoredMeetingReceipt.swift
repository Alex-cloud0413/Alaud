import Foundation

/// Proof from the paired phone after every original and the final manifest have been saved and checked.
/// Legacy per-part/final acknowledgements never authorize deleting the watch copy.
public struct StoredMeetingReceipt: Codable, Equatable, Sendable {
    public struct Part: Codable, Equatable, Sendable {
        public var index: Int
        public var sha256: String
        public init(index: Int, sha256: String) { self.index = index; self.sha256 = sha256 }
    }
    public var schemaVersion: Int
    public var meetingID: UUID
    public var expectedPartCount: Int
    public var parts: [Part]

    public init(meeting: Meeting) {
        schemaVersion = 1; meetingID = meeting.id
        expectedPartCount = meeting.expectedPartCount ?? -1
        parts = meeting.parts.sorted { $0.index < $1.index }.map { Part(index: $0.index, sha256: $0.sha256) }
    }

    public func confirms(_ meeting: Meeting) -> Bool {
        guard schemaVersion == 1, meetingID == meeting.id, meeting.source == .watch,
              meeting.captureState == .finished || meeting.captureState == .interrupted,
              meeting.isComplete, expectedPartCount == meeting.expectedPartCount else { return false }
        return parts.sorted { $0.index < $1.index } == StoredMeetingReceipt(meeting: meeting).parts
    }
}
