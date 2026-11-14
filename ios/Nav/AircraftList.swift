import CoreTransferable
import FlightCore
import SwiftUI
import UniformTypeIdentifiers

/// Settings, Aircraft: the saved aircraft and adding from a template, blank or a file.
struct AircraftList: View {
    @Bindable var store: AircraftStore
    @State private var adding: AircraftProfile?
    @State private var picking = false
    @State private var picked: AircraftProfile?
    @State private var importing = false
    @State private var conflict: AircraftProfile?
    @State private var importProblems: [String] = []

    var body: some View {
        Form {
            Section {
                ForEach(store.list) { profile in
                    NavigationLink {
                        AircraftEditor(store: store, draft: profile, isNew: false)
                    } label: {
                        VStack(alignment: .leading) {
                            Text(AircraftPages.displayName(profile))
                            let summary = AircraftPages.summary(profile)
                            if !summary.isEmpty { Text(summary).detail() }
                        }
                    }
                    .accessibilityIdentifier("aircraft-row-\(AircraftPages.displayName(profile))")
                }
                .onDelete { $0.map { store.list[$0].id }.forEach(store.delete) }
            }
        }
        .overlay {
            if store.list.isEmpty {
                ContentUnavailableView(AircraftPages.title, systemImage: "airplane",
                                       description: Text(AircraftPages.empty))
            }
        }
        .toolbar {
            // Trailing sits left of the close button, which holds the primary action spot.
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button(AircraftPages.template, systemImage: "airplane") { picking = true }
                    Button(AircraftPages.blank, systemImage: "doc") { adding = AircraftProfile(tail: "") }
                    Divider()
                    Button(AircraftPages.importFile, systemImage: "square.and.arrow.down") { importing = true }
                } label: {
                    Label(AircraftPages.add, systemImage: "plus")
                }
                .accessibilityIdentifier("aircraft-add")
            }
        }
        .navigationDestination(item: Binding(get: { adding.map(Draft.init) }, set: { adding = $0?.profile })) { draft in
            AircraftEditor(store: store, draft: draft.profile, isNew: true)
        }
        // Pushes the editor once the sheet is gone, so the push is not lost to the dismissal.
        .sheet(isPresented: $picking, onDismiss: { adding = picked; picked = nil }) {
            TemplatePicker { picked = $0; picking = false }
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.json]) { result in
            guard let url = try? result.get() else { return }
            let opened = url.startAccessingSecurityScopedResource()
            defer { if opened { url.stopAccessingSecurityScopedResource() } }
            guard let data = try? Data(contentsOf: url) else { return }
            switch store.importFile(data) {
            case .added: break
            case .conflict(let profile): conflict = profile
            case .problems(let problems): importProblems = problems
            }
        }
        .confirmationDialog(AircraftPages.conflict,
                            isPresented: Binding(get: { conflict != nil }, set: { if !$0 { conflict = nil } }),
                            titleVisibility: .visible, presenting: conflict) { profile in
            Button(AircraftProfile.replace) { store.add(profile, replace: true) }
            Button(AircraftProfile.keepBoth) { store.add(profile, replace: false) }
        }
        .alert(AircraftPages.importFailed, isPresented: Binding(get: { !importProblems.isEmpty },
                                                               set: { if !$0 { importProblems = [] } })) {
        } message: {
            Text(importProblems.joined(separator: "\n"))
        }
    }

    /// A pushed new aircraft, keyed by its id so the push survives edits.
    private struct Draft: Hashable {
        let profile: AircraftProfile
        static func == (a: Draft, b: Draft) -> Bool { a.profile.id == b.profile.id }
        func hash(into hasher: inout Hasher) { hasher.combine(profile.id) }
    }
}

/// The templates, searchable by make and model.
private struct TemplatePicker: View {
    let pick: (AircraftProfile) -> Void
    @State private var query = ""
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List(AircraftTemplates.all.filter { $0.matches(query) }, id: \.title) { template in
                Button { pick(template.profile) } label: {
                    VStack(alignment: .leading) {
                        Text(template.title).foregroundStyle(.primary)
                        if let source = template.profile.source { Text(source).detail() }
                    }
                }
                .accessibilityIdentifier("template-\(template.profile.type ?? "")")
            }
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always),
                        prompt: AircraftPages.searchTemplates)
            .navigationTitle(AircraftPages.template)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button(role: .close) { dismiss() } } }
        }
    }
}

