import SwiftUI

/// Faders (and a color picker for color fixtures) for one fixture.
struct FixtureControlView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.self) private var environment
    let fixtureID: Fixture.ID

    @State private var editing: Fixture?

    var body: some View {
        Group {
            if let fixture = model.fixture(id: fixtureID) {
                controls(for: fixture)
            } else {
                ContentUnavailableView(
                    "Fixture removed",
                    systemImage: "questionmark.square.dashed",
                    description: Text("This fixture is no longer in the patch.")
                )
            }
        }
        .controllerChrome()
        .sheet(item: $editing) { EditFixtureView(fixture: $0) }
        .task(id: scenePhase) {
            guard scenePhase == .active else { return }
            await model.pollWhileVisible()
        }
    }

    private func controls(for fixture: Fixture) -> some View {
        Form {
            Section {
                LabeledContent("Type", value: model.typeLabel(for: fixture))
                LabeledContent("Channels", value: fixture.addressLabel)
            }

            if fixture.isColorFixture {
                Section("Color") {
                    HStack {
                        ColorPicker("Color", selection: colorBinding(for: fixture), supportsOpacity: false)
                        if let preview = fixture.previewColor {
                            ColorSwatch(color: preview, size: 32)
                        }
                    }
                }
            }

            Section("Channels") {
                ForEach(Array(fixture.channels.enumerated()), id: \.offset) { index, name in
                    ChannelFader(
                        name: name,
                        channel: fixture.address + index,
                        value: valueBinding(fixture: fixture, index: index),
                        onEditingChanged: { model.setEditing($0, fixtureID: fixture.id) }
                    )
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle(fixture.name)
        .toolbar {
            ToolbarItem(placement: .automatic) {
                Button("Edit") { editing = fixture }
            }
        }
    }

    private func valueBinding(fixture: Fixture, index: Int) -> Binding<Double> {
        Binding(
            get: {
                let f = model.fixture(id: fixture.id) ?? fixture
                return Double(f.values.indices.contains(index) ? f.values[index] : 0)
            },
            set: { model.setValue(Int($0.rounded()), channel: index, fixtureID: fixture.id) }
        )
    }

    /// Two-way bridge between the color picker and the red/green/blue faders.
    private func colorBinding(for fixture: Fixture) -> Binding<Color> {
        Binding(
            get: {
                guard let f = model.fixture(id: fixture.id), let rgb = f.rgbChannelIndices else { return .black }
                return Color(dmxRed: f.values[rgb.red], green: f.values[rgb.green], blue: f.values[rgb.blue])
            },
            set: { color in
                let c = color.dmxComponents(in: environment)
                model.setColor(red: c.red, green: c.green, blue: c.blue, fixtureID: fixture.id)
            }
        )
    }
}

struct ChannelFader: View {
    let name: String
    let channel: Int
    @Binding var value: Double
    let onEditingChanged: (Bool) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(name.capitalized)
                    .font(.body.weight(.medium))
                Text("ch \(channel)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Text("\(Int(value))")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            Slider(value: $value, in: 0...255) {
                Text(name.capitalized)
            } minimumValueLabel: {
                Text("0").font(.caption2)
            } maximumValueLabel: {
                Text("255").font(.caption2)
            } onEditingChanged: { onEditingChanged($0) }
            .tint(Color.channelTint(name))
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(name.capitalized), channel \(channel)")
        .accessibilityValue("\(Int(value))")
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: value = min(255, value + 5)
            case .decrement: value = max(0, value - 5)
            @unknown default: break
            }
        }
    }
}
