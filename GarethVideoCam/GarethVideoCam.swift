//
import SwiftUI

@main
struct GarethVideoCamApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView(systemExtensionRequestManager: SystemExtensionRequestManager(logText: ""))
                .frame(minWidth: 1200, minHeight: 980)
        }
    }
}
