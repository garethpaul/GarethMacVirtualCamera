//
//  ContentView.swift
//

import Foundation
import AppKit
import Darwin
import Security
import SwiftUI
import SystemExtensions

private let quarantineAttributeName = "com.apple.quarantine"

struct ContentView: View {
    @Environment(\.scenePhase) private var scenePhase
    @ObservedObject var systemExtensionRequestManager: SystemExtensionRequestManager
    @State private var selectedSection: DashboardSection? = .overview
    @State private var didCompleteInitialAppearance = false

    var body: some View {
        NavigationSplitView {
            SidebarView(manager: systemExtensionRequestManager,
                        selectedSection: $selectedSection)
        } detail: {
            DashboardView(manager: systemExtensionRequestManager,
                          selectedSection: selectedSection ?? .overview)
        }
        .navigationSplitViewStyle(.balanced)
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear {
            guard didCompleteInitialAppearance else {
                didCompleteInitialAppearance = true
                return
            }

            systemExtensionRequestManager.refreshAfterAppBecameActive()
        }
        .onChange(of: scenePhase) { _, newScenePhase in
            guard newScenePhase == .active, didCompleteInitialAppearance else { return }

            systemExtensionRequestManager.refreshAfterAppBecameActive()
        }
    }
}

#Preview {
    ContentView(systemExtensionRequestManager: SystemExtensionRequestManager(logText: ""))
}

private enum DashboardSection: String, CaseIterable, Hashable {
    case overview
    case evidence
    case activity

    var title: String {
        switch self {
        case .overview:
            return "Overview"
        case .evidence:
            return "Evidence"
        case .activity:
            return "Activity"
        }
    }

    var systemImage: String {
        switch self {
        case .overview:
            return "rectangle.grid.2x2"
        case .evidence:
            return "checklist"
        case .activity:
            return "list.bullet.rectangle"
        }
    }
}

@MainActor
final class SystemExtensionRequestManager: NSObject, ObservableObject {
    private let expectedApplicationBundleIdentifier = "com.garethpaul.GarethVideoCam"
    private let expectedExtensionBundleIdentifier = "com.garethpaul.GarethVideoCam.Extension"
    private let expectedApplicationBundlePath = "/Applications/GarethVideoCam.app"
    private let requiredSystemExtensionInstallEntitlement = "com.apple.developer.system-extension.install"
    private let requiredApplicationGroupBaseIdentifier = "com.garethpaul.GarethVideoCam"
    private let applicationGroupsEntitlement = "com.apple.security.application-groups"
    private let expectedBundledVideoWidth = 1280
    private let expectedBundledVideoHeight = 720
    private let expectedBundledVideoFrameRate = 24

    enum InstallState: Equatable {
        case idle
        case ready
        case needsApplicationLocation
        case needsBundleIdentifier
        case needsApplicationExecutable
        case needsBundleVersion
        case needsExtensionMetadata
        case needsBundledVideo
        case needsSigning
        case locatingExtension
        case activating
        case needsApproval
        case activated
        case deactivated
        case deactivating
        case requiresRestart
        case failed(String)

        var title: String {
            switch self {
            case .idle:
                return "Idle"
            case .ready:
                return "Ready"
            case .needsApplicationLocation:
                return "Move to Applications"
            case .needsBundleIdentifier:
                return "Bundle ID Required"
            case .needsApplicationExecutable:
                return "App Executable"
            case .needsBundleVersion:
                return "Version Mismatch"
            case .needsExtensionMetadata:
                return "Extension Metadata"
            case .needsBundledVideo:
                return "Bundled Video"
            case .needsSigning:
                return "Signing Required"
            case .locatingExtension:
                return "Locating Extension"
            case .activating:
                return "Installing"
            case .needsApproval:
                return "Approval Required"
            case .activated:
                return "Installed"
            case .deactivated:
                return "Removed"
            case .deactivating:
                return "Removing"
            case .requiresRestart:
                return "Restart Required"
            case .failed:
                return "Failed"
            }
        }

        var systemImage: String {
            switch self {
            case .idle, .ready:
                return "circle.dashed"
            case .needsApplicationLocation:
                return "exclamationmark.triangle.fill"
            case .needsBundleIdentifier:
                return "tag.fill"
            case .needsApplicationExecutable:
                return "play.rectangle.fill"
            case .needsBundleVersion:
                return "exclamationmark.triangle.fill"
            case .needsExtensionMetadata:
                return "puzzlepiece.extension.fill"
            case .needsBundledVideo:
                return "film.fill"
            case .needsSigning:
                return "lock.fill"
            case .locatingExtension, .activating, .deactivating:
                return "arrow.triangle.2.circlepath"
            case .needsApproval:
                return "person.badge.shield.checkmark"
            case .activated:
                return "checkmark.seal.fill"
            case .deactivated:
                return "checkmark.circle.fill"
            case .requiresRestart:
                return "restart.circle.fill"
            case .failed:
                return "xmark.octagon.fill"
            }
        }

        var tint: Color {
            switch self {
            case .idle:
                return .secondary
            case .ready:
                return .blue
            case .needsApplicationLocation:
                return .orange
            case .needsBundleIdentifier:
                return .orange
            case .needsApplicationExecutable:
                return .orange
            case .needsBundleVersion:
                return .orange
            case .needsExtensionMetadata:
                return .orange
            case .needsBundledVideo:
                return .orange
            case .needsSigning:
                return .orange
            case .locatingExtension, .activating, .deactivating:
                return .indigo
            case .needsApproval, .requiresRestart:
                return .orange
            case .activated:
                return .green
            case .deactivated:
                return .secondary
            case .failed:
                return .red
            }
        }
    }

    struct VideoDimensions: Equatable {
        var width: Int
        var height: Int
    }

    struct BundledVideoMetadata: Equatable {
        var dimensions: VideoDimensions?
        var frameRate: Int?
        var durationSeconds: Double?
    }

    private struct MP4Atom {
        var type: String
        var payloadStart: Int
        var payloadEnd: Int
    }

    struct ExtensionInfo: Equatable {
        var identifier: String
        var version: String
        var shortVersion: String?
        var buildVersion: String?
        var executableName: String
        var executablePath: String
        var machServiceName: String
        var bundlePath: String
        var videoPath: String
        var videoByteCount: Int64
        var videoMetadata: BundledVideoMetadata
    }

    struct ReadinessCheck: Identifiable, Equatable {
        enum Status: Equatable {
            case passing
            case blocked
            case pending

            var title: String {
                switch self {
                case .passing:
                    return "Ready"
                case .blocked:
                    return "Blocked"
                case .pending:
                    return "Pending"
                }
            }

            var symbolName: String {
                switch self {
                case .passing:
                    return "checkmark.circle.fill"
                case .blocked:
                    return "xmark.circle.fill"
                case .pending:
                    return "clock.fill"
                }
            }

            var color: Color {
                switch self {
                case .passing:
                    return .green
                case .blocked:
                    return .orange
                case .pending:
                    return .secondary
                }
            }
        }

        let id: String
        let title: String
        let detail: String
        let status: Status
    }

    struct ActivityItem: Identifiable, Equatable {
        enum Level {
            case info
            case success
            case warning
            case error

            var title: String {
                switch self {
                case .info:
                    return "Info"
                case .success:
                    return "Success"
                case .warning:
                    return "Warning"
                case .error:
                    return "Error"
                }
            }

            var color: Color {
                switch self {
                case .info:
                    return .blue
                case .success:
                    return .green
                case .warning:
                    return .orange
                case .error:
                    return .red
                }
            }

            var symbolName: String {
                switch self {
                case .info:
                    return "info.circle.fill"
                case .success:
                    return "checkmark.circle.fill"
                case .warning:
                    return "exclamationmark.triangle.fill"
                case .error:
                    return "xmark.octagon.fill"
                }
            }
        }

        let id = UUID()
        let date = Date()
        let level: Level
        let title: String
        let detail: String
    }

    struct RuntimeEvidenceCheck: Identifiable, Equatable {
        let id: String
        let title: String
        let expectedValue: String
    }

    enum CodeSigningStatus: Equatable {
        case valid(String, String?, Set<String>, Set<String>)
        case invalid(String)
        case unknown(String)

        var title: String {
            switch self {
            case .valid:
                return "Valid"
            case .invalid:
                return "Invalid"
            case .unknown:
                return "Unknown"
            }
        }

        var detail: String {
            switch self {
            case .valid(let detail, _, _, _):
                return detail
            case .invalid(let detail):
                return detail
            case .unknown(let detail):
                return detail
            }
        }

        var isValid: Bool {
            switch self {
            case .valid:
                return true
            case .invalid, .unknown:
                return false
            }
        }

        var isUnknown: Bool {
            switch self {
            case .unknown:
                return true
            case .valid, .invalid:
                return false
            }
        }

        var teamIdentifier: String? {
            switch self {
            case .valid(_, let teamIdentifier, _, _):
                return teamIdentifier
            case .invalid, .unknown:
                return nil
            }
        }

        func hasEnabledEntitlement(_ entitlement: String) -> Bool {
            switch self {
            case .valid(_, _, let enabledEntitlementKeys, _):
                return enabledEntitlementKeys.contains(entitlement)
            case .invalid, .unknown:
                return false
            }
        }

        var applicationGroupIdentifiers: Set<String> {
            switch self {
            case .valid(_, _, _, let applicationGroupIdentifiers):
                return applicationGroupIdentifiers
            case .invalid, .unknown:
                return []
            }
        }
    }

    enum QuarantineStatus: Equatable {
        case present(String)
        case absent
        case unknown(String)

        var title: String {
            switch self {
            case .present:
                return "Present"
            case .absent:
                return "Absent"
            case .unknown:
                return "Unknown"
            }
        }

        var detail: String {
            switch self {
            case .present(let value):
                return "\(quarantineAttributeName)=\(value)"
            case .absent:
                return "No quarantine extended attribute was found."
            case .unknown(let detail):
                return detail
            }
        }
    }

    private enum RequestKind {
        case activation
        case deactivation

        var approvalDetail: String {
            switch self {
            case .activation:
                return "System Settings must allow the camera extension before it can run."
            case .deactivation:
                return "System Settings must allow removal before the camera extension can be deactivated."
            }
        }

        var completedTitle: String {
            switch self {
            case .activation:
                return "Install Completed"
            case .deactivation:
                return "Uninstall Completed"
            }
        }

        var completedDetail: String {
            switch self {
            case .activation:
                return "The camera extension is active."
            case .deactivation:
                return "The camera extension was removed."
            }
        }

        var completedState: InstallState {
            switch self {
            case .activation:
                return .activated
            case .deactivation:
                return .deactivated
            }
        }

        var restartDetail: String {
            switch self {
            case .activation:
                return "macOS will finish installing the camera extension after restart."
            case .deactivation:
                return "macOS will finish removing the camera extension after restart."
            }
        }

        var diagnosticTitle: String {
            switch self {
            case .activation:
                return "Activation"
            case .deactivation:
                return "Deactivation"
            }
        }
    }

    @Published var state: InstallState = .idle
    @Published var extensionInfo: ExtensionInfo?
    @Published var activity: [ActivityItem] = []
    @Published var appCodeSigningStatus: CodeSigningStatus = .unknown("App code-signing status has not been checked yet.")
    @Published var extensionCodeSigningStatus: CodeSigningStatus = .unknown("System extension code-signing status has not been checked yet.")
    @Published var appQuarantineStatus: QuarantineStatus = .unknown("App quarantine status has not been checked yet.")
    @Published var extensionQuarantineStatus: QuarantineStatus = .unknown("System extension quarantine status has not been checked yet.")
    @Published var extensionLoadFailureDetail: String?
    @Published var lastFailureDetail: String?

    private var pendingRequestKind: RequestKind?

    var logText: String {
        activity.map { "\($0.title): \($0.detail)" }.joined(separator: "\n")
    }

    init(logText: String) {
        super.init()
        if !logText.isEmpty {
            appendActivity(level: .info, title: "Started", detail: logText)
        }
        refreshExtensionInfo()
    }

    var isBusy: Bool {
        switch state {
        case .locatingExtension, .activating, .needsApproval, .deactivating, .requiresRestart:
            return true
        default:
            return false
        }
    }

    var applicationLocationStatus: String {
        if isRunningFromExpectedApplicationPath {
            return "Expected Path"
        }

        return isRunningFromApplications ? "Unexpected Applications Path" : "Outside Applications"
    }

    var applicationBundlePath: String {
        return Bundle.main.bundleURL.path
    }

    var applicationExecutablePath: String {
        return Bundle.main.executableURL?.path ?? "Unknown"
    }

    var applicationExecutableStatus: String {
        return applicationExecutableReadinessDetail == nil ? "Valid" : "Invalid"
    }

    var applicationVersion: String {
        return Self.displayVersion(shortVersion: applicationShortVersionValue,
                                   buildVersion: applicationBuildVersionValue)
    }

    var applicationShortVersion: String {
        return applicationShortVersionValue ?? "Unknown"
    }

    var applicationBuildVersion: String {
        return applicationBuildVersionValue ?? "Unknown"
    }

    var hostOperatingSystemVersion: String {
        return ProcessInfo.processInfo.operatingSystemVersionString
    }

    private static func displayVersion(shortVersion: String?, buildVersion: String?) -> String {
        switch (shortVersion, buildVersion) {
        case let (shortVersion?, buildVersion?):
            return "\(shortVersion) (\(buildVersion))"
        case let (shortVersion?, nil):
            return shortVersion
        case let (nil, buildVersion?):
            return buildVersion
        case (nil, nil):
            return "Unknown"
        }
    }

    private static func displayVersion(for properties: OSSystemExtensionProperties) -> String {
        return displayVersion(shortVersion: properties.bundleShortVersion,
                              buildVersion: properties.bundleVersion)
    }

    private static func infoPlistString(in bundle: Bundle, key: String) -> String? {
        guard let value = bundle.object(forInfoDictionaryKey: key) as? String else {
            return nil
        }

        let trimmedValue = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedValue.isEmpty,
              trimmedValue == value else {
            return nil
        }

        return value
    }

    private static func isExecutableName(_ executableName: String) -> Bool {
        return executableName != "."
            && executableName != ".."
            && !executableName.contains("/")
    }

    private static func extensionMachServiceName(in bundle: Bundle) -> String? {
        guard let cmioExtension = bundle.object(forInfoDictionaryKey: "CMIOExtension") as? [String: Any],
              let machServiceName = cmioExtension["CMIOExtensionMachServiceName"] as? String else {
            return nil
        }

        let trimmedMachServiceName = machServiceName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedMachServiceName.isEmpty,
              trimmedMachServiceName == machServiceName else {
            return nil
        }

        return machServiceName
    }

    private static func bundledRuntimeDiagnosticsScriptPath() -> String? {
        guard let scriptURL = Bundle.main.url(forResource: "collect_runtime_diagnostics",
                                              withExtension: "sh") else {
            return nil
        }

        return FileManager.default.fileExists(atPath: scriptURL.path) ? scriptURL.path : nil
    }

    private static func shellQuoted(_ value: String) -> String {
        return "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
    }

