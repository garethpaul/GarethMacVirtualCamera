//
//  ContentView.swift
//

import Foundation
import AppKit
import Security
import SwiftUI
import SystemExtensions

struct ContentView: View {
    @ObservedObject var systemExtensionRequestManager: SystemExtensionRequestManager
    @State private var selectedSection: DashboardSection? = .overview

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
            systemExtensionRequestManager.refreshExtensionInfo()
        }
    }
}

struct ContentView_Previews: PreviewProvider {
    static var previews: some View {
        ContentView(systemExtensionRequestManager: SystemExtensionRequestManager(logText: ""))
    }
}

private enum DashboardSection: String, CaseIterable, Hashable {
    case overview
    case activity

    var title: String {
        switch self {
        case .overview:
            return "Overview"
        case .activity:
            return "Activity"
        }
    }

    var systemImage: String {
        switch self {
        case .overview:
            return "rectangle.grid.2x2"
        case .activity:
            return "list.bullet.rectangle"
        }
    }
}

class SystemExtensionRequestManager: NSObject, ObservableObject {
    private let expectedApplicationBundleIdentifier = "com.garethpaul.GarethVideoCam"
    private let expectedExtensionBundleIdentifier = "com.garethpaul.GarethVideoCam.Extension"
    private let requiredSystemExtensionInstallEntitlement = "com.apple.developer.system-extension.install"

    enum InstallState: Equatable {
        case idle
        case ready
        case needsApplicationLocation
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

    struct ExtensionInfo: Equatable {
        var identifier: String
        var version: String
        var bundlePath: String
        var videoPath: String
        var videoByteCount: Int64
    }

    struct ActivityItem: Identifiable, Equatable {
        enum Level {
            case info
            case success
            case warning
            case error

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

    enum CodeSigningStatus: Equatable {
        case valid(String, String?, Set<String>)
        case invalid(String)

        var title: String {
            switch self {
            case .valid:
                return "Valid"
            case .invalid:
                return "Invalid"
            }
        }

        var detail: String {
            switch self {
            case .valid(let detail, _, _):
                return detail
            case .invalid(let detail):
                return detail
            }
        }

        var isValid: Bool {
            switch self {
            case .valid:
                return true
            case .invalid:
                return false
            }
        }

        var teamIdentifier: String? {
            switch self {
            case .valid(_, let teamIdentifier, _):
                return teamIdentifier
            case .invalid:
                return nil
            }
        }

        func hasEnabledEntitlement(_ entitlement: String) -> Bool {
            switch self {
            case .valid(_, _, let enabledEntitlementKeys):
                return enabledEntitlementKeys.contains(entitlement)
            case .invalid:
                return false
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
    }

    @Published var state: InstallState = .idle
    @Published var extensionInfo: ExtensionInfo?
    @Published var activity: [ActivityItem] = []
    @Published var appCodeSigningStatus: CodeSigningStatus = .invalid("App code-signing status has not been checked yet.")
    @Published var extensionCodeSigningStatus: CodeSigningStatus = .invalid("System extension code-signing status has not been checked yet.")
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
        return isRunningFromApplications ? "In Applications" : "Outside Applications"
    }

    var applicationBundlePath: String {
        return Bundle.main.bundleURL.path
    }

    var applicationVersion: String {
        let shortVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        let buildVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String

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

    var applicationBundleIdentifier: String {
        return Bundle.main.bundleIdentifier ?? "Unknown"
    }

    var expectedApplicationIdentifier: String {
        return expectedApplicationBundleIdentifier
    }

    var expectedExtensionIdentifier: String {
        return expectedExtensionBundleIdentifier
    }

    var canSubmitSystemExtensionRequests: Bool {
        return isRunningFromApplications
            && appCodeSigningStatus.isValid
            && appEntitlementReadinessDetail == nil
            && extensionCodeSigningStatus.isValid
            && signingTeamReadinessDetail == nil
    }

    var isRunningFromApplications: Bool {
        return applicationBundlePath.hasPrefix("/Applications/")
    }

    var requestReadinessMessage: String? {
        if !isRunningFromApplications {
            return "System extension requests require /Applications."
        }

        if !appCodeSigningStatus.isValid {
            return "System extension requests require a valid app signature."
        }

        if appEntitlementReadinessDetail != nil {
            return "System extension requests require the app System Extension entitlement."
        }

        if !extensionCodeSigningStatus.isValid {
            return "System extension requests require a valid system extension signature."
        }

        if signingTeamReadinessDetail != nil {
            return "System extension requests require matching app and extension team identifiers."
        }

        return nil
    }

    var requestReadinessStatus: String {
        return canSubmitSystemExtensionRequests ? "Ready" : "Blocked"
    }

    var requestReadinessDetail: String? {
        if !isRunningFromApplications {
            return "The app must run from /Applications/GarethVideoCam.app before macOS will accept system extension requests."
        }

        if !appCodeSigningStatus.isValid {
            return appCodeSigningStatus.detail
        }

        if let appEntitlementReadinessDetail {
            return appEntitlementReadinessDetail
        }

        if !extensionCodeSigningStatus.isValid {
            return extensionCodeSigningStatus.detail
        }

        if let signingTeamReadinessDetail {
            return signingTeamReadinessDetail
        }

        return nil
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

    var diagnosticGeneratedAt: String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: Date())
    }

