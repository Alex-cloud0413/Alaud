import AlaudCore

/// Mac receives its library through iCloud. Watch pairing stays with the iPhone.
final class WatchTransfer {
    var onChange: (() -> Void)?
    var onError: ((String) -> Void)?
    init(store: MeetingStore) {}
    func pump() {}
    func confirmStoredMeetings() {}
}