    var applicationBundleIdentifier: String {
        return Bundle.main.bundleIdentifier ?? "Unknown"
    }

    private var applicationShortVersionValue: String? {
        return Self.infoPlistString(in: Bundle.main, key: "CFBundleShortVersionString")
    }

    private var applicationBuildVersionValue: String? {
        return Self.infoPlistString(in: Bundle.main, key: "CFBundleVersion")
    }

    var expectedApplicationIdentifier: String {
        return expectedApplicationBundleIdentifier
    }

    var expectedExtensionIdentifier: String {
        return expectedExtensionBundleIdentifier
    }

    var expectedApplicationPath: String {
        return expectedApplicationBundlePath
    }

    var applicationBundleIdentifierStatus: String {
        return applicationIdentifierReadinessDetail == nil ? "Matches" : "Mismatch"
    }

    var canSubmitActivationRequest: Bool {
        return applicationLocationReadinessDetail == nil
            && applicationIdentifierReadinessDetail == nil
            && applicationExecutableReadinessDetail == nil
            && appCodeSigningStatus.isValid
            && appEntitlementReadinessDetail == nil
            && extensionInfo != nil
            && bundleVersionReadinessDetail == nil
            && extensionExecutableReadinessDetail == nil
            && extensionMetadataReadinessDetail == nil
            && bundledVideoReadinessDetail == nil
            && extensionCodeSigningStatus.isValid
            && extensionHostOnlyEntitlementReadinessDetail == nil
            && applicationGroupReadinessDetail == nil
            && signingTeamReadinessDetail == nil
    }

    var canSubmitDeactivationRequest: Bool {
        return applicationLocationReadinessDetail == nil
            && applicationIdentifierReadinessDetail == nil
            && applicationExecutableReadinessDetail == nil
            && appCodeSigningStatus.isValid
            && appEntitlementReadinessDetail == nil
    }

    var canSubmitSystemExtensionRequests: Bool {
        return canSubmitActivationRequest
    }

    var isRunningFromApplications: Bool {
        return applicationBundlePath.hasPrefix("/Applications/")
    }

    var isRunningFromExpectedApplicationPath: Bool {
        return applicationBundlePath == expectedApplicationBundlePath
    }

    var requestReadinessMessage: String? {
        if applicationLocationReadinessDetail != nil {
            return "System extension requests require /Applications/GarethVideoCam.app."
        }

        if applicationIdentifierReadinessDetail != nil {
            return "System extension requests require the expected app bundle identifier."
        }

        if applicationExecutableReadinessDetail != nil {
            return "System extension requests require a runnable host app executable."
        }

        if appCodeSigningStatus.isUnknown {
            return "System extension requests require a checked app signature."
        }

        if !appCodeSigningStatus.isValid {
            return "System extension requests require a valid app signature."
        }

        if appEntitlementReadinessDetail != nil {
            return "System extension requests require the app System Extension entitlement."
        }

        if bundleVersionReadinessDetail != nil {
            return "System extension requests require matching app and extension bundle versions."
        }

        if extensionExecutableReadinessDetail != nil {
            return "System extension requests require a runnable embedded extension executable."
        }

        if extensionMetadataReadinessDetail != nil {
            return "System extension requests require complete embedded extension metadata."
        }

        if bundledVideoReadinessDetail != nil {
            return "System extension requests require the bundled loop video metadata."
        }

        if extensionCodeSigningStatus.isUnknown {
            return "System extension requests require a checked system extension signature."
        }

        if !extensionCodeSigningStatus.isValid {
            return "System extension requests require a valid system extension signature."
        }

        if extensionHostOnlyEntitlementReadinessDetail != nil {
            return "System extension requests require the embedded extension to omit the host System Extension entitlement."
        }

        if applicationGroupReadinessDetail != nil {
            return "System extension requests require matching app group entitlements."
        }

        if signingTeamReadinessDetail != nil {
            return "System extension requests require matching app and extension team identifiers."
        }

        return nil
    }

    var requestReadinessStatus: String {
        return canSubmitSystemExtensionRequests ? "Ready" : "Blocked"
    }

    var activationRequestReadinessStatus: String {
        return canSubmitActivationRequest ? "Ready" : "Blocked"
    }

    var activationRequestReadinessDetail: String {
        return requestReadinessDetail ?? "Activation requests can be submitted."
    }

    var deactivationRequestReadinessStatus: String {
        return canSubmitDeactivationRequest ? "Ready" : "Blocked"
    }

    var deactivationRequestReadinessDetail: String {
        if let applicationLocationReadinessDetail {
            return applicationLocationReadinessDetail
        }

        if let applicationIdentifierReadinessDetail {
            return applicationIdentifierReadinessDetail
        }

        if let applicationExecutableReadinessDetail {
            return applicationExecutableReadinessDetail
        }

        if !appCodeSigningStatus.isValid {
            return appCodeSigningStatus.detail
        }

        if let appEntitlementReadinessDetail {
            return appEntitlementReadinessDetail
        }

        return "Deactivation requests can be submitted."
    }

    var pendingRequestStatus: String {
        return pendingRequestKind?.diagnosticTitle ?? "None"
    }

    var stateGuidanceDetail: String? {
        let requestKind = pendingRequestKind ?? .activation

        switch state {
        case .needsApproval:
            return requestKind.approvalDetail
        case .requiresRestart:
            return requestKind.restartDetail
        default:
            return nil
        }
    }

    var readinessChecks: [ReadinessCheck] {
        let appSignatureStatus: ReadinessCheck.Status = appCodeSigningStatus.isValid ? .passing : (appCodeSigningStatus.isUnknown ? .pending : .blocked)
        let extensionSignatureStatus: ReadinessCheck.Status = extensionCodeSigningStatus.isValid ? .passing : (extensionCodeSigningStatus.isUnknown ? .pending : .blocked)
        let appExecutableStatus: ReadinessCheck.Status = applicationExecutableReadinessDetail == nil ? .passing : .blocked
        let entitlementStatus: ReadinessCheck.Status
        if appCodeSigningStatus.isValid {
            entitlementStatus = appEntitlementReadinessDetail == nil ? .passing : .blocked
        } else {
            entitlementStatus = .pending
        }

        let bundleVersionStatus: ReadinessCheck.Status
        let bundleVersionDetail: String
        if extensionInfo != nil {
            if let bundleVersionReadinessDetail {
                bundleVersionStatus = .blocked
                bundleVersionDetail = bundleVersionReadinessDetail
            } else {
                bundleVersionStatus = .passing
                bundleVersionDetail = "App and embedded extension short/build versions both report \(applicationVersion)."
            }
        } else {
            bundleVersionStatus = .pending
            bundleVersionDetail = "Embedded extension version is pending until the extension is loaded."
        }

        let extensionExecutableStatus: ReadinessCheck.Status
        let extensionExecutableDetail: String
        if let extensionExecutableReadinessDetail {
            extensionExecutableStatus = .blocked
            extensionExecutableDetail = extensionExecutableReadinessDetail
        } else if let extensionInfo {
            extensionExecutableStatus = .passing
            extensionExecutableDetail = "Executable \(extensionInfo.executableName) is runnable at \(extensionInfo.executablePath)."
        } else {
            extensionExecutableStatus = .pending
            extensionExecutableDetail = "Embedded extension executable is pending until the extension is loaded."
        }

        let extensionHostOnlyEntitlementStatus: ReadinessCheck.Status
        let extensionHostOnlyEntitlementDetail: String
        if extensionCodeSigningStatus.isValid {
            if let extensionHostOnlyEntitlementReadinessDetail {
                extensionHostOnlyEntitlementStatus = .blocked
                extensionHostOnlyEntitlementDetail = extensionHostOnlyEntitlementReadinessDetail
            } else {
                extensionHostOnlyEntitlementStatus = .passing
                extensionHostOnlyEntitlementDetail = "The embedded system extension does not carry the host-only System Extension entitlement."
            }
        } else {
            extensionHostOnlyEntitlementStatus = .pending
            extensionHostOnlyEntitlementDetail = "A valid extension signature is required before extension entitlements can be checked."
        }

        let applicationGroupStatus: ReadinessCheck.Status
        let applicationGroupDetail: String
        if !appCodeSigningStatus.isValid || !extensionCodeSigningStatus.isValid {
            applicationGroupStatus = .pending
            applicationGroupDetail = "Valid app and extension signatures are required before app groups can be compared."
        } else if let applicationGroupReadinessDetail {
            applicationGroupStatus = .blocked
            applicationGroupDetail = applicationGroupReadinessDetail
        } else {
            applicationGroupStatus = .passing
            applicationGroupDetail = "App and extension share \(sharedApplicationGroupDescription)."
        }

        let teamStatus: ReadinessCheck.Status
        let teamDetail: String
        if !appCodeSigningStatus.isValid || !extensionCodeSigningStatus.isValid {
            teamStatus = .pending
            teamDetail = "Valid app and extension signatures are required before Team IDs can be compared."
        } else if let signingTeamReadinessDetail {
            teamStatus = .blocked
            teamDetail = signingTeamReadinessDetail
        } else {
            teamStatus = .passing
            teamDetail = "App and extension Team IDs match."
        }

        let extensionMetadataStatus: ReadinessCheck.Status
        let extensionMetadataDetail: String
        if let extensionMetadataReadinessDetail {
            extensionMetadataStatus = .blocked
            extensionMetadataDetail = extensionMetadataReadinessDetail
        } else if let extensionInfo {
            extensionMetadataStatus = .passing
            extensionMetadataDetail = "CMIO Mach service \(extensionInfo.machServiceName) is resolved and matches the extension identifier."
        } else {
            extensionMetadataStatus = .pending
            extensionMetadataDetail = "Embedded extension metadata is pending until the extension is loaded."
        }

        let bundledVideoStatus: ReadinessCheck.Status
        let bundledVideoDetail: String
        if let bundledVideoReadinessDetail {
            bundledVideoStatus = .blocked
            bundledVideoDetail = bundledVideoReadinessDetail
        } else if let extensionInfo {
            bundledVideoStatus = .passing
            bundledVideoDetail = "\(bundledVideoMetadataSummary) at \(extensionInfo.videoPath)"
        } else {
            bundledVideoStatus = .pending
            bundledVideoDetail = "Bundled video metadata is pending until the embedded extension is loaded."
        }

        return [
            ReadinessCheck(id: "location",
                           title: "Application Location",
                           detail: applicationLocationReadinessDetail ?? applicationBundlePath,
                           status: applicationLocationReadinessDetail == nil ? .passing : .blocked),
            ReadinessCheck(id: "bundle-id",
                           title: "Host Bundle ID",
                           detail: applicationIdentifierReadinessDetail ?? applicationBundleIdentifier,
                           status: applicationIdentifierReadinessDetail == nil ? .passing : .blocked),
            ReadinessCheck(id: "app-executable",
                           title: "App Executable",
                           detail: applicationExecutableReadinessDetail ?? applicationExecutablePath,
                           status: appExecutableStatus),
            ReadinessCheck(id: "app-signature",
                           title: "App Signature",
                           detail: appCodeSigningStatus.detail,
                           status: appSignatureStatus),
            ReadinessCheck(id: "app-entitlement",
                           title: "System Extension Entitlement",
                           detail: appEntitlementReadinessDetail ?? appSystemExtensionEntitlementStatus,
                           status: entitlementStatus),
            ReadinessCheck(id: "bundle-version",
                           title: "Bundle Version Match",
                           detail: bundleVersionDetail,
                           status: bundleVersionStatus),
            ReadinessCheck(id: "extension-signature",
                           title: "Extension Signature",
                           detail: extensionCodeSigningStatus.detail,
                           status: extensionSignatureStatus),
            ReadinessCheck(id: "extension-executable",
                           title: "Extension Executable",
                           detail: extensionExecutableDetail,
                           status: extensionExecutableStatus),
            ReadinessCheck(id: "extension-host-entitlement",
                           title: "Extension Host Entitlement",
                           detail: extensionHostOnlyEntitlementDetail,
                           status: extensionHostOnlyEntitlementStatus),
            ReadinessCheck(id: "application-group",
                           title: "Application Group",
                           detail: applicationGroupDetail,
                           status: applicationGroupStatus),
            ReadinessCheck(id: "extension-metadata",
                           title: "Extension Metadata",
                           detail: extensionMetadataDetail,
                           status: extensionMetadataStatus),
            ReadinessCheck(id: "bundled-video",
                           title: "Bundled Video",
                           detail: bundledVideoDetail,
                           status: bundledVideoStatus),
            ReadinessCheck(id: "team-id",
                           title: "Team ID Match",
                           detail: teamDetail,
                           status: teamStatus)
        ]
    }

    var readinessProgressSummary: String {
        let checks = readinessChecks
        let readyCount = checks.filter { $0.status == .passing }.count
        let blockedCount = checks.filter { $0.status == .blocked }.count
        let pendingCount = checks.filter { $0.status == .pending }.count
        var summaryParts = ["\(readyCount)/\(checks.count) checks ready"]

        if blockedCount > 0 {
            summaryParts.append("\(blockedCount) blocked")
        }

        if pendingCount > 0 {
            summaryParts.append("\(pendingCount) pending")
        }

        return summaryParts.joined(separator: ", ")
    }

    var requestReadinessDetail: String? {
        if let applicationLocationReadinessDetail {
            return applicationLocationReadinessDetail
        }

        if let applicationIdentifierReadinessDetail {
            return applicationIdentifierReadinessDetail
        }

        if let applicationExecutableReadinessDetail {
            return applicationExecutableReadinessDetail
        }

        if !appCodeSigningStatus.isValid {
            return appCodeSigningStatus.detail
        }

        if let appEntitlementReadinessDetail {
            return appEntitlementReadinessDetail
        }

        if let bundleVersionReadinessDetail {
            return bundleVersionReadinessDetail
        }

        if let extensionExecutableReadinessDetail {
            return extensionExecutableReadinessDetail
        }

        if let extensionMetadataReadinessDetail {
            return extensionMetadataReadinessDetail
        }

        if let bundledVideoReadinessDetail {
            return bundledVideoReadinessDetail
        }

        if !extensionCodeSigningStatus.isValid {
            return extensionCodeSigningStatus.detail
        }

        if let extensionHostOnlyEntitlementReadinessDetail {
            return extensionHostOnlyEntitlementReadinessDetail
        }

        if let applicationGroupReadinessDetail {
            return applicationGroupReadinessDetail
        }

        if let signingTeamReadinessDetail {
            return signingTeamReadinessDetail
        }

        return nil
    }

