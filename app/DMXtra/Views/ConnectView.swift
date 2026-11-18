import SwiftUI

/// Controller address and status.
struct ConnectView: View {
    @Environment(AppModel.self) private var model
    @State private var draft = ""
    @FocusState private var fieldFocused: Bool

    private var draftIsValid: Bool { ControllerAddress.baseURL(from: draft) != nil }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Address", text: $draft, prompt: Text("10.103.210.50 or 127.0.0.1:8080"))
                        .focused($fieldFocused)
                        .autocorrectionDisabled()
                        #if os(iOS)
                        .textInputAutocapitalization(.never)
                        .keyboardType(.URL)
                        #endif
                        .onSubmit(connect)
                        .submitLabel(.go)
                    Button(model.connection == .connecting ? "Connecting…" : "Connect", action: connect)
                        .disabled(!draftIsValid || model.connection == .connecting)
                } header: {
                    Text("Controller address")
                } footer: {
                    Text("IP address or hostname, with an optional port. The controller uses port 80 by default.")
                }

                Section("Status") {
                    statusRows
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Controller")
            .controllerChrome()
            .onAppear { draft = model.addressText }
            .onChange(of: model.addressText) { _, new in
                if !fieldFocused { draft = new }
            }
        }
    }

    @ViewBuilder private var statusRows: some View {
        switch model.connection {
        case .notConfigured:
            Label("Not set up", systemImage: "circle.dashed")
                .foregroundStyle(.secondary)
        case .connecting:
            HStack {
                ProgressView().controlSize(.small)
                Text("Connecting to \(model.addressText)…")
            }
        case .connected(let info):
            Label("Connected", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
            LabeledContent("Name", value: info.name)
            LabeledContent("Firmware", value: info.firmware)
            LabeledContent("Universe", value: "\(info.universeSize) channels")
            LabeledContent("Fixtures", value: "\(info.fixtureCount) of \(info.maxFixtures)")
        case .unreachable(let message):
            Label("Unreachable", systemImage: "xmark.octagon.fill")
                .foregroundStyle(.red)
            Text(message)
                .font(.footnote)
                .foregroundStyle(.secondary)
            Button("Try Again") { Task { await model.reconnect() } }
        }
    }

    private func connect() {
        guard draftIsValid else { return }
        fieldFocused = false
        let address = draft
        Task { await model.connect(to: address) }
    }
}
