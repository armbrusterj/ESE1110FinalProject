import SwiftUI

@main
struct DMXtraApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
        }
        #if os(macOS)
        .defaultSize(width: 900, height: 700)
        #endif
    }
}