    var requestReadinessNextAction: String {
        if let applicationLocationReadinessDetail {
            return "Move the app to \(expectedApplicationBundlePath). \(applicationLocationReadinessDetail)"
        }

        if let applicationIdentifierReadinessDetail {
            return "Use a build signed with the expected host bundle identifier. \(applicationIdentifierReadinessDetail)"
        }

        if let applicationExecutableReadinessDetail {
            return "Rebuild and reinstall the app so its declared executable exists and is runnable. \(applicationExecutableReadinessDetail)"
        }

        if appCodeSigningStatus.isUnknown {
            return "Refresh app status so the host app signature can be checked. \(appCodeSigningStatus.detail)"
        }

        if !appCodeSigningStatus.isValid {
            return "Sign the host app with a valid Apple Developer identity. \(appCodeSigningStatus.detail)"
        }

        if let appEntitlementReadinessDetail {
            return "Sign the host app with the \(requiredSystemExtensionInstallEntitlement) entitlement. \(appEntitlementReadinessDetail)"
        }

        if let bundleVersionReadinessDetail {
            return "Rebuild and reinstall the app so the host and embedded extension bundle versions match. \(bundleVersionReadinessDetail)"
        }

        if let extensionExecutableReadinessDetail {
            return "Rebuild the embedded system extension so its declared executable exists and is runnable. \(extensionExecutableReadinessDetail)"
        }

        if let extensionMetadataReadinessDetail {
            return "Rebuild the embedded system extension so its CMIO metadata is complete. \(extensionMetadataReadinessDetail)"
        }

        if let bundledVideoReadinessDetail {
            return "Rebuild the embedded system extension with a bundled loop video that has the expected metadata. \(bundledVideoReadinessDetail)"
        }

        if extensionCodeSigningStatus.isUnknown {
            return "Refresh app status so the embedded system extension signature can be checked. \(extensionCodeSigningStatus.detail)"
        }

        if !extensionCodeSigningStatus.isValid {
            return "Sign the embedded system extension with a valid Apple Developer identity. \(extensionCodeSigningStatus.detail)"
        }

        if let extensionHostOnlyEntitlementReadinessDetail {
            return "Remove the host-only \(requiredSystemExtensionInstallEntitlement) entitlement from the embedded system extension. \(extensionHostOnlyEntitlementReadinessDetail)"
        }

        if let applicationGroupReadinessDetail {
            return "Sign the app and embedded system extension with the same Team ID-prefixed \(applicationGroupsEntitlement) value ending in \(requiredApplicationGroupBaseIdentifier). \(applicationGroupReadinessDetail)"
        }

        if let signingTeamReadinessDetail {
            return "Sign the app and embedded system extension with the same Apple Developer Team ID. \(signingTeamReadinessDetail)"
        }

        switch state {
        case .needsApproval:
            return "Open System Settings and approve the pending camera extension request."
        case .requiresRestart:
            return "Restart macOS to finish the pending \(pendingRequestKind?.diagnosticTitle.lowercased() ?? "request")."
        default:
            return "Submit the system extension request."
        }
    }

    var appTeamIdentifier: String {
        return appCodeSigningStatus.teamIdentifier ?? "Unknown"
    }

    var appSystemExtensionEntitlementStatus: String {
        guard appCodeSigningStatus.isValid else {
            return "Unknown"
        }

        return appCodeSigningStatus.hasEnabledEntitlement(requiredSystemExtensionInstallEntitlement) ? "Present" : "Missing"
    }

    var extensionTeamIdentifier: String {
        return extensionCodeSigningStatus.teamIdentifier ?? "Unknown"
    }

    var extensionHostOnlyEntitlementStatus: String {
        guard extensionCodeSigningStatus.isValid else {
            return "Unknown"
        }

        return extensionCodeSigningStatus.hasEnabledEntitlement(requiredSystemExtensionInstallEntitlement) ? "Present" : "Absent"
    }

    var appApplicationGroups: String {
        guard appCodeSigningStatus.isValid else {
            return "Unknown"
        }

        return Self.displayApplicationGroups(appCodeSigningStatus.applicationGroupIdentifiers)
    }

    var extensionApplicationGroups: String {
        guard extensionCodeSigningStatus.isValid else {
            return "Unknown"
        }

        return Self.displayApplicationGroups(extensionCodeSigningStatus.applicationGroupIdentifiers)
    }

    var applicationGroupStatus: String {
        guard appCodeSigningStatus.isValid, extensionCodeSigningStatus.isValid else {
            return "Unknown"
        }

        return applicationGroupReadinessDetail == nil ? "Shared" : "Mismatch"
    }

    var sharedApplicationGroupDescription: String {
        let sharedGroups = Self.expectedSharedApplicationGroups(appCodeSigningStatus.applicationGroupIdentifiers,
                                                                extensionCodeSigningStatus.applicationGroupIdentifiers,
                                                                baseIdentifier: requiredApplicationGroupBaseIdentifier)
        return Self.displayApplicationGroups(sharedGroups)
    }

    var bundleVersionStatus: String {
        guard extensionInfo != nil else {
            return "Unknown"
        }

        return bundleVersionReadinessDetail == nil ? "Matches" : "Mismatch"
    }

    var bundleShortVersionMatchStatus: String {
        guard let extensionInfo else {
            return "Unknown"
        }

        guard let applicationShortVersion = applicationShortVersionValue,
              let extensionShortVersion = extensionInfo.shortVersion else {
            return "Unknown"
        }

        return applicationShortVersion == extensionShortVersion ? "Matches" : "Mismatch"
    }

    var bundleBuildVersionMatchStatus: String {
        guard let extensionInfo else {
            return "Unknown"
        }

        guard let applicationBuildVersion = applicationBuildVersionValue,
              let extensionBuildVersion = extensionInfo.buildVersion else {
            return "Unknown"
        }

        return applicationBuildVersion == extensionBuildVersion ? "Matches" : "Mismatch"
    }