/// One aircraft's fields. Save keeps it when the core finds nothing wrong.
struct AircraftEditor: View {
    let store: AircraftStore
    @State var draft: AircraftProfile
    let isNew: Bool
    @State private var problems: [String] = []
    @State private var attaching = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Form {
            if !problems.isEmpty {
                Section {
                    ForEach(problems, id: \.self) { StateWord(.danger, $0, systemImage: "xmark.octagon.fill") }
                }
            }
            ForEach(Array(AircraftPages.sections.enumerated()), id: \.offset) { index, section in
                Section {
                    ForEach(section.fields, id: \.key) { field($0) }
                } header: {
                    if index > 0 { Text(section.title) }
                } footer: {
                    if index == 0, let source = draft.source { Text(source + ". " + AircraftProfile.fillInNote) }
                    if section.fields.contains(where: { $0.key == "cruiseTASKt" }) { Text(AircraftPages.performanceNote) }
                }
            }
            stations
            envelope
            Section {
                NavigationLink(AircraftPages.weightBalance) { WeightBalancePage(store: store, profile: draft) }
                    .accessibilityIdentifier("aircraft-weight-balance")
            }
            if !isNew { poh }
            if !isNew {
                Section {
                    Button(AircraftPages.delete, role: .destructive) {
                        store.delete(draft.id)
                        dismiss()
                    }
                }
            }
        }
        // On the form, not the section: a file importer inside a list row never presents.
        .fileImporter(isPresented: $attaching, allowedContentTypes: [.pdf]) { result in
            guard let url = try? result.get() else { return }
            Task { _ = await store.attachPOH(url, to: draft.id) }
        }
        .navigationTitle(isNew ? AircraftPages.newTitle : AircraftPages.displayName(draft))
        .toolbar {
            if !isNew, let file = try? draft.exported() {
                ToolbarItem(placement: .secondaryAction) {
                    ShareLink(item: AircraftFile(name: file.fileName, data: file.data),
                              preview: SharePreview(file.fileName)) {
                        Label(AircraftPages.export, systemImage: "square.and.arrow.up")
                    }
                }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button(AircraftPages.save) {
                    problems = store.save(draft)
                    if problems.isEmpty { dismiss() }
                }
                .accessibilityIdentifier("aircraft-save")
            }
        }
    }

    // The core lists the fields by JSON key; these say which profile value each one edits.
    private static let numbers: [String: WritableKeyPath<AircraftProfile, Double?>] = [
        "cruiseTASKt": \.cruiseTASKt, "burnGPH": \.burnGPH, "usableFuelGal": \.usableFuelGal, "fuelArmIn": \.fuelArmIn,
        "emptyWeightLb": \.emptyWeightLb, "emptyArmIn": \.emptyArmIn, "maxRampLb": \.maxRampLb,
        "maxTakeoffLb": \.maxTakeoffLb, "maxLandingLb": \.maxLandingLb, "maxZeroFuelLb": \.maxZeroFuelLb,
        "climbRateFPM": \.climbRateFPM, "climbTASKt": \.climbTASKt, "climbBurnGPH": \.climbBurnGPH,
        "descentRateFPM": \.descentRateFPM, "descentTASKt": \.descentTASKt, "descentBurnGPH": \.descentBurnGPH,
        "vneKt": \.vneKt, "vnoKt": \.vnoKt, "vaKt": \.vaKt, "vfeKt": \.vfeKt,
    ]
    private static let texts: [String: WritableKeyPath<AircraftProfile, String?>] = ["type": \.type, "engine": \.engine]
    private static let requiredNumbers: [String: WritableKeyPath<AircraftProfile, Double>] = [
        "taxiFuelGal": \.taxiFuelGal, "fuelLbPerGal": \.fuelLbPerGal,
    ]

    @ViewBuilder private func field(_ f: AircraftPages.Field) -> some View {
        let id = "aircraft-\(f.key)"
        if let path = Self.numbers[f.key] {
            NumberRow((f.title, f.unit ?? ""), $draft[dynamicMember: path], id)
        } else if let path = Self.requiredNumbers[f.key] {
            NumberRow((f.title, f.unit ?? ""), required($draft[dynamicMember: path]), id)
        } else if f.key == "tail" {
            TextField(f.title, text: $draft.tail, prompt: Text(AircraftPages.tailPrompt))
                .textInputAutocapitalization(.characters)
                .autocorrectionDisabled()
                .font(.headline)
                .accessibilityIdentifier(id)
        } else if let path = Self.texts[f.key] {
            LabeledContent(f.title) {
                TextField(f.title, text: Binding(get: { draft[keyPath: path] ?? "" }, set: { draft[keyPath: path] = $0.isEmpty ? nil : $0 }))
                    .multilineTextAlignment(.trailing)
                    .autocorrectionDisabled()
                    .accessibilityIdentifier(id)
            }
        }
    }

    // The pilot's own POH, kept on the device. Only for a saved aircraft, so a cancelled one leaves no file behind.
    private var poh: some View {
        Section {
            if let url = store.poh(draft.id) {
                NavigationLink(AircraftPages.poh) { PlatePage(title: AircraftPages.poh, url: url) }
                    .accessibilityIdentifier("aircraft-poh")
                Button(AircraftPages.replacePOH) { attaching = true }
                Button(AircraftPages.removePOH, role: .destructive) { store.removePOH(draft.id) }
            } else {
                Button(AircraftPages.attachPOH, systemImage: "paperclip") { attaching = true }
                    .accessibilityIdentifier("aircraft-attach-poh")
            }
        } footer: {
            Text(AircraftPages.pohNote)
        }
    }

    private var stations: some View {
        Section {
            ForEach(draft.stations.indices, id: \.self) { i in
                VStack(alignment: .leading) {
                    TextField(AircraftPages.name, text: $draft.stations[i].name)
                    HStack {
                        NumberRow((AircraftPages.arm, AircraftPages.inches), $draft.stations[i].armIn, "aircraft-station-arm-\(i)")
                            .padding(.trailing)
                        NumberRow((AircraftPages.limit, AircraftPages.lb), $draft.stations[i].maxLb)
                    }
                    .font(.subheadline)
                    if draft.stations[i].armIn == nil, let hint = draft.stations[i].hint { Text(hint).note() }
                }
            }
            .onDelete { draft.stations.remove(atOffsets: $0) }
            Button(AircraftPages.addStation, systemImage: "plus") {
                draft.stations.append(.init(name: AircraftPages.station))
            }
        } header: {
            Text(AircraftPages.stationsTitle)
        }
    }

    private var envelope: some View {
        Section {
            ForEach(draft.envelope.indices, id: \.self) { i in
                HStack {
                    NumberRow((AircraftPages.arm, AircraftPages.inches), required($draft.envelope[i].armIn))
                        .padding(.trailing)
                    NumberRow((AircraftPages.weight, AircraftPages.lb), required($draft.envelope[i].weightLb))
                }
            }
            .onDelete { draft.envelope.remove(atOffsets: $0) }
            Button(AircraftPages.addPoint, systemImage: "plus") {
                draft.envelope.append(draft.envelope.last ?? .init(armIn: 0, weightLb: 0))
            }
        } header: {
            Text(AircraftPages.envelopeTitle)
        } footer: {
            Text(AircraftPages.envelopeNote)
        }
    }

    private func required(_ value: Binding<Double>) -> Binding<Double?> {
        Binding(get: { value.wrappedValue }, set: { value.wrappedValue = $0 ?? 0 })
    }
}

/// A title, a number field and its unit on one row.
struct NumberRow: View {
    let title: String
    let unit: String
    @Binding var value: Double?
    var identifier: String?

    init(_ field: (String, String), _ value: Binding<Double?>, _ identifier: String? = nil) {
        (title, unit) = field
        _value = value
        self.identifier = identifier
    }

    var body: some View {
        LabeledContent(title) {
            HStack {
                TextField(title, value: $value, format: .number, prompt: Text(NavText.dashes))
                    .keyboardType(.numbersAndPunctuation)
                    .multilineTextAlignment(.trailing)
                    .monospacedDigit()
                    .accessibilityIdentifier(identifier ?? "")
                if !unit.isEmpty { Text(unit).foregroundStyle(.secondary) }
            }
        }
    }
}

/// One aircraft as a shared .json file.
struct AircraftFile: Transferable {
    let name: String
    let data: Data

    static var transferRepresentation: some TransferRepresentation {
        DataRepresentation(exportedContentType: .json) { $0.data }
            .suggestedFileName { $0.name }
    }
}
