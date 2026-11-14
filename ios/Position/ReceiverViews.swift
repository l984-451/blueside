import FlightCore
import SwiftUI

/// A small antenna under the strip once a receiver has been heard; slashed while it is lost.
struct ReceiverBadge: View {
    let receiver: TrafficReceiver

    var body: some View {
        if receiver.heard {
            let on = receiver.connected
            Image(systemName: on ? "antenna.radiowaves.left.and.right" : "antenna.radiowaves.left.and.right.slash")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(on ? Color.primary : PanelInk.warning)
                .padding(chromeInset / 2)
                .modifier(NightDim())
                .glassEffect(.regular, in: .circle)
                .accessibilityLabel(on ? "ADS-B receiver connected" : "ADS-B receiver lost")
                .accessibilityIdentifier("receiver-badge")
        }
    }
}

/// What the traffic layer holds, for UI tests.
struct TrafficProbe: View {
    let receiver: TrafficReceiver

    var body: some View {
        Text(receiver.summary).font(.caption2).foregroundStyle(.clear).accessibilityIdentifier("map-traffic")
            .overlay {
                Text(receiver.received).font(.caption2).foregroundStyle(.clear).fixedSize()
                    .accessibilityIdentifier("map-receiver")
            }
    }
}

/// Settings > Devices: the receiver's state and where the aircraft symbol takes its position from.
struct ReceiverPage: View {
    let receiver: TrafficReceiver
    @AppStorage(OwnshipSource.key) private var source = OwnshipSource.auto

    var body: some View {
        let status = receiver.status
        Form {
            Section {
                LabeledContent("ADS-B Receiver", value: status.name ?? (receiver.connected ? "Connected" : "Not connected"))
                    .accessibilityIdentifier("receiver-name")
                LabeledContent("Status", value: receiver.listening
                               ? (receiver.connected ? "Connected" : "Not connected") : ReceiverStatus.notListening)
                    .accessibilityIdentifier("receiver-status")
                LabeledContent("GPS", value: status.gpsValid ? "Valid" : "No fix")
                    .accessibilityIdentifier("receiver-gps")
                Clock(next: { status.lastMessageChange(after: $0) }) { now in
                    LabeledContent("Last message", value: status.lastMessageText(at: now))
                        .accessibilityIdentifier("receiver-last")
                }
            } footer: {
                VStack(alignment: .leading) {
                    Text("Join the receiver's Wi-Fi network. Blueside listens for GDL 90 on UDP port 4000.")
                    if !receiver.listening { Text(ReceiverStatus.listenFailureNote) }
                }
            }
            Section {
                Picker("Position source", selection: $source) {
                    ForEach(OwnshipSource.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .accessibilityIdentifier("ownship-source")
            } footer: {
                Text("Automatic uses the receiver's GPS while it has a fix, and this device's otherwise.")
            }
        }
    }
}