    var diagnosticGeneratedAt: String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: Date())
    }

    private static func diagnosticTimestamp(from date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    var bundledVideoSize: String {
        guard let videoByteCount = extensionInfo?.videoByteCount else {
            return "Unknown"
        }

        return ByteCountFormatter.string(fromByteCount: videoByteCount, countStyle: .file)
    }

    var bundledVideoDimensions: String {
        guard let dimensions = extensionInfo?.videoMetadata.dimensions else {
            return "Unknown"
        }

        return "\(dimensions.width)x\(dimensions.height)"
    }

    var bundledVideoFrameRate: String {
        guard let frameRate = extensionInfo?.videoMetadata.frameRate else {
            return "Unknown"
        }

        return "\(frameRate) fps"
    }

    var bundledVideoDuration: String {
        guard let durationSeconds = extensionInfo?.videoMetadata.durationSeconds else {
            return "Unknown"
        }

        return String(format: "%.3f seconds", durationSeconds)
    }

    var bundledVideoMetadataSummary: String {
        return "\(bundledVideoSize), \(bundledVideoDimensions), \(bundledVideoFrameRate), \(bundledVideoDuration)"
    }

    var extensionMetadataStatus: String {
        guard extensionInfo != nil else {
            return "Missing"
        }

        return extensionMetadataReadinessDetail == nil ? "Complete" : "Invalid"
    }

    var extensionExecutableStatus: String {
        if extensionExecutableReadinessDetail != nil {
            return "Invalid"
        }

        return extensionInfo == nil ? "Missing" : "Valid"
    }

    var extensionMachServiceResolvedStatus: String {
        guard let extensionInfo else {
            return "Unknown"
        }

        return Self.containsUnresolvedBuildSetting(extensionInfo.machServiceName) ? "Unresolved" : "Resolved"
    }

    var extensionMachServiceIdentifierMatchStatus: String {
        guard let extensionInfo else {
            return "Unknown"
        }

        return Self.isExpectedMachServiceName(extensionInfo.machServiceName, for: extensionInfo.identifier) ? "Matches" : "Mismatch"
    }

    var bundledVideoReadinessStatus: String {
        guard extensionInfo != nil else {
            return "Missing"
        }

        return bundledVideoReadinessDetail == nil ? "Valid" : "Invalid"
    }

    var canRevealBundledExtension: Bool {
        return extensionInfo != nil
    }

    var diagnosticSummary: String {
        let extensionDescription: String
        if let extensionInfo {
            extensionDescription = """
            Extension ID: \(extensionInfo.identifier)
            Extension Version: \(extensionInfo.version)
            Extension Bundle Short Version: \(extensionInfo.shortVersion ?? "Unknown")
            Extension Bundle Build Version: \(extensionInfo.buildVersion ?? "Unknown")
            Extension Executable: \(extensionInfo.executableName)
            Extension Executable Path: \(extensionInfo.executablePath)
            Extension CMIO Mach Service: \(extensionInfo.machServiceName)
            Extension Path: \(extensionInfo.bundlePath)
            Bundled Video Path: \(extensionInfo.videoPath)
            Bundled Video Size: \(bundledVideoSize)
            Bundled Video Dimensions: \(bundledVideoDimensions)
            Bundled Video Frame Rate: \(bundledVideoFrameRate)
            Bundled Video Duration: \(bundledVideoDuration)
            """
        } else {
            extensionDescription = "Extension: No bundled extension loaded"
        }

        let recentActivity = activity
            .prefix(8)
            .map { "\(Self.diagnosticTimestamp(from: $0.date)) [\($0.level.title)] \($0.title): \($0.detail)" }
            .joined(separator: "\n")
        let readinessDescription = readinessChecks
            .map { "\($0.title): \($0.status.title) - \($0.detail)" }
            .joined(separator: "\n")

        return """
        Gareth Video Cam Diagnostics
        Generated At: \(diagnosticGeneratedAt)
        State: \(state.title)
        macOS Version: \(hostOperatingSystemVersion)
        App Version: \(applicationVersion)
        App Bundle Short Version: \(applicationShortVersion)
        App Bundle Build Version: \(applicationBuildVersion)
        Bundle Version Check: \(bundleVersionStatus)
        Bundle Short Version Match: \(bundleShortVersionMatchStatus)
        Bundle Build Version Match: \(bundleBuildVersionMatchStatus)
        Expected App ID: \(expectedApplicationIdentifier)
        Actual App ID: \(applicationBundleIdentifier)
        App Bundle ID Check: \(applicationBundleIdentifierStatus)
        Expected Extension ID: \(expectedExtensionIdentifier)
        Expected App Path: \(expectedApplicationPath)
        App Location: \(applicationLocationStatus)
        App Path: \(applicationBundlePath)
        App Executable Path: \(applicationExecutablePath)
        App Executable Check: \(applicationExecutableStatus)
        App Quarantine: \(appQuarantineStatus.title)
        App Quarantine Detail: \(appQuarantineStatus.detail)
        Request Readiness: \(requestReadinessStatus)
        Request Readiness Detail: \(requestReadinessDetail ?? "System extension requests can be submitted.")
        Request Readiness Next Action: \(requestReadinessNextAction)
        Activation Request Readiness: \(activationRequestReadinessStatus)
        Activation Request Detail: \(activationRequestReadinessDetail)
        Deactivation Request Readiness: \(deactivationRequestReadinessStatus)
        Deactivation Request Detail: \(deactivationRequestReadinessDetail)
        Runtime Diagnostics Command Source: \(runtimeDiagnosticsCommandSource)
        Runtime Diagnostics Command: \(runtimeDiagnosticsCommand)
        Expected Runtime Evidence:
        \(runtimeEvidenceExpectedDiagnostics)

        Pending Request: \(pendingRequestStatus)
        State Guidance: \(stateGuidanceDetail ?? "None")
        Last Failure: \(lastFailureDetail ?? "No failure recorded.")
        Readiness Summary: \(readinessProgressSummary)
        Readiness Checks:
        \(readinessDescription)

        App Code Signing: \(appCodeSigningStatus.title)
        App Code Signing Detail: \(appCodeSigningStatus.detail)
        App System Extension Entitlement: \(appSystemExtensionEntitlementStatus)
        App Application Groups: \(appApplicationGroups)
        App Team ID: \(appTeamIdentifier)
        Extension Code Signing: \(extensionCodeSigningStatus.title)
        Extension Code Signing Detail: \(extensionCodeSigningStatus.detail)
        Extension Load Failure: \(extensionLoadFailureDetail ?? "None")
        Extension Quarantine: \(extensionQuarantineStatus.title)
        Extension Quarantine Detail: \(extensionQuarantineStatus.detail)
        Extension Host-Only Entitlement: \(extensionHostOnlyEntitlementStatus)
        Extension Application Groups: \(extensionApplicationGroups)
        Application Group Check: \(applicationGroupStatus)
        Shared Application Group: \(sharedApplicationGroupDescription)
        Extension Team ID: \(extensionTeamIdentifier)
        Extension Executable Check: \(extensionExecutableStatus)
        Extension CMIO Mach Service Resolved: \(extensionMachServiceResolvedStatus)
        Extension CMIO Mach Service Identifier Match: \(extensionMachServiceIdentifierMatchStatus)
        \(extensionDescription)

        Recent Activity:
        \(recentActivity.isEmpty ? "No activity yet" : recentActivity)
        """
    }

    var runtimeDiagnosticsCommand: String {
        let scriptPath = Self.bundledRuntimeDiagnosticsScriptPath()
            ?? "./scripts/collect_runtime_diagnostics.sh"
        return "/bin/bash \(Self.shellQuoted(scriptPath)) \(Self.shellQuoted(expectedApplicationPath)) 1h"
    }

    var runtimeDiagnosticsCommandSource: String {
        return Self.bundledRuntimeDiagnosticsScriptPath() == nil
            ? "Repository fallback"
            : "Bundled app resource"
    }

    var runtimeEvidenceChecks: [RuntimeEvidenceCheck] {
        return [
            RuntimeEvidenceCheck(id: "readiness",
                                 title: "Runtime readiness result",
                                 expectedValue: "ready"),
            RuntimeEvidenceCheck(id: "application-location",
                                 title: "Application location ready",
                                 expectedValue: "yes"),
            RuntimeEvidenceCheck(id: "app-bundle-id",
                                 title: "App bundle identifier ready",
                                 expectedValue: "yes"),
            RuntimeEvidenceCheck(id: "app-signature",
                                 title: "App signature ready",
                                 expectedValue: "yes"),
            RuntimeEvidenceCheck(id: "app-entitlement",
                                 title: "App System Extension entitlement ready",
                                 expectedValue: "yes"),
            RuntimeEvidenceCheck(id: "app-executable",
                                 title: "App executable ready",
                                 expectedValue: "yes"),
            RuntimeEvidenceCheck(id: "extension-bundle-id",
                                 title: "Extension bundle identifier ready",
                                 expectedValue: "yes"),
            RuntimeEvidenceCheck(id: "extension-signature",
                                 title: "Extension signature ready",
                                 expectedValue: "yes"),
            RuntimeEvidenceCheck(id: "extension-host-entitlement",
                                 title: "Extension host-only entitlement absent",
                                 expectedValue: "yes"),
            RuntimeEvidenceCheck(id: "extension-executable",
                                 title: "Extension executable ready",
                                 expectedValue: "yes"),
            RuntimeEvidenceCheck(id: "mach-service",
                                 title: "Extension CMIO Mach service ready",
                                 expectedValue: "yes"),
            RuntimeEvidenceCheck(id: "bundle-version",
                                 title: "Bundle versions match ready",
                                 expectedValue: "yes"),
            RuntimeEvidenceCheck(id: "team-id",
                                 title: "Signing Team match ready",
                                 expectedValue: "yes"),
            RuntimeEvidenceCheck(id: "application-group",
                                 title: "Application group match ready",
                                 expectedValue: "yes"),
            RuntimeEvidenceCheck(id: "bundled-video",
                                 title: "Bundled video ready",
                                 expectedValue: "yes"),
            RuntimeEvidenceCheck(id: "video-metadata",
                                 title: "Bundled video metadata ready",
                                 expectedValue: "yes"),
            RuntimeEvidenceCheck(id: "activation-evidence",
                                 title: "Runtime activation evidence result",
                                 expectedValue: "active"),
            RuntimeEvidenceCheck(id: "registration-present",
                                 title: "Extension registration entry present",
                                 expectedValue: "yes"),
            RuntimeEvidenceCheck(id: "registration-active-enabled",
                                 title: "Extension registration activated enabled",
                                 expectedValue: "yes"),
            RuntimeEvidenceCheck(id: "camera-device",
                                 title: "Expected virtual camera device present",
                                 expectedValue: "yes")
        ]
    }

    var runtimeEvidenceExpectedDiagnostics: String {
        return runtimeEvidenceChecks
            .map { "\($0.title): \($0.expectedValue)" }
            .joined(separator: "\n")
    }

    var activationChecklist: String {
        return """
        Gareth Video Cam Signed Runtime Activation Checklist
        Generated At: \(diagnosticGeneratedAt)
        Current Request Readiness: \(activationRequestReadinessStatus)
        Current Request Detail: \(activationRequestReadinessDetail)
        Current Next Action: \(requestReadinessNextAction)
        Current Readiness Summary: \(readinessProgressSummary)
        Last Failure: \(lastFailureDetail ?? "No failure recorded.")
        App Path: \(applicationBundlePath)
        Expected App Path: \(expectedApplicationPath)
        Extension ID: \(extensionInfo?.identifier ?? expectedExtensionIdentifier)

        Steps:
        1. Build with an Apple Developer team that has the System Extension entitlement and app-group entitlement.
        2. Run the shared Xcode scheme so it replaces /Applications/GarethVideoCam.app, then open the app from that path.
        3. Confirm the in-app readiness summary has no blocked checks, then choose Install.
        4. Approve the pending camera extension in System Settings if macOS requests approval.
        5. Run the Diagnostics Command below on the signed macOS host.
        6. Confirm the diagnostics report the expected signed-host evidence lines.

        Expected Diagnostics:
        \(runtimeEvidenceExpectedDiagnostics)

        Diagnostics Command Source:
        \(runtimeDiagnosticsCommandSource)

        Diagnostics Command:
        \(runtimeDiagnosticsCommand)
        """
    }

    func install() {
        guard let extensionInfo = prepareForSystemExtensionRequest() else { return }

        state = .activating
        pendingRequestKind = .activation
        lastFailureDetail = nil
        appendActivity(level: .info,
                       title: "Install Requested",
                       detail: extensionInfo.identifier)

        let activationRequest = OSSystemExtensionRequest.activationRequest(forExtensionWithIdentifier: extensionInfo.identifier,
                                                                           queue: .main)
        activationRequest.delegate = self
        OSSystemExtensionManager.shared.submitRequest(activationRequest)
    }

    func uninstall() {
        guard let extensionIdentifier = prepareForSystemExtensionDeactivationRequest() else { return }

        state = .deactivating
        pendingRequestKind = .deactivation
        lastFailureDetail = nil
        appendActivity(level: .info,
                       title: "Uninstall Requested",
                       detail: extensionIdentifier)

        let deactivationRequest = OSSystemExtensionRequest.deactivationRequest(forExtensionWithIdentifier: extensionIdentifier,
                                                                               queue: .main)
        deactivationRequest.delegate = self
        OSSystemExtensionManager.shared.submitRequest(deactivationRequest)
    }

    @discardableResult
    func refreshExtensionInfo() -> Bool {
        appQuarantineStatus = Self.quarantineStatus(for: Bundle.main.bundleURL)
        appCodeSigningStatus = Self.evaluateCodeSigningStatus(for: Bundle.main.bundleURL,
                                                              validDetail: "The app bundle code signature is valid across all architecture slices.")

        do {
            let loadedExtensionInfo = try loadBundledExtensionInfo()
            extensionInfo = loadedExtensionInfo
            extensionLoadFailureDetail = nil
            extensionCodeSigningStatus = Self.evaluateCodeSigningStatus(for: URL(fileURLWithPath: loadedExtensionInfo.bundlePath),
                                                                        validDetail: "The embedded system extension code signature is valid across all architecture slices.")
            extensionQuarantineStatus = Self.quarantineStatus(for: URL(fileURLWithPath: loadedExtensionInfo.bundlePath))

            switch state {
            case .idle, .ready, .needsApplicationLocation, .needsBundleIdentifier, .needsApplicationExecutable, .needsBundleVersion, .needsExtensionMetadata, .needsBundledVideo, .needsSigning, .deactivated, .failed:
                state = readinessState
            default:
                break
            }
            return true
        } catch {
            extensionInfo = nil
            extensionLoadFailureDetail = error.localizedDescription
            extensionCodeSigningStatus = .unknown("System extension signature has not been checked because the embedded extension could not be loaded.")
            extensionQuarantineStatus = .unknown("System extension quarantine status could not be checked: \(error.localizedDescription)")
            handleReadinessFailure(error)
            return false
        }
    }

    func refreshStatus() {
        guard refreshExtensionInfo() else { return }

        let detail = requestReadinessDetail ?? "System extension requests can be submitted."
        appendActivity(level: canSubmitSystemExtensionRequests ? .success : .warning,
                       title: "Status Refreshed",
                       detail: detail)
    }

    func refreshAfterAppBecameActive() {
        let previousState = state
        let previousReadinessDetail = requestReadinessDetail
        let previousCanSubmitRequests = canSubmitSystemExtensionRequests
        let previousCanSubmitDeactivationRequest = canSubmitDeactivationRequest

        guard refreshExtensionInfo() else { return }

        let currentReadinessDetail = requestReadinessDetail
        let didChangeVisibleStatus = previousState != state
            || previousReadinessDetail != currentReadinessDetail
            || previousCanSubmitRequests != canSubmitSystemExtensionRequests
            || previousCanSubmitDeactivationRequest != canSubmitDeactivationRequest

        guard didChangeVisibleStatus else { return }

        let detail = currentReadinessDetail ?? "System extension requests can be submitted."
        appendActivity(level: canSubmitSystemExtensionRequests ? .success : .warning,
                       title: "Status Updated",
                       detail: detail)
    }

    func copyDiagnostics() {
        let didRefresh = refreshExtensionInfo()

        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        let didCopyDiagnostics = pasteboard.setString(diagnosticSummary, forType: .string)

        if didCopyDiagnostics {
            appendActivity(level: .success,
                           title: "Diagnostics Copied",
                           detail: copySuccessDetail("Copied current app and extension status to the clipboard.",
                                                     didRefresh: didRefresh))
        } else {
            appendActivity(level: .error,
                           title: "Diagnostics Copy Failed",
                           detail: "macOS did not accept the diagnostics text on the clipboard.")
        }
    }

    func copyActivationChecklist() {
        let didRefresh = refreshExtensionInfo()

        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        let didCopyChecklist = pasteboard.setString(activationChecklist, forType: .string)

        if didCopyChecklist {
            appendActivity(level: .success,
                           title: "Checklist Copied",
                           detail: copySuccessDetail("Copied the signed runtime activation checklist to the clipboard.",
                                                     didRefresh: didRefresh))
        } else {
            appendActivity(level: .error,
                           title: "Checklist Copy Failed",
                           detail: "macOS did not accept the activation checklist text on the clipboard.")
        }
    }

    func copyRuntimeDiagnosticsCommand() {
        let didRefresh = refreshExtensionInfo()

        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        let didCopyCommand = pasteboard.setString(runtimeDiagnosticsCommand, forType: .string)

        if didCopyCommand {
            appendActivity(level: .success,
                           title: "Diagnostics Command Copied",
                           detail: copySuccessDetail(runtimeDiagnosticsCommand,
                                                     didRefresh: didRefresh))
        } else {
            appendActivity(level: .error,
                           title: "Diagnostics Command Copy Failed",
                           detail: "macOS did not accept the runtime diagnostics command on the clipboard.")
        }
    }

    func copyRuntimeEvidenceExpectedDiagnostics() {
        let didRefresh = refreshExtensionInfo()

        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        let didCopyExpectedDiagnostics = pasteboard.setString(runtimeEvidenceExpectedDiagnostics, forType: .string)

        if didCopyExpectedDiagnostics {
            appendActivity(level: .success,
                           title: "Expected Evidence Copied",
                           detail: copySuccessDetail("Copied the expected signed-host diagnostics lines to the clipboard.",
                                                     didRefresh: didRefresh))
        } else {
            appendActivity(level: .error,
                           title: "Expected Evidence Copy Failed",
                           detail: "macOS did not accept the expected runtime evidence lines on the clipboard.")
        }
    }

    func revealApplicationInFinder() {
        NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL])
        appendActivity(level: .info,
                       title: "App Revealed",
                       detail: applicationBundlePath)
    }

    func revealBundledExtensionInFinder() {
        refreshExtensionInfo()

        guard let bundlePath = extensionInfo?.bundlePath else {
            appendActivity(level: .warning,
                           title: "Extension Reveal Unavailable",
                           detail: "No bundled extension is available to reveal.")
            return
        }

        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: bundlePath)])
        appendActivity(level: .info,
                       title: "Extension Revealed",
                       detail: bundlePath)
    }

    func openSystemSettings() {
        let requestKind = pendingRequestKind ?? .activation
        let settingsURL = URL(fileURLWithPath: "/System/Applications/System Settings.app")
        let didOpenSettings = NSWorkspace.shared.open(settingsURL)

        if didOpenSettings {
            appendActivity(level: .info,
                           title: "System Settings Opened",
                           detail: requestKind.approvalDetail)
        } else {
            appendActivity(level: .error,
                           title: "System Settings Unavailable",
                           detail: "macOS did not open System Settings from \(settingsURL.path).")
        }
    }

    private func loadBundledExtensionInfo() throws -> ExtensionInfo {
        let extensionsDirectoryURL = URL(fileURLWithPath: "Contents/Library/SystemExtensions", relativeTo: Bundle.main.bundleURL)

        let extensionURLs: [URL]
        do {
            extensionURLs = try FileManager.default.contentsOfDirectory(at: extensionsDirectoryURL, includingPropertiesForKeys: nil, options: .skipsHiddenFiles)
        } catch {
            throw ExtensionRequestError.missingExtensionsDirectory(extensionsDirectoryURL.path)
        }

        let extensionBundleURLs = extensionURLs
            .filter { $0.pathExtension == "systemextension" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }

        guard !extensionBundleURLs.isEmpty else {
            throw ExtensionRequestError.missingBundledExtension
        }

        guard extensionBundleURLs.count == 1 else {
            throw ExtensionRequestError.multipleBundledExtensions(extensionBundleURLs.map(\.lastPathComponent).joined(separator: ", "))
        }

        let extensionURL = extensionBundleURLs[0]
        guard let extensionBundle = Bundle(url: extensionURL) else {
            throw ExtensionRequestError.unreadableExtensionBundle(extensionURL.path)
        }

        guard let identifier = extensionBundle.bundleIdentifier else {
            throw ExtensionRequestError.missingBundleIdentifier(extensionURL.path)
        }

        guard identifier == expectedExtensionBundleIdentifier else {
            throw ExtensionRequestError.unexpectedBundleIdentifier(expected: expectedExtensionBundleIdentifier,
                                                                  actual: identifier)
        }

        let shortVersion = Self.infoPlistString(in: extensionBundle, key: "CFBundleShortVersionString")
        let buildVersion = Self.infoPlistString(in: extensionBundle, key: "CFBundleVersion")
        let version = Self.displayVersion(shortVersion: shortVersion,
                                          buildVersion: buildVersion)
        guard let executableName = Self.infoPlistString(in: extensionBundle, key: "CFBundleExecutable") else {
            throw ExtensionRequestError.missingExtensionExecutable(extensionURL.path)
        }
        guard Self.isExecutableName(executableName) else {
            throw ExtensionRequestError.invalidExtensionExecutableName(executableName, extensionURL.path)
        }
        let executableURL = extensionURL
            .appendingPathComponent("Contents")
            .appendingPathComponent("MacOS")
            .appendingPathComponent(executableName)
        try Self.validateExtensionExecutable(at: executableURL)
        guard let machServiceName = Self.extensionMachServiceName(in: extensionBundle) else {
            throw ExtensionRequestError.missingExtensionMachService(extensionURL.path)
        }
        let videoURL = extensionURL
            .appendingPathComponent("Contents")
            .appendingPathComponent("Resources")
            .appendingPathComponent("video.mp4")
        let videoByteCount = try Self.bundledVideoByteCount(at: videoURL)
        let videoMetadata = try Self.bundledVideoMetadata(at: videoURL)

        return ExtensionInfo(identifier: identifier,
                             version: version,
                             shortVersion: shortVersion,
                             buildVersion: buildVersion,
                             executableName: executableName,
                             executablePath: executableURL.path,
                             machServiceName: machServiceName,
                             bundlePath: extensionURL.path,
                             videoPath: videoURL.path,
                             videoByteCount: videoByteCount,
                             videoMetadata: videoMetadata)
    }

    private static func bundledVideoByteCount(at videoURL: URL) throws -> Int64 {
        var isDirectory = ObjCBool(false)
        guard FileManager.default.fileExists(atPath: videoURL.path, isDirectory: &isDirectory),
              !isDirectory.boolValue else {
            throw ExtensionRequestError.missingBundledVideoResource(videoURL.path)
        }

        let attributes: [FileAttributeKey: Any]
        do {
            attributes = try FileManager.default.attributesOfItem(atPath: videoURL.path)
        } catch {
            throw ExtensionRequestError.missingBundledVideoResource(videoURL.path)
        }

        guard let byteCount = attributes[.size] as? NSNumber else {
            throw ExtensionRequestError.missingBundledVideoResource(videoURL.path)
        }

        guard byteCount.int64Value > 0 else {
            throw ExtensionRequestError.emptyBundledVideoResource(videoURL.path)
        }

        return byteCount.int64Value
    }

    private static func bundledVideoMetadata(at videoURL: URL) throws -> BundledVideoMetadata {
        let videoData: Data
        do {
            videoData = try Data(contentsOf: videoURL)
        } catch {
            throw ExtensionRequestError.unreadableBundledVideoMetadata(videoURL.path)
        }

        var videoMetadata = BundledVideoMetadata(dimensions: nil,
                                                frameRate: nil,
                                                durationSeconds: nil)

        for atom in atoms(in: videoData, start: 0, end: videoData.count) where atom.type == "moov" {
            for trackAtom in atoms(in: videoData, start: atom.payloadStart, end: atom.payloadEnd) where trackAtom.type == "trak" {
                for mediaAtom in atoms(in: videoData, start: trackAtom.payloadStart, end: trackAtom.payloadEnd) where mediaAtom.type == "mdia" {
                    var handler: String?
                    var timescale: UInt32?
                    var mediaDuration: UInt64?
                    var sampleDurations: [(sampleCount: UInt32, sampleDelta: UInt32)] = []
                    var trackDimensions: VideoDimensions?

                    for nestedMediaAtom in atoms(in: videoData, start: mediaAtom.payloadStart, end: mediaAtom.payloadEnd) {
                        if nestedMediaAtom.type == "mdhd" {
                            if let mdhd = parseMdhd(in: videoData,
                                                    payloadStart: nestedMediaAtom.payloadStart,
                                                    payloadEnd: nestedMediaAtom.payloadEnd) {
                                timescale = mdhd.timescale
                                mediaDuration = mdhd.duration
                            }
                        } else if nestedMediaAtom.type == "hdlr" {
                            handler = parseHdlr(in: videoData,
                                                payloadStart: nestedMediaAtom.payloadStart,
                                                payloadEnd: nestedMediaAtom.payloadEnd)
                        } else if nestedMediaAtom.type == "minf" {
                            sampleDurations = findSttsEntries(in: videoData,
                                                              start: nestedMediaAtom.payloadStart,
                                                              end: nestedMediaAtom.payloadEnd)
                            for minfAtom in atoms(in: videoData,
                                                  start: nestedMediaAtom.payloadStart,
                                                  end: nestedMediaAtom.payloadEnd) where minfAtom.type == "stbl" {
                                for stblAtom in atoms(in: videoData,
                                                      start: minfAtom.payloadStart,
                                                      end: minfAtom.payloadEnd) where stblAtom.type == "stsd" {
                                    if let dimensions = parseStsdDimensions(in: videoData,
                                                                            payloadStart: stblAtom.payloadStart,
                                                                            payloadEnd: stblAtom.payloadEnd) {
                                        trackDimensions = dimensions
                                    }
                                }
                            }
                        }
                    }

                    guard handler == "vide" else {
                        continue
                    }

                    if let trackDimensions {
                        videoMetadata.dimensions = trackDimensions
                    }

                    if let timescale, timescale > 0, let mediaDuration {
                        videoMetadata.durationSeconds = Double(mediaDuration) / Double(timescale)
                    }

                    if let timescale, timescale > 0, sampleDurations.count == 1 {
                        let sampleCount = sampleDurations[0].sampleCount
                        let sampleDelta = sampleDurations[0].sampleDelta
                        if sampleCount > 0, sampleDelta > 0, timescale % sampleDelta == 0 {
                            videoMetadata.frameRate = Int(timescale / sampleDelta)
                        }
                    }
                }
            }
        }

        return videoMetadata
    }

    private static func atoms(in data: Data, start: Int, end: Int) -> [MP4Atom] {
        guard start >= 0, start <= end, end <= data.count else {
            return []
        }

        var atoms: [MP4Atom] = []
        var offset = start
        while offset + 8 <= end {
            guard let atomSize32 = readUInt32(data, at: offset, end: end),
                  let atomType = atomType(in: data, at: offset, end: end) else {
                return atoms
            }

            var atomSize = Int(atomSize32)
            var headerSize = 8

            if atomSize32 == 1 {
                guard let atomSize64 = readUInt64(data, at: offset + 8, end: end),
                      atomSize64 <= UInt64(Int.max) else {
                    return atoms
                }
                atomSize = Int(atomSize64)
                headerSize = 16
            } else if atomSize32 == 0 {
                atomSize = end - offset
            }

            guard atomSize >= headerSize, atomSize <= end - offset else {
                return atoms
            }

            atoms.append(MP4Atom(type: atomType,
                                 payloadStart: offset + headerSize,
                                 payloadEnd: offset + atomSize))
            offset += atomSize
        }

        return atoms
    }

    private static func parseMdhd(in data: Data, payloadStart: Int, payloadEnd: Int) -> (timescale: UInt32, duration: UInt64)? {
        guard payloadStart >= 0, payloadStart < payloadEnd, payloadEnd <= data.count else {
            return nil
        }

        let version = data[payloadStart]
        if version == 1 {
            guard let timescale = readUInt32(data, at: payloadStart + 20, end: payloadEnd),
                  let duration = readUInt64(data, at: payloadStart + 24, end: payloadEnd) else {
                return nil
            }

            return (timescale, duration)
        }

        guard version == 0 else {
            return nil
        }

        guard let timescale = readUInt32(data, at: payloadStart + 12, end: payloadEnd),
              let duration = readUInt32(data, at: payloadStart + 16, end: payloadEnd) else {
            return nil
        }

        return (timescale, UInt64(duration))
    }

    private static func parseHdlr(in data: Data, payloadStart: Int, payloadEnd: Int) -> String? {
        guard payloadStart >= 0,
              payloadStart + 12 <= payloadEnd,
              payloadEnd <= data.count else {
            return nil
        }

        guard data[payloadStart] == 0 else {
            return nil
        }

        return String(data: data.subdata(in: (payloadStart + 8)..<(payloadStart + 12)),
                      encoding: .isoLatin1)
    }

    private static func parseStts(in data: Data, payloadStart: Int, payloadEnd: Int) -> [(sampleCount: UInt32, sampleDelta: UInt32)] {
        guard payloadStart >= 0,
              payloadStart + 8 <= payloadEnd,
              payloadEnd <= data.count,
              let entryCount = readUInt32(data, at: payloadStart + 4, end: payloadEnd) else {
            return []
        }

        guard data[payloadStart] == 0 else {
            return []
        }

        var entries: [(sampleCount: UInt32, sampleDelta: UInt32)] = []
        var entryOffset = payloadStart + 8
        let maxEntryCount = max(0, (payloadEnd - entryOffset) / 8)
        guard Int(entryCount) <= maxEntryCount else {
            return []
        }

        for _ in 0..<Int(entryCount) {
            guard let sampleCount = readUInt32(data, at: entryOffset, end: payloadEnd),
                  let sampleDelta = readUInt32(data, at: entryOffset + 4, end: payloadEnd) else {
                return entries
            }

            entries.append((sampleCount, sampleDelta))
            entryOffset += 8
        }

        return entries
    }

    private static func findSttsEntries(in data: Data, start: Int, end: Int) -> [(sampleCount: UInt32, sampleDelta: UInt32)] {
        for atom in atoms(in: data, start: start, end: end) {
            if atom.type == "stts" {
                return parseStts(in: data,
                                 payloadStart: atom.payloadStart,
                                 payloadEnd: atom.payloadEnd)
            }

            if atom.type == "minf" || atom.type == "stbl" {
                let nestedEntries = findSttsEntries(in: data,
                                                    start: atom.payloadStart,
                                                    end: atom.payloadEnd)
                if !nestedEntries.isEmpty {
                    return nestedEntries
                }
            }
        }

        return []
    }

    private static func parseStsdDimensions(in data: Data, payloadStart: Int, payloadEnd: Int) -> VideoDimensions? {
        guard payloadStart >= 0,
              payloadStart + 8 <= payloadEnd,
              payloadEnd <= data.count else {
            return nil
        }

        guard data[payloadStart] == 0 else {
            return nil
        }

        guard let entryCount = readUInt32(data, at: payloadStart + 4, end: payloadEnd) else {
            return nil
        }

        let sampleDescriptions = atoms(in: data, start: payloadStart + 8, end: payloadEnd)
        guard Int(entryCount) <= sampleDescriptions.count else {
            return nil
        }

        for atom in sampleDescriptions.prefix(Int(entryCount)) {
            guard ["avc1", "hvc1", "hev1", "mp4v"].contains(atom.type),
                  let width = readUInt16(data, at: atom.payloadStart + 24, end: atom.payloadEnd),
                  let height = readUInt16(data, at: atom.payloadStart + 26, end: atom.payloadEnd) else {
                continue
            }

            return VideoDimensions(width: Int(width), height: Int(height))
        }

        return nil
    }

    private static func atomType(in data: Data, at offset: Int, end: Int) -> String? {
        guard offset + 8 <= end else {
            return nil
        }

        return String(data: data.subdata(in: (offset + 4)..<(offset + 8)),
                      encoding: .isoLatin1)
    }

    private static func readUInt16(_ data: Data, at offset: Int, end: Int) -> UInt16? {
        guard offset >= 0, offset + 2 <= end, end <= data.count else {
            return nil
        }

        return data[offset..<(offset + 2)].reduce(UInt16(0)) { partialResult, byte in
            return (partialResult << 8) | UInt16(byte)
        }
    }

    private static func readUInt32(_ data: Data, at offset: Int, end: Int) -> UInt32? {
        guard offset >= 0, offset + 4 <= end, end <= data.count else {
            return nil
        }

        return data[offset..<(offset + 4)].reduce(UInt32(0)) { partialResult, byte in
            return (partialResult << 8) | UInt32(byte)
        }
    }

    private static func readUInt64(_ data: Data, at offset: Int, end: Int) -> UInt64? {
        guard offset >= 0, offset + 8 <= end, end <= data.count else {
            return nil
        }

        return data[offset..<(offset + 8)].reduce(UInt64(0)) { partialResult, byte in
            return (partialResult << 8) | UInt64(byte)
        }
    }

    private static func validateExtensionExecutable(at executableURL: URL) throws {
        var isDirectory = ObjCBool(false)
        let executablePath = executableURL.path
        guard FileManager.default.fileExists(atPath: executablePath, isDirectory: &isDirectory),
              !isDirectory.boolValue,
              FileManager.default.isExecutableFile(atPath: executablePath) else {
            throw ExtensionRequestError.invalidExtensionExecutable(executablePath)
        }
    }

    @discardableResult
    private func prepareForHostSystemExtensionRequest() -> Bool {
        appQuarantineStatus = Self.quarantineStatus(for: Bundle.main.bundleURL)
        appCodeSigningStatus = Self.evaluateCodeSigningStatus(for: Bundle.main.bundleURL,
                                                              validDetail: "The app bundle code signature is valid across all architecture slices.")

        if let applicationLocationReadinessDetail {
            recordReadinessBlock(state: .needsApplicationLocation,
                                 title: "Move Required",
                                 detail: applicationLocationReadinessDetail)
            return false
        }

        if let applicationIdentifierReadinessDetail {
            recordReadinessBlock(state: .needsBundleIdentifier,
                                 title: "App Identifier Required",
                                 detail: applicationIdentifierReadinessDetail)
            return false
        }

        if let applicationExecutableReadinessDetail {
            recordReadinessBlock(state: .needsApplicationExecutable,
                                 title: "App Executable Required",
                                 detail: applicationExecutableReadinessDetail)
            return false
        }

        guard appCodeSigningStatus.isValid else {
            recordReadinessBlock(state: .needsSigning,
                                 title: "Signing Required",
                                 detail: appCodeSigningStatus.detail)
            return false
        }

        if let appEntitlementReadinessDetail {
            recordReadinessBlock(state: .needsSigning,
                                 title: "Entitlement Required",
                                 detail: appEntitlementReadinessDetail)
            return false
        }

        return true
    }

    private func prepareForSystemExtensionRequest() -> ExtensionInfo? {
        guard prepareForHostSystemExtensionRequest() else { return nil }

        state = .locatingExtension
        let extensionInfo: ExtensionInfo
        do {
            extensionInfo = try loadBundledExtensionInfo()
            self.extensionInfo = extensionInfo
            extensionLoadFailureDetail = nil
            extensionCodeSigningStatus = Self.evaluateCodeSigningStatus(for: URL(fileURLWithPath: extensionInfo.bundlePath),
                                                                        validDetail: "The embedded system extension code signature is valid across all architecture slices.")
            extensionQuarantineStatus = Self.quarantineStatus(for: URL(fileURLWithPath: extensionInfo.bundlePath))
        } catch {
            self.extensionInfo = nil
            extensionLoadFailureDetail = error.localizedDescription
            extensionCodeSigningStatus = .unknown("System extension signature has not been checked because the embedded extension could not be loaded.")
            extensionQuarantineStatus = .unknown("System extension quarantine status could not be checked: \(error.localizedDescription)")
            handleReadinessFailure(error)
            return nil
        }

        if let bundleVersionReadinessDetail {
            recordReadinessBlock(state: .needsBundleVersion,
                                 title: "Version Match Required",
                                 detail: bundleVersionReadinessDetail)
            return nil
        }

        if let extensionExecutableReadinessDetail {
            recordReadinessBlock(state: .needsExtensionMetadata,
                                 title: "Extension Executable Required",
                                 detail: extensionExecutableReadinessDetail)
            return nil
        }

        if let extensionMetadataReadinessDetail {
            recordReadinessBlock(state: .needsExtensionMetadata,
                                 title: "Extension Metadata Required",
                                 detail: extensionMetadataReadinessDetail)
            return nil
        }

        if let bundledVideoReadinessDetail {
            recordReadinessBlock(state: .needsBundledVideo,
                                 title: "Bundled Video Required",
                                 detail: bundledVideoReadinessDetail)
            return nil
        }

        guard extensionCodeSigningStatus.isValid else {
            recordReadinessBlock(state: .needsSigning,
                                 title: "Extension Signing Required",
                                 detail: extensionCodeSigningStatus.detail)
            return nil
        }

        if let extensionHostOnlyEntitlementReadinessDetail {
            recordReadinessBlock(state: .needsSigning,
                                 title: "Extension Entitlement Required",
                                 detail: extensionHostOnlyEntitlementReadinessDetail)
            return nil
        }

        if let applicationGroupReadinessDetail {
            recordReadinessBlock(state: .needsSigning,
                                 title: "Application Group Required",
                                 detail: applicationGroupReadinessDetail)
            return nil
        }

        if let signingTeamReadinessDetail {
            recordReadinessBlock(state: .needsSigning,
                                 title: "Team Identifier Required",
                                 detail: signingTeamReadinessDetail)
            return nil
        }

        return extensionInfo
    }

    private func prepareForSystemExtensionDeactivationRequest() -> String? {
        guard prepareForHostSystemExtensionRequest() else { return nil }

        return expectedExtensionBundleIdentifier
    }

    private var readinessState: InstallState {
        if applicationLocationReadinessDetail != nil {
            return .needsApplicationLocation
        }

        if applicationIdentifierReadinessDetail != nil {
            return .needsBundleIdentifier
        }

        if applicationExecutableReadinessDetail != nil {
            return .needsApplicationExecutable
        }

        if bundleVersionReadinessDetail != nil {
            return .needsBundleVersion
        }

        if extensionExecutableReadinessDetail != nil {
            return .needsExtensionMetadata
        }

        if extensionMetadataReadinessDetail != nil {
            return .needsExtensionMetadata
        }

        if bundledVideoReadinessDetail != nil {
            return .needsBundledVideo
        }

        if !appCodeSigningStatus.isValid
            || appEntitlementReadinessDetail != nil
            || !extensionCodeSigningStatus.isValid
            || extensionHostOnlyEntitlementReadinessDetail != nil
            || applicationGroupReadinessDetail != nil
            || signingTeamReadinessDetail != nil {
            return .needsSigning
        }

        return .ready
    }

    private var applicationLocationReadinessDetail: String? {
        guard !isRunningFromExpectedApplicationPath else {
            return nil
        }

        if isRunningFromApplications {
            return "The app is in /Applications but must run from \(expectedApplicationBundlePath); current path is \(applicationBundlePath)."
        }

        return "The app must run from \(expectedApplicationBundlePath); current path is \(applicationBundlePath)."
    }

    private var applicationIdentifierReadinessDetail: String? {
        guard applicationBundleIdentifier != expectedApplicationBundleIdentifier else {
            return nil
        }

        return "The app bundle identifier \(applicationBundleIdentifier) does not match the expected identifier \(expectedApplicationBundleIdentifier)."
    }

    private var applicationExecutableReadinessDetail: String? {
        guard let executableURL = Bundle.main.executableURL else {
            return "The host app does not declare a runnable executable."
        }

        let executablePath = executableURL.path
        var isDirectory = ObjCBool(false)
        guard FileManager.default.fileExists(atPath: executablePath, isDirectory: &isDirectory),
              !isDirectory.boolValue else {
            return "The host app executable is missing at \(executablePath)."
        }

        guard FileManager.default.isExecutableFile(atPath: executablePath) else {
            return "The host app executable is not executable at \(executablePath)."
        }

        return nil
    }

    private var appEntitlementReadinessDetail: String? {
        guard appCodeSigningStatus.isValid else {
            return nil
        }

        guard appCodeSigningStatus.hasEnabledEntitlement(requiredSystemExtensionInstallEntitlement) else {
            return "The app signature does not include the \(requiredSystemExtensionInstallEntitlement) entitlement."
        }

        return nil
    }

    private var bundleVersionReadinessDetail: String? {
        guard let extensionInfo else {
            return nil
        }

        guard let appShortVersion = applicationShortVersionValue,
              let appBuildVersion = applicationBuildVersionValue,
              let extensionShortVersion = extensionInfo.shortVersion,
              let extensionBuildVersion = extensionInfo.buildVersion else {
            return "Both app and embedded system extension short/build versions must be known; app short is \(applicationShortVersion), app build is \(applicationBuildVersion), extension short is \(extensionInfo.shortVersion ?? "Unknown"), extension build is \(extensionInfo.buildVersion ?? "Unknown")."
        }

        var mismatches: [String] = []
        if appShortVersion != extensionShortVersion {
            mismatches.append("short version \(appShortVersion) does not match \(extensionShortVersion)")
        }

        if appBuildVersion != extensionBuildVersion {
            mismatches.append("build version \(appBuildVersion) does not match \(extensionBuildVersion)")
        }

        guard mismatches.isEmpty else {
            return "The app and embedded system extension bundle versions differ: \(mismatches.joined(separator: ", "))."
        }

        return nil
    }

    private var extensionExecutableReadinessDetail: String? {
        if let extensionInfo {
            guard !extensionInfo.executableName.isEmpty else {
                return "The bundled system extension does not declare CFBundleExecutable."
            }

            guard !extensionInfo.executablePath.isEmpty else {
                return "The bundled system extension executable path could not be resolved."
            }

            var isDirectory = ObjCBool(false)
            guard FileManager.default.fileExists(atPath: extensionInfo.executablePath, isDirectory: &isDirectory),
                  !isDirectory.boolValue else {
                return "The bundled system extension executable is missing at \(extensionInfo.executablePath)."
            }

            guard FileManager.default.isExecutableFile(atPath: extensionInfo.executablePath) else {
                return "The bundled system extension executable is not executable at \(extensionInfo.executablePath)."
            }

            return nil
        }

        if let extensionLoadFailureDetail,
           Self.isExtensionExecutableFailureDetail(extensionLoadFailureDetail) {
            return extensionLoadFailureDetail
        }

        return nil
    }

    private var extensionHostOnlyEntitlementReadinessDetail: String? {
        guard extensionCodeSigningStatus.isValid else {
            return nil
        }

        guard !extensionCodeSigningStatus.hasEnabledEntitlement(requiredSystemExtensionInstallEntitlement) else {
            return "The embedded system extension signature includes the host-only \(requiredSystemExtensionInstallEntitlement) entitlement."
        }

        return nil
    }

    private var applicationGroupReadinessDetail: String? {
        guard appCodeSigningStatus.isValid, extensionCodeSigningStatus.isValid else {
            return nil
        }

        let appGroups = appCodeSigningStatus.applicationGroupIdentifiers
        let extensionGroups = extensionCodeSigningStatus.applicationGroupIdentifiers
        guard !appGroups.isEmpty else {
            return "The app signature does not include any \(applicationGroupsEntitlement) values."
        }

        guard !extensionGroups.isEmpty else {
            return "The embedded system extension signature does not include any \(applicationGroupsEntitlement) values."
        }

        if let unresolvedGroup = appGroups.first(where: Self.containsUnresolvedBuildSetting) {
            return "The app signature contains an unresolved application group value: \(unresolvedGroup)."
        }

        if let unresolvedGroup = extensionGroups.first(where: Self.containsUnresolvedBuildSetting) {
            return "The embedded system extension signature contains an unresolved application group value: \(unresolvedGroup)."
        }

        let appExpectedGroups = Self.expectedApplicationGroups(appGroups,
                                                               baseIdentifier: requiredApplicationGroupBaseIdentifier)
        guard !appExpectedGroups.isEmpty else {
            return "The app signature does not include a Team ID-prefixed application group ending in \(requiredApplicationGroupBaseIdentifier); signed groups are \(Self.displayApplicationGroups(appGroups))."
        }

        let extensionExpectedGroups = Self.expectedApplicationGroups(extensionGroups,
                                                                     baseIdentifier: requiredApplicationGroupBaseIdentifier)
        guard !extensionExpectedGroups.isEmpty else {
            return "The embedded system extension signature does not include a Team ID-prefixed application group ending in \(requiredApplicationGroupBaseIdentifier); signed groups are \(Self.displayApplicationGroups(extensionGroups))."
        }

        let sharedGroups = Self.expectedSharedApplicationGroups(appGroups,
                                                                extensionGroups,
                                                                baseIdentifier: requiredApplicationGroupBaseIdentifier)
        guard !sharedGroups.isEmpty else {
            return "The app and embedded system extension do not share the same expected application group; app groups are \(Self.displayApplicationGroups(appGroups)), extension groups are \(Self.displayApplicationGroups(extensionGroups))."
        }

        return nil
    }

    private var bundledVideoReadinessDetail: String? {
        if let extensionInfo {
            guard extensionInfo.videoByteCount > 0 else {
                return "The bundled extension video resource at \(extensionInfo.videoPath) is empty."
            }

            guard let dimensions = extensionInfo.videoMetadata.dimensions else {
                return "The bundled extension video resource at \(extensionInfo.videoPath) does not expose parseable video dimensions."
            }

            guard dimensions.width == expectedBundledVideoWidth,
                  dimensions.height == expectedBundledVideoHeight else {
                return "The bundled extension video resource at \(extensionInfo.videoPath) is \(dimensions.width)x\(dimensions.height), but must be \(expectedBundledVideoWidth)x\(expectedBundledVideoHeight)."
            }

            guard let frameRate = extensionInfo.videoMetadata.frameRate else {
                return "The bundled extension video resource at \(extensionInfo.videoPath) does not expose a parseable constant video frame rate."
            }

            guard frameRate == expectedBundledVideoFrameRate else {
                return "The bundled extension video resource at \(extensionInfo.videoPath) is \(frameRate) fps, but must be \(expectedBundledVideoFrameRate) fps."
            }

            guard let durationSeconds = extensionInfo.videoMetadata.durationSeconds,
                  durationSeconds > 0 else {
                return "The bundled extension video resource at \(extensionInfo.videoPath) does not expose a positive video duration."
            }

            return nil
        }

        if let extensionLoadFailureDetail,
           Self.isBundledVideoFailureDetail(extensionLoadFailureDetail) {
            return extensionLoadFailureDetail
        }

        return nil
    }

    private var extensionMetadataReadinessDetail: String? {
        if let extensionInfo {
            if extensionInfo.executableName.isEmpty {
                return "The bundled system extension does not declare CFBundleExecutable."
            }

            if extensionInfo.executablePath.isEmpty {
                return "The bundled system extension executable path could not be resolved."
            }

            if extensionInfo.machServiceName.isEmpty {
                return "The bundled system extension does not declare CMIOExtensionMachServiceName."
            }

            if Self.containsUnresolvedBuildSetting(extensionInfo.machServiceName) {
                return "The bundled system extension CMIOExtensionMachServiceName contains unresolved build settings: \(extensionInfo.machServiceName)."
            }

            if !Self.isExpectedMachServiceName(extensionInfo.machServiceName, for: extensionInfo.identifier) {
                return "The bundled system extension CMIOExtensionMachServiceName \(extensionInfo.machServiceName) must be \(extensionInfo.identifier) or a Team ID-prefixed value ending in .\(extensionInfo.identifier)."
            }

            return nil
        }

        if let extensionLoadFailureDetail,
           Self.isExtensionMetadataFailureDetail(extensionLoadFailureDetail) {
            return extensionLoadFailureDetail
        }

        return nil
    }

    private var signingTeamReadinessDetail: String? {
        guard appCodeSigningStatus.isValid, extensionCodeSigningStatus.isValid else {
            return nil
        }

        guard let appTeamIdentifier = appCodeSigningStatus.teamIdentifier else {
            return "The app signature does not expose a team identifier."
        }

        guard let extensionTeamIdentifier = extensionCodeSigningStatus.teamIdentifier else {
            return "The embedded system extension signature does not expose a team identifier."
        }

        guard appTeamIdentifier == extensionTeamIdentifier else {
            return "The app team identifier \(appTeamIdentifier) does not match the embedded system extension team identifier \(extensionTeamIdentifier)."
        }

        return nil
    }

    private static func evaluateCodeSigningStatus(for bundleURL: URL, validDetail: String) -> CodeSigningStatus {
        var staticCode: SecStaticCode?
        let createStatus = SecStaticCodeCreateWithPath(bundleURL as CFURL, SecCSFlags(), &staticCode)
        guard createStatus == errSecSuccess, let staticCode else {
            return .invalid(errorMessage(for: createStatus))
        }

        let validationFlags = SecCSFlags(rawValue: kSecCSCheckAllArchitectures)
        var validationError: Unmanaged<CFError>?
        let checkStatus = SecStaticCodeCheckValidityWithErrors(staticCode, validationFlags, nil, &validationError)
        guard checkStatus == errSecSuccess else {
            let validationErrorDetail = validationError?.takeRetainedValue()
            return .invalid(errorMessage(for: checkStatus, error: validationErrorDetail))
        }
        validationError?.release()

        guard let signingDictionary = signingInformation(for: staticCode) else {
            return .unknown("The code signature is valid, but signing information could not be read.")
        }

        return .valid(validDetail,
                      teamIdentifier(in: signingDictionary),
                      enabledEntitlementKeys(in: signingDictionary),
                      applicationGroupIdentifiers(in: signingDictionary))
    }

    private static func errorMessage(for status: OSStatus, error: CFError? = nil) -> String {
        let fallback = "Code-signing check failed with OSStatus \(status)."
        let statusMessage = SecCopyErrorMessageString(status, nil) as String? ?? fallback
        guard let error else {
            return statusMessage
        }

        let errorDescription = (CFErrorCopyDescription(error) as String)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !errorDescription.isEmpty else {
            return statusMessage
        }

        return "\(statusMessage) \(errorDescription)"
    }

    private static func signingInformation(for staticCode: SecStaticCode) -> [String: Any]? {
        var signingInformation: CFDictionary?
        let infoStatus = SecCodeCopySigningInformation(staticCode,
                                                       SecCSFlags(rawValue: kSecCSSigningInformation | kSecCSRequirementInformation),
                                                       &signingInformation)
        guard infoStatus == errSecSuccess,
              let signingInformation,
              let signingDictionary = signingInformation as? [String: Any] else {
            return nil
        }

        return signingDictionary
    }

    private static func teamIdentifier(in signingDictionary: [String: Any]?) -> String? {
        guard let signingDictionary,
              let teamIdentifier = signingDictionary[kSecCodeInfoTeamIdentifier as String] as? String,
              !teamIdentifier.isEmpty,
              isTeamIdentifier(teamIdentifier) else {
            return nil
        }

        return teamIdentifier
    }

    private static func isTeamIdentifier(_ teamIdentifier: String) -> Bool {
        return teamIdentifier.range(of: "^[A-Za-z0-9]{10}$", options: .regularExpression) != nil
    }

    private static func enabledEntitlementKeys(in signingDictionary: [String: Any]?) -> Set<String> {
        guard let signingDictionary,
              let entitlementDictionary = signingDictionary[kSecCodeInfoEntitlementsDict as String] as? [String: Any] else {
            return []
        }

        return Set(entitlementDictionary.compactMap { key, value in
            guard let isEnabled = value as? Bool else {
                return nil
            }

            return isEnabled ? key : nil
        })
    }

    private static func applicationGroupIdentifiers(in signingDictionary: [String: Any]?) -> Set<String> {
        guard let signingDictionary,
              let entitlementDictionary = signingDictionary[kSecCodeInfoEntitlementsDict as String] as? [String: Any],
              let entitlementValue = entitlementDictionary["com.apple.security.application-groups"] else {
            return []
        }

        guard let groupIdentifiers = entitlementValue as? [Any] else {
            return []
        }

        var identifiers: Set<String> = []
        for value in groupIdentifiers {
            guard let groupIdentifier = value as? String else {
                return []
            }

            let trimmedGroupIdentifier = groupIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedGroupIdentifier.isEmpty,
                  trimmedGroupIdentifier == groupIdentifier else {
                return []
            }

            identifiers.insert(groupIdentifier)
        }

        return identifiers
    }

    private static func displayApplicationGroups(_ groups: Set<String>) -> String {
        let sortedGroups = groups.sorted()
        return sortedGroups.isEmpty ? "None" : sortedGroups.joined(separator: ", ")
    }

    private static func isExpectedApplicationGroupIdentifier(_ groupIdentifier: String, baseIdentifier: String) -> Bool {
        let escapedBaseIdentifier = NSRegularExpression.escapedPattern(for: baseIdentifier)
        let teamPrefixedPattern = "^[A-Za-z0-9]{10}\\.\(escapedBaseIdentifier)$"
        return groupIdentifier.range(of: teamPrefixedPattern, options: .regularExpression) != nil
    }

    private static func expectedApplicationGroups(_ groups: Set<String>, baseIdentifier: String) -> Set<String> {
        return Set(groups.filter { isExpectedApplicationGroupIdentifier($0, baseIdentifier: baseIdentifier) })
    }

    private static func expectedSharedApplicationGroups(_ appGroups: Set<String>,
                                                        _ extensionGroups: Set<String>,
                                                        baseIdentifier: String) -> Set<String> {
        let appExpectedGroups = expectedApplicationGroups(appGroups, baseIdentifier: baseIdentifier)
        let extensionExpectedGroups = expectedApplicationGroups(extensionGroups, baseIdentifier: baseIdentifier)
        return appExpectedGroups.intersection(extensionExpectedGroups)
    }

    private static func quarantineStatus(for url: URL) -> QuarantineStatus {
        guard FileManager.default.fileExists(atPath: url.path) else {
            return .unknown("Path is missing: \(url.path)")
        }

        return url.withUnsafeFileSystemRepresentation { fileSystemPath in
            guard let fileSystemPath else {
                return .unknown("Path cannot be represented in the file system: \(url.path)")
            }

            return quarantineAttributeName.withCString { attributeName in
                let size = getxattr(fileSystemPath, attributeName, nil, 0, 0, 0)
                if size < 0 {
                    let errorNumber = errno
                    if errorNumber == ENOATTR {
                        return .absent
                    }

                    return .unknown("getxattr failed with errno \(errorNumber).")
                }

                guard size > 0 else {
                    return .present("empty")
                }

                let dataSize = Int(size)
                var data = Data(count: dataSize)
                let readSize = data.withUnsafeMutableBytes { buffer -> ssize_t in
                    guard let baseAddress = buffer.baseAddress else {
                        return 0
                    }

                    return getxattr(fileSystemPath, attributeName, baseAddress, dataSize, 0, 0)
                }

                if readSize < 0 {
                    return .unknown("getxattr failed with errno \(errno).")
                }

                let readableSize = Int(readSize)
                if readableSize < dataSize {
                    data = data.subdata(in: 0..<readableSize)
                }

                return .present(printableQuarantineValue(from: data))
            }
        }
    }

    private static func printableQuarantineValue(from data: Data) -> String {
        if let value = String(data: data, encoding: .utf8) {
            let trimmedValue = value.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmedValue.isEmpty {
                return trimmedValue
            }
        }

        let hexValue = data.map { String(format: "%02x", Int($0)) }.joined()
        return hexValue.isEmpty ? "empty" : "0x\(hexValue)"
    }

    private static func isBundledVideoFailureDetail(_ detail: String) -> Bool {
        return detail.localizedCaseInsensitiveContains("video resource")
            || detail.localizedCaseInsensitiveContains("video.mp4")
            || detail.localizedCaseInsensitiveContains("video metadata")
    }

    private static func isBundledExtensionFailureDetail(_ detail: String) -> Bool {
        return detail.localizedCaseInsensitiveContains("system extensions directory")
            || detail.localizedCaseInsensitiveContains("bundled .systemextension")
            || detail.localizedCaseInsensitiveContains("bundled extension at")
            || detail.localizedCaseInsensitiveContains("Expected bundled extension")
    }

    private static func isExtensionExecutableFailureDetail(_ detail: String) -> Bool {
        return detail.localizedCaseInsensitiveContains("CFBundleExecutable")
            || detail.localizedCaseInsensitiveContains("extension executable")
    }

    private static func isExtensionMetadataFailureDetail(_ detail: String) -> Bool {
        return isBundledExtensionFailureDetail(detail)
            || detail.localizedCaseInsensitiveContains("CMIOExtensionMachServiceName")
            || detail.localizedCaseInsensitiveContains("extension metadata")
    }

    private static func containsUnresolvedBuildSetting(_ value: String) -> Bool {
        return value.contains("$(") || value.contains("${")
    }

    private static func isExpectedMachServiceName(_ machServiceName: String, for extensionIdentifier: String) -> Bool {
        if machServiceName == extensionIdentifier {
            return true
        }

        let escapedExtensionIdentifier = NSRegularExpression.escapedPattern(for: extensionIdentifier)
        let teamPrefixedPattern = "^[A-Za-z0-9]{10}\\.\(escapedExtensionIdentifier)$"
        return machServiceName.range(of: teamPrefixedPattern, options: .regularExpression) != nil
    }

    private func handleReadinessFailure(_ error: Error) {
        let message = error.localizedDescription
        lastFailureDetail = message

        if Self.isExtensionExecutableFailureDetail(message) {
            state = .needsExtensionMetadata
            appendActivity(level: .warning, title: "Extension Executable Required", detail: message)
        } else if Self.isExtensionMetadataFailureDetail(message) {
            state = .needsExtensionMetadata
            appendActivity(level: .warning, title: "Extension Metadata Required", detail: message)
        } else if Self.isBundledVideoFailureDetail(message) {
            state = .needsBundledVideo
            appendActivity(level: .warning, title: "Bundled Video Required", detail: message)
        } else {
            state = .failed(message)
            appendActivity(level: .error, title: "Readiness Failed", detail: message)
        }
    }

    private func copySuccessDetail(_ detail: String, didRefresh: Bool) -> String {
        guard !didRefresh else {
            return detail
        }

        let refreshDetail = lastFailureDetail ?? requestReadinessDetail ?? "Readiness could not be refreshed."
        return "\(detail)\nRefresh found: \(refreshDetail)"
    }

    private func recordReadinessBlock(state: InstallState, title: String, detail: String) {
        self.state = state
        lastFailureDetail = detail
        appendActivity(level: .warning, title: title, detail: detail)
    }

    private func appendActivity(level: ActivityItem.Level, title: String, detail: String) {
        if let firstActivity = activity.first,
           firstActivity.level == level,
           firstActivity.title == title,
           firstActivity.detail == detail {
            activity.removeFirst()
        }

        let item = ActivityItem(level: level, title: title, detail: detail)
        activity.insert(item, at: 0)

        if activity.count > 20 {
            activity.removeLast(activity.count - 20)
        }
    }
}

