import Foundation
import WatchConnectivity
import AlaudCore

/// This object is deliberately not main-actor isolated: temporary WCSession files must be copied before the delegate returns.
final class WatchTransfer: NSObject, WCSessionDelegate, @unchecked Sendable {
    private let store: MeetingStore
    var onChange: (() -> Void)?
    var onError: ((String) -> Void)?
    private let session: WCSession?
    private let codecLock = NSLock()

    init(store: MeetingStore) {
        self.store = store
        session = WCSession.isSupported() ? .default : nil
        super.init()
        session?.delegate = self; session?.activate()
    }

    func pump() {
        #if os(watchOS)
        guard let session, session.activationState == .activated else { return }
        do {
            for meeting in try store.list() where meeting.source == .watch {
                for part in meeting.parts where !part.receivedByPhone {
                    let key = "\(meeting.id.uuidString):\(part.index):\(part.sha256)"
                    guard !session.outstandingFileTransfers.contains(where: { $0.file.metadata?["key"] as? String == key }) else { continue }
                    session.transferFile(try store.audioURL(meetingID: meeting.id, part: part), metadata: [
                        "key": key, "envelope": try encode(TransferEnvelope(meeting: meeting, part: part))
                    ])
                }
                if meeting.endedAt != nil, !meeting.finalManifestAcknowledged {
                    let key = "final:\(meeting.id.uuidString)"
                    guard !session.outstandingUserInfoTransfers.contains(where: { $0.userInfo["key"] as? String == key }) else { continue }
                    session.transferUserInfo(["key": key, "kind": "final", "meeting": try encode(meeting)])
                }
            }
        } catch { report(error) }
        #endif
    }

    func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
        if let error { report(error) }
        pump(); changed()
    }

    func session(_ session: WCSession, didReceive file: WCSessionFile) {
        #if os(iOS)
        do {
            guard let data = file.metadata?["envelope"] as? Data else { throw StoreError.invalidPart }
            let envelope = try decode(TransferEnvelope.self, data: data)
            try store.importPart(from: file.fileURL, envelope: envelope)
            session.transferUserInfo(["kind": "partAck", "id": envelope.meeting.id.uuidString,
                                      "index": envelope.part.index, "hash": envelope.part.sha256])
            changed()
        } catch { report(error) }
        #endif
    }

    func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any] = [:]) {
        do {
            #if os(iOS)
            if userInfo["kind"] as? String == "final", let data = userInfo["meeting"] as? Data {
                let incoming = try decode(Meeting.self, data: data)
                try store.importFinalManifest(incoming)
                session.transferUserInfo(["kind": "finalAck", "id": incoming.id.uuidString])
                changed()
            }
            #else
            guard let value = userInfo["id"] as? String, let id = UUID(uuidString: value) else { return }
            if userInfo["kind"] as? String == "partAck", let index = userInfo["index"] as? Int,
               let hash = userInfo["hash"] as? String {
                try store.update(id) { meeting in
                    guard let i = meeting.parts.firstIndex(where: { $0.index == index && $0.sha256 == hash }) else { return }
                    meeting.parts[i].receivedByPhone = true
                }
            } else if userInfo["kind"] as? String == "finalAck" {
                try store.update(id) { $0.finalManifestAcknowledged = true }
            }
            changed(); pump()
            #endif
        } catch { report(error) }
    }

    func session(_ session: WCSession, didFinish fileTransfer: WCSessionFileTransfer, error: Error?) {
        // Transport completion is not durable receipt. Never delete or mark received here.
        if let error { report(error) }; changed()
    }

    #if os(iOS)
    func sessionDidBecomeInactive(_ session: WCSession) {}
    func sessionDidDeactivate(_ session: WCSession) { session.activate() }
    #endif

    private func changed() { DispatchQueue.main.async { [weak self] in self?.onChange?() } }
    private func report(_ error: Error) { DispatchQueue.main.async { [weak self] in self?.onError?(error.localizedDescription) } }
    private func encode<T: Encodable>(_ value: T) throws -> Data {
        codecLock.lock(); defer { codecLock.unlock() }
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(value)
    }
    private func decode<T: Decodable>(_ type: T.Type, data: Data) throws -> T {
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(type, from: data)
    }
}
