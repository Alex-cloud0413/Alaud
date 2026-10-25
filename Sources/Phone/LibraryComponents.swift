import SwiftUI
import AlaudCore

struct MeetingRow: View {
    let meeting: Meeting
    var cloudSaved = false
    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: "waveform").font(.system(size: 20, weight: .medium))
                .frame(width: 42, height: 46).background(Color.alaudWash, in: RoundedRectangle(cornerRadius: 12))
            VStack(alignment: .leading, spacing: 8) {
                Text(meeting.title).font(.headline).foregroundStyle(.primary).lineLimit(2)
                HStack(spacing: 6) {
                    Text(meeting.createdAt, format: .dateTime.month().day().hour().minute())
                    Text("·"); Text(meeting.source.title)
                }.font(.caption).foregroundStyle(.secondary)
                HStack(spacing: 7) {
                    Text(meeting.stateTitle)
                    if cloudSaved { Image(systemName: "checkmark.icloud") }
                    if !meeting.gaps.isEmpty { Image(systemName: "exclamationmark.circle") }
                    let count = meeting.followUps.filter { !$0.completed }.count
                    if count > 0 { Text("· \(count) 项跟进") }
                }.font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            Text(audioClock(meeting.audioDuration)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
        }.padding(.vertical, 13)
    }
}

struct CloudStatusLine: View {
    @ObservedObject var cloud: CloudLibrary
    var body: some View {
        HStack(spacing: 7) {
            if cloud.isSyncing { ProgressView().controlSize(.small) }
            else { Image(systemName: cloud.lastIssue == nil ? "icloud" : "icloud.slash") }
            Text(cloud.status).lineLimit(2)
        }.font(.caption).foregroundStyle(.secondary)
    }
}