extension SystemExtensionRequestManager: @preconcurrency OSSystemExtensionRequestDelegate {
    public func request(_ request: OSSystemExtensionRequest, actionForReplacingExtension existing: OSSystemExtensionProperties, withExtension ext: OSSystemExtensionProperties) -> OSSystemExtensionRequest.ReplacementAction {
        appendActivity(level: .info,
                       title: "Replacing Extension",
                       detail: "\(Self.displayVersion(for: existing)) -> \(Self.displayVersion(for: ext))")
        return .replace
    }

    public func requestNeedsUserApproval(_ request: OSSystemExtensionRequest) {
        let requestKind = pendingRequestKind ?? .activation
        state = .needsApproval
        appendActivity(level: .warning,
                       title: "Approval Required",
                       detail: requestKind.approvalDetail)
    }

    public func request(_ request: OSSystemExtensionRequest, didFinishWithResult result: OSSystemExtensionRequest.Result) {
        let requestKind = pendingRequestKind ?? .activation

        switch result {
        case .completed:
            pendingRequestKind = nil
            lastFailureDetail = nil
            state = requestKind.completedState
            appendActivity(level: .success,
                           title: requestKind.completedTitle,
                           detail: requestKind.completedDetail)
        case .willCompleteAfterReboot:
            pendingRequestKind = requestKind
            lastFailureDetail = nil
            state = .requiresRestart
            appendActivity(level: .warning,
                           title: "Restart Required",
                           detail: requestKind.restartDetail)
        @unknown default:
            pendingRequestKind = nil
            lastFailureDetail = nil
            state = .ready
            appendActivity(level: .info,
                           title: "Request Completed",
                           detail: "macOS returned result \(result.rawValue).")
        }
    }

