//
import SwiftUI

@main
struct GarethVideoCamApp: App {
    @StateObject private var systemExtensionRequestManager = SystemExtensionRequestManager(logText: "")

    var body: some Scene {
        WindowGroup {
            ContentView(systemExtensionRequestManager: systemExtensionRequestManager)
                .frame(minWidth: 860, minHeight: 640)
        }
        .windowResizability(.contentMinSize)
    }
}
