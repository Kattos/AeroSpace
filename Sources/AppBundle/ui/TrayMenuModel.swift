import AppKit
import Common

public final class TrayMenuModel: ObservableObject {
    @MainActor public static let shared = TrayMenuModel()

    private init() {}

    @Published var trayText: String = ""
    @Published var trayItems: [TrayItem] = []
    /// Is "layouting" enabled
    @Published var isEnabled: Bool = true
    @Published var workspaces: [WorkspaceViewModel] = []
    @Published var workspaceChooserColors: [(pattern: String, rgb: UInt32)] = []
    @Published var workspaceChooser = WorkspaceChooserSettings()
    @Published var experimentalUISettings: ExperimentalUISettings = ExperimentalUISettings()
    @Published var sponsorshipMessage: String = sponsorshipPrompts.randomElement().orDie()
    @Published var lastReloadConfigContainedWarnings: Bool = false
    @Published var axPermissionStatus: AxPermissionStatus = .waitingWithPrompt

    @MainActor private var ghosttyTitles: [UInt32: (window: MacWindow, title: String)] = [:]
    @MainActor private var titleTask: Task<Void, Never>?
    @MainActor private var titleSurfaces: Set<WorkspaceTitleSurface> = []
    @MainActor private var titleGeneration = 0
    @MainActor private var trackedMenu: NSMenu?
    @MainActor private var menuObservers: [any NSObjectProtocol] = []
    @MainActor private var chooserIcons: [Int32: (identity: ObjectIdentifier, image: NSImage?)] = [:]

    @MainActor func chooserIcon(pid: Int32?) -> NSImage? {
        chooserIcons = chooserIcons.filter { pid, entry in
            MacApp.allAppsMap[pid].map { ObjectIdentifier($0) == entry.identity } ?? false
        }
        guard let pid, let app = MacApp.allAppsMap[pid] else { return nil }
        if let entry = chooserIcons[pid] { return entry.image }
        let candidate = app.nsApp.icon?.copy() as? NSImage
        let image = candidate?.isValid == true ? candidate : nil
        image?.size = NSSize(width: 16, height: 16)
        chooserIcons[pid] = (ObjectIdentifier(app), image)
        return image
    }

    @MainActor func observeWorkspaceMenu() {
        guard menuObservers.isEmpty else { return }
        menuObservers.append(NotificationCenter.default.addObserver(
            forName: NSMenu.didBeginTrackingNotification, object: nil, queue: .main,
        ) { notification in
            // The observer's main queue guarantees that this AppKit object stays on the main thread.
            nonisolated(unsafe) let menu = notification.object as? NSMenu
            MainActor.assumeIsolated {
                let model = TrayMenuModel.shared
                guard let menu = unsafe menu, menu.items.contains(where: { $0.title == "Workspaces:" })
                else { return }
                model.trackedMenu = menu
                model.showWorkspaceTitles(.menu)
            }
        })
        menuObservers.append(NotificationCenter.default.addObserver(
            forName: NSMenu.didEndTrackingNotification, object: nil, queue: .main,
        ) { notification in
            nonisolated(unsafe) let menu = notification.object as? NSMenu
            MainActor.assumeIsolated {
                let model = TrayMenuModel.shared
                guard let menu = unsafe menu, menu === model.trackedMenu else { return }
                model.trackedMenu = nil
                model.hideWorkspaceTitles(.menu)
            }
        })
    }

    @MainActor func showWorkspaceTitles(_ surface: WorkspaceTitleSurface) {
        guard titleSurfaces.insert(surface).inserted else { return }
        titleGeneration += 1
        if titleTask != nil { titleTask?.cancel() }
        else { refreshWorkspaceTitles() }
    }

    @MainActor func hideWorkspaceTitles(_ surface: WorkspaceTitleSurface) {
        titleSurfaces.remove(surface)
        if titleSurfaces.isEmpty {
            titleGeneration += 1
            titleTask?.cancel()
        }
    }

