//
//  ContentView.swift
//

import Foundation
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
    private let expectedExtensionBundleIdentifier = "com.garethpaul.GarethVideoCam.Extension"

    enum InstallState: Equatable {
        case idle
        case ready
        case needsApplicationLocation
        case locatingExtension
        case activating
        case needsApproval
        case activated
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
            case .locatingExtension:
                return "Locating Extension"
            case .activating:
                return "Installing"
            case .needsApproval:
                return "Approval Required"
            case .activated:
                return "Installed"
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
            case .locatingExtension, .activating, .deactivating:
                return "arrow.triangle.2.circlepath"
            case .needsApproval:
                return "person.badge.shield.checkmark"
            case .activated:
                return "checkmark.seal.fill"
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
            case .locatingExtension, .activating, .deactivating:
                return .indigo
            case .needsApproval, .requiresRestart:
                return .orange
            case .activated:
                return .green
            case .failed:
                return .red
            }
        }
    }

    struct ExtensionInfo: Equatable {
        var identifier: String
        var version: String
        var bundlePath: String
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

    @Published var state: InstallState = .idle
    @Published var extensionInfo: ExtensionInfo?
    @Published var activity: [ActivityItem] = []

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
        return canSubmitSystemExtensionRequests ? "In Applications" : "Outside Applications"
    }

    var applicationBundlePath: String {
        return Bundle.main.bundleURL.path
    }

    var canSubmitSystemExtensionRequests: Bool {
        return applicationBundlePath.hasPrefix("/Applications/")
    }

    func install() {
        guard prepareForSystemExtensionRequest() else { return }

        state = .locatingExtension
        do {
            let extensionInfo = try loadBundledExtensionInfo()
            self.extensionInfo = extensionInfo
            state = .activating
            appendActivity(level: .info,
                           title: "Install Requested",
                           detail: extensionInfo.identifier)

            let activationRequest = OSSystemExtensionRequest.activationRequest(forExtensionWithIdentifier: extensionInfo.identifier,
                                                                               queue: .main)
            activationRequest.delegate = self
            OSSystemExtensionManager.shared.submitRequest(activationRequest)
        } catch {
            handleFailure(error)
        }
    }

    func uninstall() {
        guard prepareForSystemExtensionRequest() else { return }

        state = .locatingExtension
        do {
            let extensionInfo = try loadBundledExtensionInfo()
            self.extensionInfo = extensionInfo
            state = .deactivating
            appendActivity(level: .info,
                           title: "Uninstall Requested",
                           detail: extensionInfo.identifier)

            let deactivationRequest = OSSystemExtensionRequest.deactivationRequest(forExtensionWithIdentifier: extensionInfo.identifier,
                                                                                   queue: .main)
            deactivationRequest.delegate = self
            OSSystemExtensionManager.shared.submitRequest(deactivationRequest)
        } catch {
            handleFailure(error)
        }
    }

    func refreshExtensionInfo() {
        do {
            extensionInfo = try loadBundledExtensionInfo()
            switch state {
            case .idle, .ready, .needsApplicationLocation:
                state = canSubmitSystemExtensionRequests ? .ready : .needsApplicationLocation
            default:
                break
            }
        } catch {
            handleFailure(error)
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

            return ExtensionInfo(identifier: identifier,
                                 version: version,
                                 bundlePath: extensionURL.path)
        }

        throw ExtensionRequestError.unexpectedBundleIdentifier(expected: expectedExtensionBundleIdentifier,
                                                              actual: unexpectedIdentifiers.joined(separator: ", "))
    }

    private func prepareForSystemExtensionRequest() -> Bool {
        guard canSubmitSystemExtensionRequests else {
            state = .needsApplicationLocation
            appendActivity(level: .warning,
                           title: "Move Required",
                           detail: "Current path is \(applicationBundlePath).")
            return false
        }

        return true
    }

    private func handleFailure(_ error: Error) {
        let message = error.localizedDescription
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
        state = .needsApproval
        appendActivity(level: .warning,
                       title: "Approval Required",
                       detail: "System Settings must allow the camera extension before it can run.")
    }

    public func request(_ request: OSSystemExtensionRequest, didFinishWithResult result: OSSystemExtensionRequest.Result) {
        switch result.rawValue {
        case 0:
            state = .activated
            appendActivity(level: .success,
                           title: "Request Completed",
                           detail: "The camera extension is active.")
        case 1:
            state = .requiresRestart
            appendActivity(level: .warning,
                           title: "Restart Required",
                           detail: "The request completed and macOS reported that a restart is required.")
        default:
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
        state = .failed(errorString)
        appendActivity(level: .error,
                       title: "Request Failed",
                       detail: "\(errorString) (\(nsError.domain) \(errorCode)): \(nsError.localizedDescription)")
    }
}

enum ExtensionRequestError: LocalizedError {
    case missingExtensionsDirectory(String)
    case missingBundledExtension
    case unreadableExtensionBundle(String)
    case missingBundleIdentifier(String)
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
                HStack(alignment: .center, spacing: 12) {
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
                    .layoutPriority(1)

                    Spacer(minLength: 16)

                    Button(action: manager.install) {
                        Label("Install", systemImage: "arrow.down.circle.fill")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(manager.isBusy || !manager.canSubmitSystemExtensionRequests)

                    Button(action: manager.uninstall) {
                        Label("Uninstall", systemImage: "trash")
                    }
                    .buttonStyle(.bordered)
                    .disabled(manager.isBusy || !manager.canSubmitSystemExtensionRequests)
                }

                if !manager.canSubmitSystemExtensionRequests {
                    Label("System extension requests require /Applications.", systemImage: "exclamationmark.triangle.fill")
                        .font(.callout)
                        .foregroundStyle(.orange)
                }
            }
        }
    }
}

private struct DetailsPanel: View {
    @ObservedObject var manager: SystemExtensionRequestManager

    var body: some View {
        SectionSurface {
            VStack(alignment: .leading, spacing: 14) {
                Text("Build")
                    .font(.title3.weight(.semibold))

                DetailRow(title: "Extension Version", value: manager.extensionInfo?.version ?? "Unknown")
                DetailRow(title: "Application Location", value: manager.applicationLocationStatus)
                DetailRow(title: "Application Path", value: manager.applicationBundlePath, monospaced: true)

                if let bundlePath = manager.extensionInfo?.bundlePath {
                    DetailRow(title: "Bundle Path", value: bundlePath, monospaced: true)
                }
            }
        }
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
                HStack {
                    Text(item.title)
                        .font(.callout.weight(.semibold))
                    Spacer()
                    Text(Self.timestampFormatter.string(from: item.date))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                Text(item.detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
        }
    }
}

private struct DetailRow: View {
    var title: String
    var value: String
    var monospaced = false

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
                .foregroundStyle(.secondary)
                .frame(width: 160, alignment: .leading)
            Text(value)
                .font(monospaced ? .callout.monospaced() : .callout)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
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
