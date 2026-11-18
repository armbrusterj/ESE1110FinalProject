import SwiftUI

/// All channels of the universe, shaded by the fixture that owns them.
struct UniverseView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.scenePhase) private var scenePhase
    let showController: () -> Void

    @State private var selectedChannel: ChannelSelection?

    var body: some View {
        NavigationStack {
            Group {
                if !model.connection.isConnected && model.fixtures.isEmpty {
                    NotConnectedView(showController: showController)
                } else {
                    grid
                }
            }
            .navigationTitle("Universe")
            .controllerChrome()
            .sheet(item: $selectedChannel) { ChannelValueSheet(channel: $0.channel) }
            .task(id: scenePhase) {
                guard scenePhase == .active else { return }
                await model.pollWhileVisible(includeUniverse: true)
            }
        }
    }

    private var grid: some View {
        let owners = PatchMath.ownerMap(model.fixtures)
        let tints = patchTints
        return ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                ConnectionStatusView()
                legend
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 54), spacing: 4)], spacing: 4) {
                    ForEach(1...model.universeSize, id: \.self) { channel in
                        let value = model.universe.indices.contains(channel - 1) ? model.universe[channel - 1] : 0
                        Button {
                            selectedChannel = ChannelSelection(channel: channel)
                        } label: {
                            ChannelCell(channel: channel, value: value, owner: owners[channel],
                                        tint: owners[channel].flatMap { tints[$0.id] })
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .padding()
        }
        .refreshable {
            await model.refreshFixtures()
            await model.refreshUniverse()
        }
    }

    /// One color per fixture, by position in the patch.
    private var patchTints: [Fixture.ID: Color] {
        Dictionary(uniqueKeysWithValues: model.fixtures.enumerated().map { ($1.id, Color.patchColor(index: $0)) })
    }

    @ViewBuilder private var legend: some View {
        if !model.fixtures.isEmpty {
            let tints = patchTints
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(model.fixtures) { f in
                        HStack(spacing: 6) {
                            RoundedRectangle(cornerRadius: 3)
                                .fill(tints[f.id] ?? .gray)
                                .frame(width: 14, height: 14)
                            Text(f.name).font(.caption.weight(.semibold))
                            Text(f.addressLabel).font(.caption).foregroundStyle(.secondary).monospacedDigit()
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background((tints[f.id] ?? .gray).opacity(0.15), in: Capsule())
                    }
                }
            }
        }
    }
}

private struct ChannelSelection: Identifiable {
    let channel: Int
    var id: Int { channel }
}

private struct ChannelCell: View {
    let channel: Int
    let value: Int
    let owner: Fixture?
    let tint: Color?

    var body: some View {
        let isFirst = owner?.address == channel
        let channelName = owner.map { $0.channels[channel - $0.address] }
        VStack(spacing: 1) {
            HStack {
                Text("\(channel)")
                    .font(.system(size: 9).monospacedDigit())
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
            }
            Text("\(value)")
                .font(.system(size: 15, weight: value > 0 ? .bold : .regular).monospacedDigit())
                .foregroundStyle(value > 0 ? .primary : .secondary)
            Text(isFirst ? owner!.name : (channelName.map { String($0.prefix(3)) } ?? " "))
                .font(.system(size: 8, weight: isFirst ? .bold : .regular))
                .lineLimit(1)
                .truncationMode(.tail)
                .foregroundStyle(.secondary)
        }
        .padding(3)
        .frame(minWidth: 54, minHeight: 50)
        .background(background, in: RoundedRectangle(cornerRadius: 5))
        .overlay(alignment: .bottom) {
            // Level bar along the bottom edge.
            GeometryReader { geo in
                Rectangle()
                    .fill(tint ?? .accentColor)
                    .frame(width: geo.size.width * CGFloat(value) / 255, height: 3)
                    .frame(maxHeight: .infinity, alignment: .bottom)
            }
            .clipShape(RoundedRectangle(cornerRadius: 5))
        }
        .overlay {
            if isFirst {
                RoundedRectangle(cornerRadius: 5)
                    .strokeBorder(tint ?? .accentColor, lineWidth: 1.5)
            }
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText(channelName: channelName))
        .accessibilityValue("\(value)")
        .accessibilityAddTraits(.isButton)
    }

    private var background: Color {
        if owner != nil, let tint { return tint.opacity(0.28) }
        return Color.secondary.opacity(0.08)
    }

    private func accessibilityText(channelName: String?) -> String {
        if let owner, let channelName { return "Channel \(channel), \(owner.name) \(channelName)" }
        return "Channel \(channel), unpatched"
    }
}

/// Set one raw channel with `POST /dmx`.
private struct ChannelValueSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let channel: Int

    @State private var value = 0
    @State private var saving = false
    @State private var error: ControllerError?

    var body: some View {
        let owner = model.fixtures.first { $0.channelRange.contains(channel) }
        NavigationStack {
            Form {
                Section {
                    if let owner {
                        LabeledContent("Fixture", value: owner.name)
                        LabeledContent("Function", value: owner.channels[channel - owner.address].capitalized)
                    } else {
                        LabeledContent("Fixture", value: "Unpatched")
                    }
                    LabeledContent("Current value", value: "\(currentValue)")
                }
                Section("New value") {
                    NumberField(title: "Value", value: $value, range: 0...255)
                    Slider(value: Binding(get: { Double(value) }, set: { value = Int($0.rounded()) }), in: 0...255)
                    HStack {
                        ForEach([0, 64, 128, 191, 255], id: \.self) { preset in
                            Button("\(preset)") { value = preset }
                                .buttonStyle(.bordered)
                                .frame(maxWidth: .infinity)
                        }
                    }
                }
                if let error {
                    Section {
                        Label(error.serverMessage ?? error.localizedDescription, systemImage: "xmark.octagon.fill")
                            .foregroundStyle(.red)
                    }
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Channel \(channel)")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Set", action: save).disabled(saving || !(0...255).contains(value))
                }
            }
            .onAppear { value = currentValue }
        }
        #if os(macOS)
        .frame(minWidth: 380, minHeight: 340)
        #endif
    }

    private var currentValue: Int {
        model.universe.indices.contains(channel - 1) ? model.universe[channel - 1] : 0
    }

    private func save() {
        saving = true
        error = nil
        Task {
            defer { saving = false }
            do {
                try await model.setChannel(channel, to: value)
                dismiss()
            } catch let e as ControllerError {
                error = e
            } catch {}
        }
    }
}