    public func request(_ request: OSSystemExtensionRequest, didFailWithError error: Error) {
        let nsError = error as NSError
        let errorCode = nsError.code
        let errorString: String
        switch errorCode {
        case 1:
            errorString = "unknown error"
        case 2:
            errorString = "missing entitlement"
        case 3:
            errorString = "container app is outside /Applications"
        case 4:
            errorString = "extension not found"
        case 5:
            errorString = "extension missing identifier"
        case 6:
            errorString = "duplicate extension identifier"
        case 7:
            errorString = "unknown extension category"
        case 8:
            errorString = "code signature invalid"
        case 9:
            errorString = "validation failed"
        case 10:
            errorString = "forbidden by system policy"
        case 11:
            errorString = "request canceled"
        case 12:
            errorString = "request superseded"
        case 13:
            errorString = "authorization required"
        default:
            errorString = "unknown code \(errorCode)"
        }
        let failureDetail = "\(errorString) (\(nsError.domain) \(errorCode)): \(nsError.localizedDescription)"
        state = .failed(errorString)
        pendingRequestKind = nil
        lastFailureDetail = failureDetail
        appendActivity(level: .error,
                       title: "Request Failed",
                       detail: failureDetail)
    }
}

enum ExtensionRequestError: LocalizedError {
    case missingExtensionsDirectory(String)
    case missingBundledExtension
    case multipleBundledExtensions(String)
    case unreadableExtensionBundle(String)
    case missingBundleIdentifier(String)
    case missingExtensionExecutable(String)
    case invalidExtensionExecutableName(String, String)
    case invalidExtensionExecutable(String)
    case missingExtensionMachService(String)
    case missingBundledVideoResource(String)
    case emptyBundledVideoResource(String)
    case unreadableBundledVideoMetadata(String)
    case unexpectedBundleIdentifier(expected: String, actual: String)

