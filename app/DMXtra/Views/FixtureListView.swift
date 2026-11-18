import SwiftUI

/// The patch: every fixture, with add / edit / delete.
struct FixtureListView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.scenePhase) private var scenePhase
    let showController: () -> Void

    @State private var showingAdd = false
    @State private var editing: Fixture?
    @State private var pendingDelete: Fixture?
    @State private var deleteError: ControllerError?

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("Fixtures")
                .navigationDestination(for: Fixture.ID.self) { id in
                    FixtureControlView(fixtureID: id)
                }
                .toolbar {
                    ToolbarItem(placement: .automatic) {
                        Button { showingAdd = true } label: { Label("Add Fixture", systemImage: "plus") }
                            .disabled(!model.connection.isConnected || model.fixtureTypes.isEmpty)
                    }
                }
                .controllerChrome()
                .sheet(isPresented: $showingAdd) { AddFixtureView() }
                .sheet(item: $editing) { EditFixtureView(fixture: $0) }
                .alert(
                    "Couldn't delete fixture",
                    isPresented: Binding(get: { deleteError != nil }, set: { if !$0 { deleteError = nil } }),
                    presenting: deleteError
                ) { _ in
                    Button("OK", role: .cancel) {}
                } message: { Text($0.serverMessage ?? $0.localizedDescription) }
                .task(id: scenePhase) {
                    guard scenePhase == .active else { return }
                    await model.pollWhileVisible()
                }
        }
    }

    @ViewBuilder private var content: some View {
        if model.fixtures.isEmpty && !model.connection.isConnected {
            NotConnectedView(showController: showController)
        } else {
            List {
                Section {
                    ConnectionStatusView()
                }
                Section {
                    if model.fixtures.isEmpty {
                        Text("No fixtures patched. Tap + to add one.")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(model.fixtures) { fixture in
                        NavigationLink(value: fixture.id) {
                            FixtureRow(fixture: fixture, typeLabel: model.typeLabel(for: fixture))
                        }
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            Button { pendingDelete = fixture } label: { Label("Delete", systemImage: "trash") }
                                .tint(.red)
                            Button { editing = fixture } label: { Label("Edit", systemImage: "pencil") }
                                .tint(.blue)
                        }
                        .contextMenu {
                            Button { editing = fixture } label: { Label("Edit…", systemImage: "pencil") }
                            Button(role: .destructive) { pendingDelete = fixture } label: {
                                Label("Delete…", systemImage: "trash")
                            }
                        }
                        // Attached to the row so the confirmation is anchored to it.
                        .confirmationDialog(
                            "Delete \(fixture.name)?",
                            isPresented: Binding(
                                get: { pendingDelete?.id == fixture.id },
                                set: { if !$0 { pendingDelete = nil } }
                            ),
                            titleVisibility: .visible
                        ) {
                            Button("Delete", role: .destructive) { delete(fixture) }
                        } message: {
                            Text("\(fixture.channelsDescription) will be unpatched and set to 0.")
                        }
                    }
                } header: {
                    if let info = model.info {
                        Text("Patch · \(model.fixtures.count) of \(info.maxFixtures)")
                    } else {
                        Text("Patch")
                    }
                }
            }
            .refreshable { await model.refreshFixtures() }
        }
    }

    private func delete(_ fixture: Fixture) {
        Task {
            do {
                try await model.deleteFixture(id: fixture.id)
            } catch let error as ControllerError {
                deleteError = error
            } catch {}
        }
    }
}

struct FixtureRow: View {
    let fixture: Fixture
    let typeLabel: String

    var body: some View {
        HStack(spacing: 12) {
            if let color = fixture.previewColor {
                ColorSwatch(color: color)
            } else {
                // Keep names aligned; show intensity for non-color fixtures.
                let level = Double(fixture.values.max() ?? 0) / 255
                ColorSwatch(color: Color(white: level))
                    .opacity(fixture.values.isEmpty ? 0 : 1)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(fixture.name)
                    .font(.headline)
                Text("\(typeLabel) · \(fixture.addressLabel)")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }
}
