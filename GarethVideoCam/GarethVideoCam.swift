//
import SwiftUI

@main
struct GarethVideoCamApp: App {
    @StateObject private var systemExtensionRequestManager = SystemExtensionRequestManager(logText: "")

    var body: some Scene {
        WindowGroup {
            ContentView(systemExtensionRequestManager: systemExtensionRequestManager)
                .frame(minWidth: 720, minHeight: 560)
        }
        .windowResizability(.contentMinSize)
    }
}
