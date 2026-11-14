import FlightCore
import SwiftUI

/// The layer picker: one base layer at a time, then each overlay group with its switches.
struct LayerPicker: View {
    let model: AppModel
    let catalog: LayerCatalog
    var plates: Plates?
    var onShowPlate: (Plate) -> Void = { _ in }
    /// Notices in force or to come that have no area to draw.
    var tfrsWithoutArea: [Tfr] = []
    /// The level drawn now, the pick or the default.
    var windsLevel = WindsMap.defaultLevel
    @AppStorage(StationShow.key) private var stationShow = StationShow.category
    @AppStorage(WindsMap.levelKey) private var chosenWindsLevel = 0

    var body: some View {
        Form {
            if let plates, !plates.onMap.isEmpty { placed(plates) }
            section(LayerMenu.aeronautical)
            ForEach(LayerMenu.bases.indices, id: \.self) { i in
                Section {
                    ForEach(LayerMenu.bases[i], id: \.self) { layer in
                        check(layer.title, on: model.baseLayer == layer) { model.baseLayer = layer }
                            .accessibilityIdentifier("base-\(layer.rawValue)")
                    }
                } header: {
                    if i == 0 { Text("Base") }
                }
            }
            ForEach(LayerMenu.overlays.indices, id: \.self) { section(LayerMenu.overlays[$0]) }
        }
        .panelList()
        .accessibilityIdentifier("layer-picker")
    }

    /// Plates placed on the map: a tap flies there, a swipe takes one off.
    private func placed(_ plates: Plates) -> some View {
        Section {
            ForEach(plates.onMap) { plate in
                Button { onShowPlate(plate) } label: {
                    VStack(alignment: .leading) {
                        Text(plate.name).foregroundStyle(.primary)
                        Text(plate.icao).font(.subheadline).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(.rect)
                }
                .accessibilityIdentifier("on-map-\(plate.file)")
            }
            .onDelete { plates.onMap.remove(atOffsets: $0) }
            Button(LayerMenu.removeAll, role: .destructive) { plates.onMap.removeAll() }
                .accessibilityIdentifier("on-map-remove-all")
        } header: {
            Text(LayerMenu.onMap)
        }
    }

    private func section(_ section: LayerMenu.Section) -> some View {
        Section {
            ForEach(section.rows.indices, id: \.self) { i in
                switch section.rows[i] {
                case .overlay(let id): if let overlay = catalog.overlay(id) { row(overlay) }
                case .station(let show): stationRow(show)
                }
            }
        } header: {
            if let title = section.title { Text(title) }
        }
    }

    /// One readout of the station dots: picking it shows the dots, picking it again hides them.
    private func stationRow(_ show: StationShow) -> some View {
        let id = WeatherSwitches.stationsID
        let on = catalog.overlay(id)?.isOn == true && stationShow == show
        return check(show.title, on: on) {
            stationShow = show
            catalog.setOverlay(id, on: !on)
        }
        .accessibilityIdentifier("station-\(show.rawValue)")
    }

    private func check(_ title: String, on: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                Text(title).foregroundStyle(.primary)
                Spacer()
                if on { Image(systemName: "checkmark").foregroundStyle(Color.accentColor) }
            }
            .contentShape(.rect)
        }
        .tint(.primary)
        .accessibilityAddTraits(on ? .isSelected : [])
    }

    @ViewBuilder private func row(_ overlay: OverlayLayer) -> some View {
        Toggle(overlay.title, isOn: Binding(
            get: { catalog.overlay(overlay.id)?.isOn ?? false },
            set: { catalog.setOverlay(overlay.id, on: $0) }))
            .accessibilityIdentifier("overlay-\(overlay.id)")
        if overlay.isImage, overlay.isOn {
            Slider(value: Binding(
                get: { catalog.overlay(overlay.id)?.opacity ?? 1 },
                set: { catalog.setOpacity(overlay.id, to: $0) }), in: 0...1)
                .accessibilityIdentifier("opacity-\(overlay.id)")
        }
        if overlay.id == WindsMap.switchID, overlay.isOn {
            Picker(WindsMap.levelTitle, selection: Binding(get: { windsLevel }, set: { chosenWindsLevel = $0 })) {
                ForEach(WindsMap.levels, id: \.self) { Text(WindsMap.title($0)).tag($0) }
            }
            .accessibilityIdentifier("winds-level")
        }
        if overlay.id == WeatherSwitches.tfrsID, overlay.isOn, !tfrsWithoutArea.isEmpty {
            NavigationLink("\(tfrsWithoutArea.count) not drawn on the map") { tfrList }
                .accessibilityIdentifier("tfrs-without-area")
        }
    }

    private var tfrList: some View {
        List(tfrsWithoutArea, id: \.notam) { tfr in
            VStack(alignment: .leading) {
                Text("TFR \(tfr.notam)").font(.headline)
                if let title = tfr.title ?? tfr.name { Text(title).font(.subheadline) }
                Text(tfr.unreadable ? Tfr.unreadableNote : "\(tfr.lower?.text ?? "?") to \(tfr.upper?.text ?? "?")")
                    .font(.subheadline).foregroundStyle(.secondary)
            }
        }
        .navigationTitle(Tfr.listTitle)
        .panelList()
    }
}