    var errorDescription: String? {
        switch self {
        case .missingExtensionsDirectory(let path):
            return "No system extensions directory exists at \(path)."
        case .missingBundledExtension:
            return "No bundled .systemextension was found."
        case .multipleBundledExtensions(let bundleNames):
            return "Expected exactly one bundled .systemextension, but found \(bundleNames)."
        case .unreadableExtensionBundle(let path):
            return "The bundled extension at \(path) could not be opened."
        case .missingBundleIdentifier(let path):
            return "The bundled extension at \(path) does not declare a bundle identifier."
        case .missingExtensionExecutable(let path):
            return "The bundled extension at \(path) does not declare CFBundleExecutable."
        case .invalidExtensionExecutableName(let executableName, let path):
            return "The bundled extension at \(path) declares invalid CFBundleExecutable \(executableName)."
        case .invalidExtensionExecutable(let path):
            return "The bundled extension executable at \(path) is missing or is not executable."
        case .missingExtensionMachService(let path):
            return "The bundled extension at \(path) does not declare CMIOExtensionMachServiceName."
        case .missingBundledVideoResource(let path):
            return "The bundled extension does not include the required video resource at \(path)."
        case .emptyBundledVideoResource(let path):
            return "The bundled extension video resource at \(path) is empty."
        case .unreadableBundledVideoMetadata(let path):
            return "The bundled extension video resource at \(path) could not be read for video metadata."
        case .unexpectedBundleIdentifier(let expected, let actual):
            return "Expected bundled extension \(expected), but found \(actual)."
        }
    }
}

private struct SidebarView: View {
    @ObservedObject var manager: SystemExtensionRequestManager
    @Binding var selectedSection: DashboardSection?

    var body: some View {
        List(selection: $selectedSection) {
            Section {
                HStack(spacing: 10) {
                    Image(systemName: "video.circle.fill")
                        .symbolRenderingMode(.hierarchical)
                        .font(.system(size: 28, weight: .semibold))
                        .foregroundStyle(.blue)

                    VStack(alignment: .leading, spacing: 3) {
                        Text("Gareth Video Cam")
                            .font(.headline)
                        Text(manager.state.title)
                            .font(.caption)
                            .foregroundStyle(manager.state.tint)
                    }
                }
                .padding(.vertical, 6)
            }

            Section("Camera") {
                ForEach(DashboardSection.allCases, id: \.self) { section in
                    NavigationLink(value: section) {
                        Label(section.title, systemImage: section.systemImage)
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .navigationTitle("Controls")
    }
}

private struct DashboardView: View {
    @ObservedObject var manager: SystemExtensionRequestManager
    var selectedSection: DashboardSection

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                HeaderView(manager: manager)

                switch selectedSection {
                case .overview:
                    ActionPanel(manager: manager)
                    ReadinessPanel(manager: manager)
                case .evidence:
                    RuntimeEvidencePanel(manager: manager)
                case .activity:
                    ActivityPanel(items: manager.activity)
                }

                switch selectedSection {
                case .overview, .evidence:
                    DetailsPanel(manager: manager)
                    ActivityPanel(items: Array(manager.activity.prefix(5)))
                case .activity:
                    EmptyView()
                }
            }
            .padding(28)
            .frame(maxWidth: 920, alignment: .leading)
        }
    }
}

private struct RuntimeEvidencePanel: View {
    @ObservedObject var manager: SystemExtensionRequestManager

    var body: some View {
        SectionSurface {
            VStack(alignment: .leading, spacing: 14) {
                Text("Runtime Evidence")
                    .font(.title3.weight(.semibold))

                DetailRow(title: "Current Readiness", value: manager.requestReadinessStatus)
                DetailRow(title: "Next Action", value: manager.requestReadinessNextAction)
                DetailRow(title: "Command Source", value: manager.runtimeDiagnosticsCommandSource)
                DetailRow(title: "Diagnostics Command", value: manager.runtimeDiagnosticsCommand, monospaced: true)

                VStack(spacing: 0) {
                    ForEach(Array(manager.runtimeEvidenceChecks.enumerated()), id: \.element.id) { index, check in
                        DetailRow(title: check.title, value: check.expectedValue)
                            .padding(.vertical, 8)

                        if index < manager.runtimeEvidenceChecks.count - 1 {
                            Divider()
                        }
                    }
                }

                runtimeEvidenceActions
            }
        }
    }

    private var runtimeEvidenceActions: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 10) {
                actionButtons
            }

            VStack(alignment: .leading, spacing: 10) {
                actionButtons
            }
        }
        .padding(.top, 4)
    }

    @ViewBuilder
    private var actionButtons: some View {
        Button(action: manager.copyRuntimeDiagnosticsCommand) {
            Label("Copy Command", systemImage: "terminal")
        }
        .buttonStyle(.bordered)
        .help("Copy the runtime diagnostics command.")

        Button(action: manager.copyRuntimeEvidenceExpectedDiagnostics) {
            Label("Copy Expected Lines", systemImage: "checkmark.seal")
        }
        .buttonStyle(.bordered)
        .help("Copy the expected signed-host diagnostics lines.")

        Button(action: manager.copyActivationChecklist) {
            Label("Copy Checklist", systemImage: "checklist")
        }
        .buttonStyle(.bordered)
        .help("Copy the signed runtime activation checklist.")

        Button(action: manager.copyDiagnostics) {
            Label("Copy Diagnostics", systemImage: "doc.on.doc")
        }
        .buttonStyle(.bordered)
        .help("Copy the current readiness and diagnostics snapshot.")
    }
}

private struct HeaderView: View {
    @ObservedObject var manager: SystemExtensionRequestManager

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            Image(systemName: "video.fill")
                .font(.system(size: 34, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 64, height: 64)
                .background(Color.blue, in: RoundedRectangle(cornerRadius: 8, style: .continuous))

            VStack(alignment: .leading, spacing: 8) {
                Text("Gareth Video Cam")
                    .font(.system(size: 34, weight: .semibold, design: .default))
                StatusBadge(state: manager.state)
                Text(manager.requestReadinessDetail ?? "System extension requests can be submitted.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }

            Spacer()
        }
    }
}

private struct ActionPanel: View {
    @ObservedObject var manager: SystemExtensionRequestManager

    var body: some View {
        SectionSurface {
            VStack(alignment: .leading, spacing: 14) {
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .center, spacing: 12) {
                        extensionIdentity
                            .layoutPriority(1)

                        Spacer(minLength: 16)

                        requestButtons
                    }

                    VStack(alignment: .leading, spacing: 12) {
                        extensionIdentity
                        requestButtons
                    }
                }

                if let requestReadinessMessage = manager.requestReadinessMessage {
                    Label(requestReadinessMessage, systemImage: "exclamationmark.triangle.fill")
                        .font(.callout)
                        .foregroundStyle(.orange)
                }

                Label(manager.requestReadinessNextAction, systemImage: "arrow.right.circle.fill")
                    .font(.callout)
                    .foregroundStyle(manager.canSubmitSystemExtensionRequests ? .blue : .orange)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)

