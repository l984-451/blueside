import FlightCore
import SwiftUI

/// One region in the download list, with its size, its state and the action that fits the state.
struct PackRow: View {
    let row: RegionRow
    let onDownload: () -> Void
    let onRetry: () -> Void
    let onRemove: () -> Void
    var waiting = false
    /// Keeps identifiers apart when two lists show the same states.
    var tag = ""

    var body: some View {
        HStack {
            VStack(alignment: .leading) {
                Text(DownloadPolicy.regionName(row.id)).font(.headline)
                Text(DownloadPolicy.byteCount(Int64(row.bytes))).detail()
                Self.stateLine(row.state, effective: row.effective, waiting: waiting, identifier: "state-\(tag)\(row.id)")
            }
            Spacer()
            Self.action(row.state, effective: row.effective, identifier: { "\($0)-\(tag)\(row.id)" },
                        onDownload: onDownload, onRetry: onRetry)
        }
        .swipeActions {
            if Self.removable(row.state) {
                Button("Remove", role: .destructive, action: onRemove).accessibilityIdentifier("remove-\(tag)\(row.id)")
            }
        }
        .contextMenu {
            if Self.removable(row.state) { Button("Remove", role: .destructive, action: onRemove) }
        }
    }

    private static func removable(_ state: PackState) -> Bool {
        switch state {
        case .ready, .expired: true
        default: false
        }
    }

    /// The state in words: failed in red, expired in amber, the rest secondary.
    @ViewBuilder static func stateLine(_ state: PackState, effective: Date?, waiting: Bool,
                                       identifier: String) -> some View {
        let text = DownloadPolicy.statusText(state, effective: effective, waiting: waiting)
        switch state {
        case .failed:
            StateWord(.danger, text, systemImage: "xmark.octagon.fill").accessibilityIdentifier(identifier)
        case .expired where effective == nil:
            StateWord(.warning, text, systemImage: "exclamationmark.triangle.fill").accessibilityIdentifier(identifier)
        default:
            Text(text).detail().monospacedDigit().accessibilityIdentifier(identifier)
        }
    }

    /// Download, a ring while downloading, a check when on disk, Update when expired, or Retry, all in one
    /// 44 point slot so the control never moves. `identifier` turns "download", "retry", "update", "done" into an id.
    static func action(_ state: PackState, effective: Date?, identifier: @escaping (String) -> String,
                       onDownload: @escaping () -> Void, onRetry: @escaping () -> Void) -> some View {
        Group {
            switch state {
            case .notDownloaded:
                slotButton("arrow.down.circle", "Download", identifier("download"), onDownload)
            case .failed:
                slotButton("arrow.clockwise.circle", "Retry", identifier("retry"), onRetry)
            case .expired where effective == nil:
                slotButton("arrow.down.circle", "Update", identifier("update"), onRetry)
            case .downloading(let progress):
                ProgressRing(progress: progress)
            case .ready, .expired:
                Image(systemName: "checkmark.circle.fill").imageScale(.large).foregroundStyle(.green)
                    .accessibilityLabel("Downloaded")
                    .accessibilityIdentifier(identifier("done"))
            }
        }
        .frame(width: 44, height: 44) // design-lint: allow 44 pt target shared by every state
    }

    private static func slotButton(_ symbol: String, _ label: String, _ identifier: String,
                                   _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).imageScale(.large)
                .frame(maxWidth: .infinity, maxHeight: .infinity).contentShape(.rect)
        }
        .buttonStyle(.borderless)
        .accessibilityLabel(label)
        .accessibilityIdentifier(identifier)
    }
}

/// A determinate ring the size of the download symbol, filling clockwise from the top, as in the App Store.
struct ProgressRing: View {
    let progress: Double

    var body: some View {
        ZStack {
            Circle().stroke(.quaternary, lineWidth: 2.5)
            Circle().trim(from: 0, to: max(progress, 0.02))
                .stroke(.tint, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .frame(width: 22, height: 22) // design-lint: allow matches arrow.down.circle at large scale
        .accessibilityElement()
        .accessibilityLabel("Downloading")
        .accessibilityValue("\(Int((progress * 100).rounded())) percent")
    }
}
