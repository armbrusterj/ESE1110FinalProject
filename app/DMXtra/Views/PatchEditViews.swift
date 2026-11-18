import SwiftUI

private let maxNameLength = 31

/// Patch a new fixture: name, type from `/fixture-types`, start address.
struct AddFixtureView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var typeKey = ""
    @State private var address = 1
    @State private var addressEdited = false
    @State private var saving = false
    @State private var error: ControllerError?

    private var selectedType: FixtureType? {
        model.fixtureTypes.first { $0.type == typeKey }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Name", text: $name, prompt: Text("Wash 3"))
                    Picker("Type", selection: $typeKey) {
                        ForEach(model.fixtureTypes) { type in
                            Text("\(type.label) (\(type.channelCount) ch)").tag(type.type)
                        }
                    }
                    NumberField(title: "Start address", value: addressBinding, range: 1...model.universeSize)
                    if let type = selectedType {
                        AddressHint(
                            address: address,
                            type: type,
                            excluding: nil,
                            suggested: model.suggestedAddress(channelCount: type.channelCount),
                            useSuggested: { address = $0; addressEdited = false }
                        )
                    }
                }
                if let error {
                    Section { ErrorText(error: error) }
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Add Fixture")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add", action: save).disabled(!canSave)
                }
            }
            .onAppear {
                if typeKey.isEmpty { typeKey = model.fixtureTypes.first?.type ?? "" }
                if name.isEmpty { name = "Fixture \(model.fixtures.count + 1)" }
                suggestAddress()
            }
            .onChange(of: typeKey) { suggestAddress() }
        }
        #if os(macOS)
        .frame(minWidth: 420, minHeight: 320)
        #endif
    }

    private var addressBinding: Binding<Int> {
        Binding(get: { address }, set: { address = $0; addressEdited = true })
    }

    private var canSave: Bool {
        let n = name.trimmingCharacters(in: .whitespaces)
        return !saving && selectedType != nil && (1...maxNameLength).contains(n.count)
    }

    private func suggestAddress() {
        guard !addressEdited, let type = selectedType,
              let next = model.suggestedAddress(channelCount: type.channelCount) else { return }
        address = next
    }

    private func save() {
        guard let type = selectedType else { return }
        saving = true
        error = nil
        Task {
            defer { saving = false }
            do {
                try await model.addFixture(name: name.trimmingCharacters(in: .whitespaces), type: type.type, address: address)
                dismiss()
            } catch let e as ControllerError {
                error = e
            } catch {}
        }
    }
}

/// Rename or re-address an existing fixture, or delete it.
struct EditFixtureView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let fixture: Fixture

    @State private var name = ""
    @State private var address = 1
    @State private var saving = false
    @State private var confirmingDelete = false
    @State private var error: ControllerError?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Name", text: $name)
                    LabeledContent("Type", value: model.typeLabel(for: fixture))
                    NumberField(title: "Start address", value: $address, range: 1...model.universeSize)
                    AddressHint(
                        address: address,
                        type: FixtureType(type: fixture.type, label: model.typeLabel(for: fixture),
                                          channelCount: fixture.channelCount, channels: fixture.channels),
                        excluding: fixture.id,
                        suggested: nil,
                        useSuggested: { address = $0 }
                    )
                } footer: {
                    Text("Moving a fixture carries its current values with it; the channels it leaves go to 0. To change the type, delete the fixture and add a new one.")
                }
                if let error {
                    Section { ErrorText(error: error) }
                }
                Section {
                    Button("Delete Fixture", role: .destructive) { confirmingDelete = true }
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Edit \(fixture.name)")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save", action: save).disabled(!canSave)
                }
            }
            .confirmationDialog("Delete \(fixture.name)?", isPresented: $confirmingDelete, titleVisibility: .visible) {
                Button("Delete", role: .destructive, action: delete)
            } message: {
                Text("\(fixture.channelsDescription) will be unpatched and set to 0.")
            }
            .onAppear {
                name = fixture.name
                address = fixture.address
            }
        }
        #if os(macOS)
        .frame(minWidth: 420, minHeight: 320)
        #endif
    }

    private var trimmedName: String { name.trimmingCharacters(in: .whitespaces) }

    private var canSave: Bool {
        !saving && (1...maxNameLength).contains(trimmedName.count)
            && (trimmedName != fixture.name || address != fixture.address)
    }

    private func save() {
        saving = true
        error = nil
        let newName = trimmedName == fixture.name ? nil : trimmedName
        let newAddress = address == fixture.address ? nil : address
        Task {
            defer { saving = false }
            do {
                try await model.updateFixture(id: fixture.id, name: newName, address: newAddress)
                dismiss()
            } catch let e as ControllerError {
                error = e
            } catch {}
        }
    }

    private func delete() {
        saving = true
        Task {
            defer { saving = false }
            do {
                try await model.deleteFixture(id: fixture.id)
                dismiss()
            } catch let e as ControllerError {
                error = e
            } catch {}
        }
    }
}

/// "Uses channels 7–9", plus a local warning about overlaps. The server has
/// the final say; this only saves a round trip in the obvious cases.
private struct AddressHint: View {
    @Environment(AppModel.self) private var model
    let address: Int
    let type: FixtureType
    let excluding: Fixture.ID?
    let suggested: Int?
    let useSuggested: (Int) -> Void

    var body: some View {
        let end = address + type.channelCount - 1
        VStack(alignment: .leading, spacing: 4) {
            Text("Uses channels \(PatchMath.rangeLabel(address...max(address, end)))")
                .foregroundStyle(.secondary)
            if !PatchMath.fits(address: address, channelCount: type.channelCount, universeSize: model.universeSize) {
                Label("Doesn't fit in the universe", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
            } else if PatchMath.overlaps(address: address, channelCount: type.channelCount,
                                         fixtures: model.fixtures, excluding: excluding) {
                Label("Overlaps another fixture", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
            }
            let next = suggested ?? model.suggestedAddress(channelCount: type.channelCount, excluding: excluding)
            if let next, next != address {
                Button("Use next free address (\(next))") { useSuggested(next) }
                    .buttonStyle(.borderless)
            }
        }
        .font(.footnote)
    }
}

private struct ErrorText: View {
    let error: ControllerError

    var body: some View {
        Label(error.serverMessage ?? error.localizedDescription, systemImage: "xmark.octagon.fill")
            .foregroundStyle(.red)
    }
}
