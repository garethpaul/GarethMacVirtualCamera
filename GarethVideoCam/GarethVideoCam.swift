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
        .commands {
            CommandMenu("Camera") {
                Button("Install Camera Extension") {
                    systemExtensionRequestManager.install()
                }
                .disabled(systemExtensionRequestManager.isBusy || !systemExtensionRequestManager.canSubmitActivationRequest)

                Button("Uninstall Camera Extension") {
                    systemExtensionRequestManager.uninstall()
                }
                .disabled(systemExtensionRequestManager.isBusy || !systemExtensionRequestManager.canSubmitDeactivationRequest)

                Divider()

                Button("Refresh Status") {
                    systemExtensionRequestManager.refreshStatus()
                }
                .keyboardShortcut("r", modifiers: [.command])

                Button("Copy Diagnostics") {
                    systemExtensionRequestManager.copyDiagnostics()
                }
                .keyboardShortcut("c", modifiers: [.command, .shift])

                Button("Copy Activation Checklist") {
                    systemExtensionRequestManager.copyActivationChecklist()
                }
                .keyboardShortcut("l", modifiers: [.command, .shift])

                Button("Copy Runtime Diagnostics Command") {
                    systemExtensionRequestManager.copyRuntimeDiagnosticsCommand()
                }
                .keyboardShortcut("d", modifiers: [.command, .shift])

                Button("Copy Expected Runtime Evidence") {
                    systemExtensionRequestManager.copyRuntimeEvidenceExpectedDiagnostics()
                }
                .keyboardShortcut("e", modifiers: [.command, .shift])

                Button("Open System Settings") {
                    systemExtensionRequestManager.openSystemSettings()
                }

                Divider()

                Button("Reveal App in Finder") {
                    systemExtensionRequestManager.revealApplicationInFinder()
                }

                Button("Reveal Extension in Finder") {
                    systemExtensionRequestManager.revealBundledExtensionInFinder()
                }
                .disabled(!systemExtensionRequestManager.canRevealBundledExtension)
            }
        }
    }
}