                if let stateGuidanceDetail = manager.stateGuidanceDetail {
                    Label(stateGuidanceDetail, systemImage: manager.state.systemImage)
                        .font(.callout)
                        .foregroundStyle(manager.state.tint)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if manager.state == .needsApproval {
                    approvalButton
                }
            }
        }
    }

    @ViewBuilder
    private var extensionIdentity: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Camera Extension")
                .font(.title3.weight(.semibold))
            Text(manager.extensionInfo?.identifier ?? "No bundled extension")
                .font(.callout.monospaced())
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        }
    }

    @ViewBuilder
    private var requestButtons: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 10) {
                installButton
                uninstallButton
            }

            VStack(alignment: .leading, spacing: 10) {
                installButton
                uninstallButton
            }
        }
    }

    @ViewBuilder
    private var installButton: some View {
        Button(action: manager.install) {
            Label("Install", systemImage: "arrow.down.circle.fill")
        }
        .buttonStyle(.borderedProminent)
        .disabled(manager.isBusy || !manager.canSubmitActivationRequest)
        .help("Submit a macOS system extension activation request.")
    }

    @ViewBuilder
    private var uninstallButton: some View {
        Button(action: manager.uninstall) {
            Label("Uninstall", systemImage: "trash")
        }
        .buttonStyle(.bordered)
        .disabled(manager.isBusy || !manager.canSubmitDeactivationRequest)
        .help("Submit a macOS system extension deactivation request.")
    }

    @ViewBuilder
    private var approvalButton: some View {
        Button(action: manager.openSystemSettings) {
            Label("Open System Settings", systemImage: "gearshape")
        }
        .buttonStyle(.borderedProminent)
        .help("Open System Settings to approve the pending camera extension request.")
    }
}

private struct ReadinessPanel: View {
    @ObservedObject var manager: SystemExtensionRequestManager

    var body: some View {
        let checks = manager.readinessChecks

        SectionSurface {
            VStack(alignment: .leading, spacing: 14) {
                Text("Readiness")
                    .font(.title3.weight(.semibold))
                Text(manager.readinessProgressSummary)
                    .font(.callout)
                    .foregroundStyle(.secondary)

                VStack(spacing: 0) {
                    ForEach(Array(checks.enumerated()), id: \.element.id) { index, check in
                        ReadinessRow(check: check)
                            .padding(.vertical, 10)

                        if index < checks.count - 1 {
                            Divider()
                        }
                    }
                }
            }
        }
    }
}

private struct ReadinessRow: View {
    var check: SystemExtensionRequestManager.ReadinessCheck

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: check.status.symbolName)
                .foregroundStyle(check.status.color)
                .frame(width: 18)

            VStack(alignment: .leading, spacing: 4) {
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .firstTextBaseline) {
                        readinessTitle
                        Spacer(minLength: 12)
                        readinessStatus
                    }

                    VStack(alignment: .leading, spacing: 2) {
                        readinessTitle
                        readinessStatus
                    }
                }

                readinessDetail
            }
        }
    }

    @ViewBuilder
    private var readinessTitle: some View {
        Text(check.title)
            .font(.callout.weight(.semibold))
            .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder
    private var readinessDetail: some View {
        Text(check.detail)
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .textSelection(.enabled)
    }

    @ViewBuilder
    private var readinessStatus: some View {
        Text(check.status.title)
            .font(.caption.weight(.semibold))
            .foregroundStyle(check.status.color)
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
    }
}

private struct DetailsPanel: View {
    @ObservedObject var manager: SystemExtensionRequestManager

    var body: some View {
        SectionSurface {
            VStack(alignment: .leading, spacing: 14) {
                Text("Build")
                    .font(.title3.weight(.semibold))

                DetailRow(title: "macOS Version", value: manager.hostOperatingSystemVersion)
                DetailRow(title: "App Version", value: manager.applicationVersion)
                DetailRow(title: "App Bundle Short Version", value: manager.applicationShortVersion)
                DetailRow(title: "App Bundle Build Version", value: manager.applicationBuildVersion)
                DetailRow(title: "Bundle Version Check", value: manager.bundleVersionStatus)
                DetailRow(title: "Bundle Short Version Match", value: manager.bundleShortVersionMatchStatus)
                DetailRow(title: "Bundle Build Version Match", value: manager.bundleBuildVersionMatchStatus)
                DetailRow(title: "App Bundle ID", value: manager.applicationBundleIdentifier)
                DetailRow(title: "App Bundle ID Check", value: manager.applicationBundleIdentifierStatus)
                DetailRow(title: "Expected App ID", value: manager.expectedApplicationIdentifier)
                DetailRow(title: "Expected Extension ID", value: manager.expectedExtensionIdentifier)
                DetailRow(title: "Extension Version", value: manager.extensionInfo?.version ?? "Unknown")
                DetailRow(title: "Extension Bundle Short Version", value: manager.extensionInfo?.shortVersion ?? "Unknown")
                DetailRow(title: "Extension Bundle Build Version", value: manager.extensionInfo?.buildVersion ?? "Unknown")
                DetailRow(title: "Application Location", value: manager.applicationLocationStatus)
                DetailRow(title: "Expected App Path", value: manager.expectedApplicationPath, monospaced: true)
                DetailRow(title: "App Executable Check", value: manager.applicationExecutableStatus)
                DetailRow(title: "App Executable Path", value: manager.applicationExecutablePath, monospaced: true)
                DetailRow(title: "App Quarantine", value: manager.appQuarantineStatus.title)
                DetailRow(title: "App Quarantine Detail", value: manager.appQuarantineStatus.detail, monospaced: true)
                DetailRow(title: "Request Readiness", value: manager.requestReadinessStatus)
                DetailRow(title: "Activation Request Readiness", value: manager.activationRequestReadinessStatus)
                DetailRow(title: "Activation Request Detail", value: manager.activationRequestReadinessDetail)
                DetailRow(title: "Deactivation Request Readiness", value: manager.deactivationRequestReadinessStatus)
                DetailRow(title: "Deactivation Request Detail", value: manager.deactivationRequestReadinessDetail)
                DetailRow(title: "Runtime Command Source", value: manager.runtimeDiagnosticsCommandSource)
                DetailRow(title: "Pending Request", value: manager.pendingRequestStatus)
                if let stateGuidanceDetail = manager.stateGuidanceDetail {
                    DetailRow(title: "State Guidance", value: stateGuidanceDetail)
                }
                if let requestReadinessDetail = manager.requestReadinessDetail {
                    DetailRow(title: "Readiness Detail", value: requestReadinessDetail)
                }
                DetailRow(title: "Readiness Next Action", value: manager.requestReadinessNextAction)
                if let lastFailureDetail = manager.lastFailureDetail {
                    DetailRow(title: "Last Failure", value: lastFailureDetail)
                }
                DetailRow(title: "App Signature", value: manager.appCodeSigningStatus.title)
                if !manager.appCodeSigningStatus.isValid {
                    DetailRow(title: "App Signature Detail", value: manager.appCodeSigningStatus.detail)
                }
                DetailRow(title: "System Extension Entitlement", value: manager.appSystemExtensionEntitlementStatus)
                DetailRow(title: "App Application Groups", value: manager.appApplicationGroups, monospaced: true)
                DetailRow(title: "App Team ID", value: manager.appTeamIdentifier)
                DetailRow(title: "Extension Signature", value: manager.extensionCodeSigningStatus.title)
                if !manager.extensionCodeSigningStatus.isValid {
                    DetailRow(title: "Extension Signature Detail", value: manager.extensionCodeSigningStatus.detail)
                }
                if let extensionLoadFailureDetail = manager.extensionLoadFailureDetail {
                    DetailRow(title: "Extension Load Failure", value: extensionLoadFailureDetail)
                }
                DetailRow(title: "Extension Quarantine", value: manager.extensionQuarantineStatus.title)
                DetailRow(title: "Extension Quarantine Detail", value: manager.extensionQuarantineStatus.detail, monospaced: true)
                DetailRow(title: "Extension Host-Only Entitlement", value: manager.extensionHostOnlyEntitlementStatus)
                DetailRow(title: "Extension Application Groups", value: manager.extensionApplicationGroups, monospaced: true)
                DetailRow(title: "Application Group Check", value: manager.applicationGroupStatus)
                DetailRow(title: "Shared Application Group", value: manager.sharedApplicationGroupDescription, monospaced: true)
                DetailRow(title: "Extension Team ID", value: manager.extensionTeamIdentifier)
                DetailRow(title: "Extension Executable Check", value: manager.extensionExecutableStatus)
                DetailRow(title: "Extension Metadata", value: manager.extensionMetadataStatus)
                DetailRow(title: "Extension CMIO Mach Service Resolved", value: manager.extensionMachServiceResolvedStatus)
                DetailRow(title: "Extension CMIO Mach Service Identifier Match", value: manager.extensionMachServiceIdentifierMatchStatus)
                DetailRow(title: "Bundled Video", value: manager.bundledVideoReadinessStatus)
                DetailRow(title: "Application Path", value: manager.applicationBundlePath, monospaced: true)

                if let bundlePath = manager.extensionInfo?.bundlePath {
                    DetailRow(title: "Extension Bundle Path", value: bundlePath, monospaced: true)
                }
                if let executableName = manager.extensionInfo?.executableName {
                    DetailRow(title: "Extension Executable", value: executableName, monospaced: true)
                }
                if let executablePath = manager.extensionInfo?.executablePath {
                    DetailRow(title: "Extension Executable Path", value: executablePath, monospaced: true)
                }
                if let machServiceName = manager.extensionInfo?.machServiceName {
                    DetailRow(title: "Extension CMIO Mach Service", value: machServiceName, monospaced: true)
                }
                if let videoPath = manager.extensionInfo?.videoPath {
                    DetailRow(title: "Bundled Video Path", value: videoPath, monospaced: true)
                    DetailRow(title: "Bundled Video Size", value: manager.bundledVideoSize)
                    DetailRow(title: "Bundled Video Dimensions", value: manager.bundledVideoDimensions)
                    DetailRow(title: "Bundled Video Frame Rate", value: manager.bundledVideoFrameRate)
                    DetailRow(title: "Bundled Video Duration", value: manager.bundledVideoDuration)
                }

                DetailsActions(manager: manager)
            }
        }
    }
}

private struct DetailsActions: View {
    @ObservedObject var manager: SystemExtensionRequestManager

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 10) {
                actionButtons
            }

            VStack(alignment: .leading, spacing: 10) {
                actionButtons
            }
        }
        .padding(.top, 4)
    }

    @ViewBuilder
    private var actionButtons: some View {
        Button(action: manager.refreshStatus) {
            Label("Refresh Status", systemImage: "arrow.clockwise")
        }
        .buttonStyle(.bordered)
        .help("Refresh app, extension, signing, and readiness status.")

        Button(action: manager.openSystemSettings) {
            Label("System Settings", systemImage: "gearshape")
        }
        .buttonStyle(.bordered)
        .help("Open System Settings for extension approval.")

        Button(action: manager.copyDiagnostics) {
            Label("Copy Diagnostics", systemImage: "doc.on.doc")
        }
        .buttonStyle(.bordered)
        .help("Copy the current readiness and diagnostics snapshot.")

        Button(action: manager.copyActivationChecklist) {
            Label("Copy Checklist", systemImage: "checklist")
        }
        .buttonStyle(.bordered)
        .help("Copy the signed runtime activation checklist.")

        Button(action: manager.copyRuntimeDiagnosticsCommand) {
            Label("Copy Command", systemImage: "terminal")
        }
        .buttonStyle(.bordered)
        .help("Copy the runtime diagnostics command.")

        Button(action: manager.copyRuntimeEvidenceExpectedDiagnostics) {
            Label("Copy Expected Lines", systemImage: "checkmark.seal")
        }
        .buttonStyle(.bordered)
        .help("Copy the expected signed-host diagnostics lines.")

        Button(action: manager.revealApplicationInFinder) {
            Label("Reveal App", systemImage: "folder")
        }
        .buttonStyle(.bordered)
        .help("Reveal the running app bundle in Finder.")

        Button(action: manager.revealBundledExtensionInFinder) {
            Label("Reveal Extension", systemImage: "folder")
        }
        .buttonStyle(.bordered)
        .disabled(!manager.canRevealBundledExtension)
        .help("Reveal the embedded system extension bundle in Finder.")
    }
}

private struct ActivityPanel: View {
    var items: [SystemExtensionRequestManager.ActivityItem]

    var body: some View {
        SectionSurface {
            VStack(alignment: .leading, spacing: 14) {
                Text("Activity")
                    .font(.title3.weight(.semibold))

                if items.isEmpty {
                    Text("No activity yet")
                        .foregroundStyle(.secondary)
                } else {
                    VStack(spacing: 0) {
                        ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                            ActivityRow(item: item)
                                .padding(.vertical, 10)

                            if index < items.count - 1 {
                                Divider()
                            }
                        }
                    }
                }
            }
        }
    }
}

private struct ActivityRow: View {
    var item: SystemExtensionRequestManager.ActivityItem

    private static let timestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .medium
        return formatter
    }()

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: item.level.symbolName)
                .foregroundStyle(item.level.color)
                .frame(width: 18)

            VStack(alignment: .leading, spacing: 3) {
                ViewThatFits(in: .horizontal) {
                    HStack {
                        activityTitle
                        Spacer()
                        activityTimestamp
                    }

                    VStack(alignment: .leading, spacing: 2) {
                        activityTitle
                        activityTimestamp
                    }
                }
                activityDetail
            }
        }
    }

    @ViewBuilder
    private var activityTitle: some View {
        Text(item.title)
            .font(.callout.weight(.semibold))
            .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder
    private var activityDetail: some View {
        Text(item.detail)
            .font(.callout)
            .foregroundStyle(.secondary)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var activityTimestamp: some View {
        Text(Self.timestampFormatter.string(from: item.date))
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
    }
}

private struct DetailRow: View {
    private static let titleColumnWidth: CGFloat = 220

    var title: String
    var value: String
    var monospaced = false

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                titleLabel
                    .frame(width: Self.titleColumnWidth, alignment: .leading)
                valueText
            }

            VStack(alignment: .leading, spacing: 4) {
                titleLabel
                valueText
            }
        }
    }

    @ViewBuilder
    private var titleLabel: some View {
        Text(title)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder
    private var valueText: some View {
        Text(value)
            .font(monospaced ? .callout.monospaced() : .callout)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct StatusBadge: View {
    var state: SystemExtensionRequestManager.InstallState

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: state.systemImage)
            Text(state.title)
        }
        .font(.callout.weight(.semibold))
        .foregroundStyle(state.tint)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(state.tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

private struct SectionSurface<Content: View>: View {
    private let content: () -> Content

    init(@ViewBuilder content: @escaping () -> Content) {
        self.content = content
    }

    var body: some View {
        content()
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(Color(nsColor: .separatorColor).opacity(0.55), lineWidth: 1)
            }
    }
}