    var bundledVideoSize: String {
        guard let videoByteCount = extensionInfo?.videoByteCount else {
            return "Unknown"
        }

        return ByteCountFormatter.string(fromByteCount: videoByteCount, countStyle: .file)
    }

    var diagnosticSummary: String {
        let extensionDescription: String
        if let extensionInfo {
            extensionDescription = """
            Extension ID: \(extensionInfo.identifier)
            Extension Version: \(extensionInfo.version)
            Extension Path: \(extensionInfo.bundlePath)
            Bundled Video Path: \(extensionInfo.videoPath)
            Bundled Video Size: \(bundledVideoSize)
            """
        } else {
            extensionDescription = "Extension: No bundled extension loaded"
        }

        let recentActivity = activity
            .prefix(8)
            .map { "\($0.title): \($0.detail)" }
            .joined(separator: "\n")

        return """
        Gareth Video Cam Diagnostics
        Generated At: \(diagnosticGeneratedAt)
        State: \(state.title)
        App Version: \(applicationVersion)
        Expected App ID: \(expectedApplicationIdentifier)
        Actual App ID: \(applicationBundleIdentifier)
        Expected Extension ID: \(expectedExtensionIdentifier)
        App Location: \(applicationLocationStatus)
        App Path: \(applicationBundlePath)
        Request Readiness: \(requestReadinessStatus)
        Request Readiness Detail: \(requestReadinessDetail ?? "System extension requests can be submitted.")
        Last Failure: \(lastFailureDetail ?? "No failure recorded.")
        App Code Signing: \(appCodeSigningStatus.title)
        App Code Signing Detail: \(appCodeSigningStatus.detail)
        App System Extension Entitlement: \(appSystemExtensionEntitlementStatus)
        App Team ID: \(appTeamIdentifier)
        Extension Code Signing: \(extensionCodeSigningStatus.title)
        Extension Code Signing Detail: \(extensionCodeSigningStatus.detail)
        Extension Team ID: \(extensionTeamIdentifier)
        \(extensionDescription)

        Recent Activity:
        \(recentActivity.isEmpty ? "No activity yet" : recentActivity)
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
        guard let extensionInfo = prepareForSystemExtensionRequest() else { return }

        state = .deactivating
        pendingRequestKind = .deactivation
        lastFailureDetail = nil
        appendActivity(level: .info,
                       title: "Uninstall Requested",
                       detail: extensionInfo.identifier)

        let deactivationRequest = OSSystemExtensionRequest.deactivationRequest(forExtensionWithIdentifier: extensionInfo.identifier,
                                                                               queue: .main)
        deactivationRequest.delegate = self
        OSSystemExtensionManager.shared.submitRequest(deactivationRequest)
    }

    func refreshExtensionInfo() {
        appCodeSigningStatus = Self.evaluateCodeSigningStatus(for: Bundle.main.bundleURL,
                                                              validDetail: "The app bundle code signature is valid.")

        do {
            let loadedExtensionInfo = try loadBundledExtensionInfo()
            extensionInfo = loadedExtensionInfo
            extensionCodeSigningStatus = Self.evaluateCodeSigningStatus(for: URL(fileURLWithPath: loadedExtensionInfo.bundlePath),
                                                                        validDetail: "The embedded system extension code signature is valid.")

            switch state {
            case .idle, .ready, .needsApplicationLocation, .needsSigning, .deactivated, .failed:
                state = readinessState
            default:
                break
            }
        } catch {
            extensionInfo = nil
            extensionCodeSigningStatus = .invalid("System extension code-signing status could not be checked: \(error.localizedDescription)")
            handleFailure(error)
        }
    }

    func copyDiagnostics() {
        refreshExtensionInfo()

        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        let didCopyDiagnostics = pasteboard.setString(diagnosticSummary, forType: .string)

        if didCopyDiagnostics {
            appendActivity(level: .success,
                           title: "Diagnostics Copied",
                           detail: "Copied current app and extension status to the clipboard.")
        } else {
            appendActivity(level: .error,
                           title: "Diagnostics Copy Failed",
                           detail: "macOS did not accept the diagnostics text on the clipboard.")
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
        let settingsURL = URL(fileURLWithPath: "/System/Applications/System Settings.app")
        let didOpenSettings = NSWorkspace.shared.open(settingsURL)

        if didOpenSettings {
            appendActivity(level: .info,
                           title: "System Settings Opened",
                           detail: "Approve the camera extension if macOS is waiting for user approval.")
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

        var unexpectedIdentifiers: [String] = []
        for extensionURL in extensionBundleURLs {
            guard let extensionBundle = Bundle(url: extensionURL) else {
                throw ExtensionRequestError.unreadableExtensionBundle(extensionURL.path)
            }

            guard let identifier = extensionBundle.bundleIdentifier else {
                throw ExtensionRequestError.missingBundleIdentifier(extensionURL.path)
            }

            guard identifier == expectedExtensionBundleIdentifier else {
                unexpectedIdentifiers.append(identifier)
                continue
            }

            let version = extensionBundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
                ?? extensionBundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String
                ?? "Unknown"
            let videoURL = extensionURL
                .appendingPathComponent("Contents")
                .appendingPathComponent("Resources")
                .appendingPathComponent("video.mp4")
            let videoByteCount = try Self.bundledVideoByteCount(at: videoURL)

            return ExtensionInfo(identifier: identifier,
                                 version: version,
                                 bundlePath: extensionURL.path,
                                 videoPath: videoURL.path,
                                 videoByteCount: videoByteCount)
        }

        throw ExtensionRequestError.unexpectedBundleIdentifier(expected: expectedExtensionBundleIdentifier,
                                                              actual: unexpectedIdentifiers.joined(separator: ", "))
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

    private func prepareForSystemExtensionRequest() -> ExtensionInfo? {
        appCodeSigningStatus = Self.evaluateCodeSigningStatus(for: Bundle.main.bundleURL,
                                                              validDetail: "The app bundle code signature is valid.")

        guard isRunningFromApplications else {
            state = .needsApplicationLocation
            appendActivity(level: .warning,
                           title: "Move Required",
                           detail: "Current path is \(applicationBundlePath).")
            return nil
        }

        guard appCodeSigningStatus.isValid else {
            state = .needsSigning
            appendActivity(level: .warning,
                           title: "Signing Required",
                           detail: appCodeSigningStatus.detail)
            return nil
        }

        if let appEntitlementReadinessDetail {
            state = .needsSigning
            appendActivity(level: .warning,
                           title: "Entitlement Required",
                           detail: appEntitlementReadinessDetail)
            return nil
        }

        state = .locatingExtension
        let extensionInfo: ExtensionInfo
        do {
            extensionInfo = try loadBundledExtensionInfo()
            self.extensionInfo = extensionInfo
            extensionCodeSigningStatus = Self.evaluateCodeSigningStatus(for: URL(fileURLWithPath: extensionInfo.bundlePath),
                                                                        validDetail: "The embedded system extension code signature is valid.")
        } catch {
            extensionCodeSigningStatus = .invalid("System extension code-signing status could not be checked: \(error.localizedDescription)")
            handleFailure(error)
            return nil
        }

        guard extensionCodeSigningStatus.isValid else {
            state = .needsSigning
            appendActivity(level: .warning,
                           title: "Extension Signing Required",
                           detail: extensionCodeSigningStatus.detail)
            return nil
        }

        if let signingTeamReadinessDetail {
            state = .needsSigning
            appendActivity(level: .warning,
                           title: "Team Identifier Required",
                           detail: signingTeamReadinessDetail)
            return nil
        }

        return extensionInfo
    }

    private var readinessState: InstallState {
        if !isRunningFromApplications {
            return .needsApplicationLocation
        }

        if !appCodeSigningStatus.isValid
            || appEntitlementReadinessDetail != nil
            || !extensionCodeSigningStatus.isValid
            || signingTeamReadinessDetail != nil {
            return .needsSigning
        }

        return .ready
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

        let checkStatus = SecStaticCodeCheckValidityWithErrors(staticCode, SecCSFlags(), nil, nil)
        guard checkStatus == errSecSuccess else {
            return .invalid(errorMessage(for: checkStatus))
        }

        let signingDictionary = signingInformation(for: staticCode)
        return .valid(validDetail,
                      teamIdentifier(in: signingDictionary),
                      enabledEntitlementKeys(in: signingDictionary))
    }

    private static func errorMessage(for status: OSStatus) -> String {
        let fallback = "Code-signing check failed with OSStatus \(status)."
        return SecCopyErrorMessageString(status, nil) as String? ?? fallback
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
              !teamIdentifier.isEmpty else {
            return nil
        }

        return teamIdentifier
    }

    private static func enabledEntitlementKeys(in signingDictionary: [String: Any]?) -> Set<String> {
        guard let signingDictionary,
              let entitlementDictionary = signingDictionary[kSecCodeInfoEntitlementsDict as String] as? [String: Any] else {
            return []
        }

        return Set(entitlementDictionary.compactMap { key, value in
            if let isEnabled = value as? Bool {
                return isEnabled ? key : nil
            }

            if let number = value as? NSNumber {
                return number.boolValue ? key : nil
            }

            return nil
        })
    }

    private func handleFailure(_ error: Error) {
        let message = error.localizedDescription
        pendingRequestKind = nil
        lastFailureDetail = message
        state = .failed(message)
        appendActivity(level: .error, title: "Request Failed", detail: message)
    }

    private func appendActivity(level: ActivityItem.Level, title: String, detail: String) {
        let item = ActivityItem(level: level, title: title, detail: detail)
        activity.insert(item, at: 0)

        if activity.count > 20 {
            activity.removeLast(activity.count - 20)
        }
    }
}

extension SystemExtensionRequestManager: OSSystemExtensionRequestDelegate {
    public func request(_ request: OSSystemExtensionRequest, actionForReplacingExtension existing: OSSystemExtensionProperties, withExtension ext: OSSystemExtensionProperties) -> OSSystemExtensionRequest.ReplacementAction {
        appendActivity(level: .info,
                       title: "Replacing Extension",
                       detail: "\(existing.bundleShortVersion) -> \(ext.bundleShortVersion)")
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
        pendingRequestKind = nil

        switch result {
        case .completed:
            lastFailureDetail = nil
            state = requestKind.completedState
            appendActivity(level: .success,
                           title: requestKind.completedTitle,
                           detail: requestKind.completedDetail)
        case .willCompleteAfterReboot:
            lastFailureDetail = nil
            state = .requiresRestart
            appendActivity(level: .warning,
                           title: "Restart Required",
                           detail: requestKind.restartDetail)
        @unknown default:
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
    case unreadableExtensionBundle(String)
    case missingBundleIdentifier(String)
    case missingBundledVideoResource(String)
    case emptyBundledVideoResource(String)
    case unexpectedBundleIdentifier(expected: String, actual: String)

    var errorDescription: String? {
        switch self {
        case .missingExtensionsDirectory(let path):
            return "No system extensions directory exists at \(path)."
        case .missingBundledExtension:
            return "No bundled .systemextension was found."
        case .unreadableExtensionBundle(let path):
            return "The bundled extension at \(path) could not be opened."
        case .missingBundleIdentifier(let path):
            return "The bundled extension at \(path) does not declare a bundle identifier."
        case .missingBundledVideoResource(let path):
            return "The bundled extension does not include the required video resource at \(path)."
        case .emptyBundledVideoResource(let path):
            return "The bundled extension video resource at \(path) is empty."
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
                    DetailsPanel(manager: manager)
                    ActivityPanel(items: Array(manager.activity.prefix(5)))
                case .activity:
                    ActivityPanel(items: manager.activity)
                }
            }
            .padding(28)
            .frame(maxWidth: 920, alignment: .leading)
        }
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
        .disabled(manager.isBusy || !manager.canSubmitSystemExtensionRequests)
    }

    @ViewBuilder
    private var uninstallButton: some View {
        Button(action: manager.uninstall) {
            Label("Uninstall", systemImage: "trash")
        }
        .buttonStyle(.bordered)
        .disabled(manager.isBusy || !manager.canSubmitSystemExtensionRequests)
    }
}

private struct DetailsPanel: View {
    @ObservedObject var manager: SystemExtensionRequestManager

    var body: some View {
        SectionSurface {
            VStack(alignment: .leading, spacing: 14) {
                Text("Build")
                    .font(.title3.weight(.semibold))

                DetailRow(title: "App Version", value: manager.applicationVersion)
                DetailRow(title: "App Bundle ID", value: manager.applicationBundleIdentifier)
                DetailRow(title: "Expected App ID", value: manager.expectedApplicationIdentifier)
                DetailRow(title: "Expected Extension ID", value: manager.expectedExtensionIdentifier)
                DetailRow(title: "Extension Version", value: manager.extensionInfo?.version ?? "Unknown")
                DetailRow(title: "Application Location", value: manager.applicationLocationStatus)
                DetailRow(title: "Request Readiness", value: manager.requestReadinessStatus)
                if let requestReadinessDetail = manager.requestReadinessDetail {
                    DetailRow(title: "Readiness Detail", value: requestReadinessDetail)
                }
                if let lastFailureDetail = manager.lastFailureDetail {
                    DetailRow(title: "Last Failure", value: lastFailureDetail)
                }
                DetailRow(title: "App Signature", value: manager.appCodeSigningStatus.title)
                if !manager.appCodeSigningStatus.isValid {
                    DetailRow(title: "App Signature Detail", value: manager.appCodeSigningStatus.detail)
                }
                DetailRow(title: "System Extension Entitlement", value: manager.appSystemExtensionEntitlementStatus)
                DetailRow(title: "App Team ID", value: manager.appTeamIdentifier)
                DetailRow(title: "Extension Signature", value: manager.extensionCodeSigningStatus.title)
                if !manager.extensionCodeSigningStatus.isValid {
                    DetailRow(title: "Extension Signature Detail", value: manager.extensionCodeSigningStatus.detail)
                }
                DetailRow(title: "Extension Team ID", value: manager.extensionTeamIdentifier)
                DetailRow(title: "Application Path", value: manager.applicationBundlePath, monospaced: true)

                if let bundlePath = manager.extensionInfo?.bundlePath {
                    DetailRow(title: "Bundle Path", value: bundlePath, monospaced: true)
                }
                if let videoPath = manager.extensionInfo?.videoPath {
                    DetailRow(title: "Video Path", value: videoPath, monospaced: true)
                    DetailRow(title: "Video Size", value: manager.bundledVideoSize)
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
        Button(action: manager.refreshExtensionInfo) {
            Label("Refresh Status", systemImage: "arrow.clockwise")
        }
        .buttonStyle(.bordered)

        Button(action: manager.openSystemSettings) {
            Label("System Settings", systemImage: "gearshape")
        }
        .buttonStyle(.bordered)

        Button(action: manager.copyDiagnostics) {
            Label("Copy Diagnostics", systemImage: "doc.on.doc")
        }
        .buttonStyle(.bordered)

        Button(action: manager.revealApplicationInFinder) {
            Label("Reveal App", systemImage: "folder")
        }
        .buttonStyle(.bordered)

        Button(action: manager.revealBundledExtensionInFinder) {
            Label("Reveal Extension", systemImage: "folder")
        }
        .buttonStyle(.bordered)
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
                        ForEach(items) { item in
                            ActivityRow(item: item)
                                .padding(.vertical, 10)

                            if item.id != items.last?.id {
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
                Text(item.detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
        }
    }

    @ViewBuilder
    private var activityTitle: some View {
        Text(item.title)
            .font(.callout.weight(.semibold))
    }

    @ViewBuilder
    private var activityTimestamp: some View {
        Text(Self.timestampFormatter.string(from: item.date))
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
    }
}

private struct DetailRow: View {
    var title: String
    var value: String
    var monospaced = false

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                titleLabel
                    .frame(width: 160, alignment: .leading)
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