    @MainActor private func refreshWorkspaceTitles() {
        guard !titleSurfaces.isEmpty else { return }
        let generation = titleGeneration
        let windows = Workspace.all.flatMap { workspace in
            workspace.allLeafWindowsRecursive.compactMap { $0 as? MacWindow }
                .filter { $0.macApp.rawAppBundleId == "com.mitchellh.ghostty" }
                .sorted { $0.windowId < $1.windowId }.prefix(3)
                .map { (window: $0, workspace: workspace.name) }
        }
        titleTask = Task { @MainActor in
            for entry in windows {
                guard !Task.isCancelled else { break }
                let title = (try? await entry.window.getTitle(.cancellable)) ?? ""
                guard !Task.isCancelled, generation == self.titleGeneration else { break }
                guard MacWindow.allWindowsMap[entry.window.windowId] === entry.window,
                      entry.window.nodeWorkspace?.name == entry.workspace
                else { continue }
                self.ghosttyTitles[entry.window.windowId] = (entry.window, sanitizedWorkspaceTitle(title))
            }
            let cancelled = Task.isCancelled
            self.titleTask = nil
            if generation == self.titleGeneration, !cancelled {
                updateWorkspaceMenuItems()
            } else if !self.titleSurfaces.isEmpty {
                self.refreshWorkspaceTitles()
            }
        }
    }

    @MainActor func workspaceSummary(_ workspace: Workspace) -> (menu: String, labels: [String], entries: [WorkspaceAppEntry]) {
        ghosttyTitles = ghosttyTitles.filter { MacWindow.allWindowsMap[$0.key] === $0.value.window }
        let windows = workspace.allLeafWindowsRecursive
        let otherApps = windows.filter { $0.app.rawAppBundleId != "com.mitchellh.ghostty" }
            .compactMap { $0.app.name?.takeIf { !$0.isEmpty } }.toSet().sorted()
        let ghostty = windows.filter { $0.app.rawAppBundleId == "com.mitchellh.ghostty" }
            .sorted { $0.windowId < $1.windowId }
        let appSummary = otherApps.joinTruncating(separator: ", ", length: 25)
        var menuLabels = appSummary.isEmpty ? [] : [appSummary]
        var labels = otherApps
        var entries = otherApps.map { name in
            WorkspaceAppEntry(label: name, pid: windows.filter { $0.app.name == name }.map { $0.app.pid }.min())
        }
        for (index, window) in ghostty.prefix(3).enumerated() {
            let appName = window.app.name?.takeIf { !$0.isEmpty } ?? "Ghostty"
            let title = ghosttyTitles[window.windowId]?.title ?? ""
            let label = ghosttyWorkspaceLabel(appName: appName, title: title)
            let text = ghostty.count > 1 ? "[\(index + 1)] \(label)" : label
            menuLabels.append(text)
            labels.append(text)
            entries.append(WorkspaceAppEntry(label: text, pid: window.app.pid))
        }
        if ghostty.count > 3 {
            let text = "+\(ghostty.count - 3) more Ghostty windows"
            menuLabels.append(text)
            labels.append(text)
            entries.append(WorkspaceAppEntry(label: text, pid: ghostty.first?.app.pid))
        }
        return (menuLabels.joined(separator: ", "), labels, entries)
    }
}

enum WorkspaceTitleSurface { case menu, chooser }

func sanitizedWorkspaceTitle(_ title: String) -> String {
    title.components(separatedBy: .whitespacesAndNewlines.union(.controlCharacters))
        .filter { !$0.isEmpty }.joined(separator: " ")
}

func ghosttyWorkspaceLabel(appName: String, title: String) -> String {
    title.isEmpty || title.caseInsensitiveCompare(appName) == .orderedSame ? appName : "\(appName): \(title)"
}

func boundedWorkspaceMenuTitle(_ title: String) -> String {
    let font = NSFont.monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
    let attributes: [NSAttributedString.Key: Any] = [.font: font]
    let width: CGFloat = 420
    if (title as NSString).size(withAttributes: attributes).width <= width { return title }
    // Native menu labels ignore SwiftUI layout modifiers; bound the rendered text itself.
    var prefix = ""
    for character in title {
        let candidate = prefix + String(character)
        if ((candidate + "…") as NSString).size(withAttributes: attributes).width > width { break }
        prefix = candidate
    }
    return prefix + "…"
}

