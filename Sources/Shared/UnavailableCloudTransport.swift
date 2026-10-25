#if !os(watchOS)
import Foundation
import AlaudCore

actor UnavailableCloudTransport: CloudTransport {
    func identity() async throws -> String { throw CloudLibraryError.unavailable }
    func meetingIndex() async throws -> [CloudIndexEntry] { throw CloudLibraryError.unavailable }
    func fetchMeeting(_ id: UUID) async throws -> CloudMeetingSnapshot? { throw CloudLibraryError.unavailable }
    func saveMeeting(_ meeting: Meeting, expectedRevision: String?) async throws -> CloudMeetingSnapshot { throw CloudLibraryError.unavailable }
    func saveAudio(meeting: Meeting, part: AudioPart, localURL: URL?) async throws -> CloudPartProof { throw CloudLibraryError.unavailable }
    func publishMeeting(_ id: UUID, revision: String) async throws -> String { throw CloudLibraryError.unavailable }
    func downloadAudio(meetingID: UUID, part: AudioPart, destination: URL) async throws { throw CloudLibraryError.unavailable }
}
#endif
