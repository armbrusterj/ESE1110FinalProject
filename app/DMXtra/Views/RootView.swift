import SwiftUI

enum AppTab: Hashable {
    case fixtures, universe, controller
}

struct RootView: View {
    @Environment(AppModel.self) private var model
    @State private var tab: AppTab = .fixtures

    var body: some View {
        TabView(selection: $tab) {
            FixtureListView(showController: { tab = .controller })
                .tabItem { Label("Fixtures", systemImage: "slider.horizontal.3") }
                .tag(AppTab.fixtures)
            UniverseView(showController: { tab = .controller })
                .tabItem { Label("Universe", systemImage: "square.grid.4x3.fill") }
                .tag(AppTab.universe)
            ConnectView()
                .tabItem { Label("Controller", systemImage: "antenna.radiowaves.left.and.right") }
                .tag(AppTab.controller)
        }
        .controllerErrorAlert(model)
        .task {
            #if DEBUG
            // Debug builds: `-DMXtraTab universe|controller` opens on that tab (for screenshots).
            switch UserDefaults.standard.string(forKey: "DMXtraTab") {
            case "universe": tab = .universe
            case "controller": tab = .controller
            default: break
            }
            #endif
            if model.addressText.isEmpty {
                tab = .controller
            } else {
                await model.connectToSavedAddress()
            }
        }
    }
}

/// Shown in place of a screen's content when there's no controller to talk to.
struct NotConnectedView: View {
    @Environment(AppModel.self) private var model
    let showController: () -> Void

    var body: some View {
        ContentUnavailableView {
            switch model.connection {
            case .connecting:
                Label("Connecting…", systemImage: "antenna.radiowaves.left.and.right")
            case .unreachable:
                Label("Controller unreachable", systemImage: "wifi.exclamationmark")
            default:
                Label("No controller", systemImage: "antenna.radiowaves.left.and.right.slash")
            }
        } description: {
            switch model.connection {
            case .unreachable(let message): Text(message)
            case .connecting: Text(model.addressText)
            default: Text("Enter the controller's address to get started.")
            }
        } actions: {
            if case .unreachable = model.connection {
                Button("Try Again") { Task { await model.reconnect() } }
                    .buttonStyle(.borderedProminent)
            }
            Button("Controller Settings", action: showController)
        }
    }
}