enum AxPermissionStatus: Equatable {
    case granted
    case waiting
    case waitingWithPrompt
}

@MainActor func updateTrayText() {
    let sortedMonitors = sortedMonitors
    let focus = focus
    TrayMenuModel.shared.trayText = (activeMode?.takeIf { $0 != mainModeId }?.first.map { "(\($0.uppercased())) " } ?? "") +
        sortedMonitors
        .map {
            let hasFullscreenWindows = $0.activeWorkspace.allLeafWindowsRecursive.contains { $0.isFullscreen }
            let activeWorkspaceName = hasFullscreenWindows ? "[\($0.activeWorkspace.name)]" : $0.activeWorkspace.name
            return ($0.activeWorkspace == focus.workspace && sortedMonitors.count > 1 ? "*" : "") + activeWorkspaceName
        }
        .joined(separator: " │ ")
    updateWorkspaceMenuItems()
    var items = sortedMonitors.map {
        let hasFullscreenWindows = $0.activeWorkspace.allLeafWindowsRecursive.contains { $0.isFullscreen }
        return TrayItem(
            type: .workspace,
            name: $0.activeWorkspace.name,
            isActive: $0.activeWorkspace == focus.workspace,
            hasFullscreenWindows: hasFullscreenWindows,
        )
    }
    let mode = activeMode?.takeIf { $0 != mainModeId }?.first.map {
        TrayItem(type: .mode, name: $0.uppercased(), isActive: true, hasFullscreenWindows: false)
    }
    if let mode {
        items.insert(mode, at: 0)
    }
    TrayMenuModel.shared.trayItems = items
}

@MainActor private func updateWorkspaceMenuItems() {
    TrayMenuModel.shared.workspaces = Workspace.all.map {
        let summary = TrayMenuModel.shared.workspaceSummary($0)
        let dash = " - "
        let suffix = switch true {
            case !summary.menu.isEmpty: dash + summary.menu
            case $0.isVisible: dash + $0.workspaceMonitor.name
            default: ""
        }
        let hasFullscreenWindows = $0.allLeafWindowsRecursive.contains { $0.isFullscreen }
        return WorkspaceViewModel(
            name: $0.name,
            suffix: suffix,
            appLabels: summary.labels,
            isFocused: focus.workspace == $0,
            isEffectivelyEmpty: $0.isEffectivelyEmpty,
            isVisible: $0.isVisible,
            hasFullscreenWindows: hasFullscreenWindows,
            appEntries: summary.entries,
        )
    }
}

struct WorkspaceViewModel: Hashable {
    let name: String
    let suffix: String
    let appLabels: [String]
    let isFocused: Bool
    let isEffectivelyEmpty: Bool
    let isVisible: Bool
    let hasFullscreenWindows: Bool
    var appEntries: [WorkspaceAppEntry] = []
}

struct WorkspaceAppEntry: Hashable {
    let label: String
    let pid: Int32?
}

enum TrayItemType: String, Hashable {
    case mode
    case workspace
}

private let validLetters = "A" ... "Z"

struct TrayItem: Hashable, Identifiable {
    let type: TrayItemType
    let name: String
    let isActive: Bool
    let hasFullscreenWindows: Bool
    var systemImageName: String? {
        // System image type is only valid for numbers 0 to 50 and single capital char workspace name
        switch Int(name) {
            case let number?: if !(0 ... 50).contains(number) { return nil }
            case nil where name.count == 1: if !validLetters.contains(name) { return nil }
            default: return nil
        }
        let lowercasedName = name.lowercased()
        return switch type {
            case .mode: "\(lowercasedName).circle"
            case .workspace where isActive: "\(lowercasedName).square.fill"
            case .workspace: "\(lowercasedName).square"
        }
    }
    var id: String {
        return type.rawValue + name
    }
}
