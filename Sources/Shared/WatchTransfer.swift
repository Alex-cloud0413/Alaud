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
    private let operationLock = NSRecursiveLock()
    private var lastStorageCheck: [UUID: Date] = [:]

    init(store: MeetingStore) {
        self.store = store
        session = WCSession.isSupported() ? .default : nil
        super.init()
        session?.delegate = self; session?.activate()
    }

    func pump() {
        #if os(watchOS)
        guard let session, session.activationState == .activated else { return }
        operationLock.lock(); defer { operationLock.unlock() }
        do { try store.finishConfirmedCleanup() } catch { report(error) }
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
                if meeting.transferComplete {
                    let key = "storageCheck:\(meeting.id.uuidString)"
                    let recent = lastStorageCheck[meeting.id].map { Date().timeIntervalSince($0) < 30 } ?? false
                    if !recent && !session.outstandingUserInfoTransfers.contains(where: { $0.userInfo["key"] as? String == key }) {
                        session.transferUserInfo(["key": key, "kind": "storageCheck", "meeting": try encode(meeting)])
                        lastStorageCheck[meeting.id] = Date()
                    }
                }
            }
        } catch { report(error) }
        #endif
    }

    func confirmStoredMeetings() {
        #if os(iOS)
        guard let session, session.activationState == .activated else { return }
        do {
            for meeting in try store.list() where meeting.source == .watch && meeting.isComplete {
                try sendStorageReceipt(for: meeting.id, session: session)
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
            try sendStorageReceipt(for: envelope.meeting.id, session: session)
            changed()
        } catch { report(error) }
        #endif
    }

    func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any] = [:]) {
        do {
            #if os(iOS)
            if ["final", "storageCheck"].contains(userInfo["kind"] as? String ?? ""), let data = userInfo["meeting"] as? Data {
                let incoming = try decode(Meeting.self, data: data)
                try store.importFinalManifest(incoming)
                session.transferUserInfo(["kind": "finalAck", "id": incoming.id.uuidString])
                if userInfo["kind"] as? String == "storageCheck" {
                    let missing = try store.missingPartIndices(from: incoming)
                    if !missing.isEmpty {
                        session.transferUserInfo(["kind": "resendParts", "id": incoming.id.uuidString, "indices": missing])
                    }
                }
                try sendStorageReceipt(for: incoming.id, session: session)
                changed()
            }
            #else
            guard let value = userInfo["id"] as? String, let id = UUID(uuidString: value) else { return }
            operationLock.lock(); defer { operationLock.unlock() }
            guard store.contains(id) else { return } // old acknowledgements after cleanup are harmless
            if userInfo["kind"] as? String == "storedMeetingAck", let data = userInfo["receipt"] as? Data {
                let receipt = try decode(StoredMeetingReceipt.self, data: data)
                guard receipt.meetingID == id, receipt.confirms(try store.load(id)) else { throw StoreError.unconfirmedCleanup }
                try store.removeConfirmedWatchCopy(receipt)
                lastStorageCheck.removeValue(forKey: id)
                // The phone already owns all originals. Cancel stale queued copies before reporting them as errors.
                for transfer in session.outstandingFileTransfers where transfer.file.metadata?["key"] as? String != nil {
                    if (transfer.file.metadata?["key"] as? String)?.hasPrefix(id.uuidString + ":") == true { transfer.cancel() }
                }
                for transfer in session.outstandingUserInfoTransfers {
                    if ["final:\(id.uuidString)", "storageCheck:\(id.uuidString)"].contains(transfer.userInfo["key"] as? String ?? "") { transfer.cancel() }
                }
                changed(); return
            }
            if userInfo["kind"] as? String == "resendParts", let indices = userInfo["indices"] as? [Int] {
                try store.update(id) { meeting in
                    for index in meeting.parts.indices where indices.contains(meeting.parts[index].index) {
                        meeting.parts[index].receivedByPhone = false
                    }
                }
            }
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
        if let key = fileTransfer.file.metadata?["key"] as? String,
           let value = key.split(separator: ":").first, let id = UUID(uuidString: String(value)), !store.contains(id) { return }
        if let error { report(error) }; changed()
    }

    #if os(iOS)
    func sessionDidBecomeInactive(_ session: WCSession) {}
    func sessionDidDeactivate(_ session: WCSession) { session.activate() }

    private func sendStorageReceipt(for id: UUID, session: WCSession) throws {
        if let receipt = try store.storedMeetingReceipt(for: id) {
            session.transferUserInfo(["kind": "storedMeetingAck", "id": id.uuidString, "receipt": try encode(receipt)])
        }
    }
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
