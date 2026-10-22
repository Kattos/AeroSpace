import AppKit
import Common

struct AutoPlaceCommand: Command {
    let args: AutoPlaceCmdArgs
    /*conforms*/ let shouldResetClosedWindowsCache: Bool = true

    func run(_ env: CmdEnv, _ io: CmdIo) async -> BinaryExitCode {
        var moved = 0
        var unchanged = 0
        var unmatched = 0
        var skipped = 0
        var failures = 0

        for window in MacWindow.allWindows.sortedBy({ $0.windowId }) {
            switch window.windowParentCases {
                case .tilingContainer, .floatingWindowsContainer:
                    break
                case .unbound, .macosMinimizedWindowsContainer, .macosHiddenAppsWindowsContainer,
                     .macosFullscreenWindowsContainer, .macosPopupWindowsContainer:
                    skipped += 1
                    continue
            }
            guard let currentWorkspace = window.nodeWorkspace else {
                skipped += 1
                continue
            }
            // The first matching rule in the config order wins
            // The full Ghostty label is fetched lazily at most once per window, and only if no earlier
            // app-name match decides the rule
            var cachedGhosttyLabel: String? = nil
            var matched: AutoPlaceRule? = nil
            var failed = false
            for rule in config.autoPlace {
                do {
                    if try await rule.matches(window, ghosttyLabel: {
                        if let cachedGhosttyLabel { return cachedGhosttyLabel }
                        let label = try await autoPlaceGhosttyLabel(window)
                        cachedGhosttyLabel = label
                        return label
                    }) {
                        matched = rule
                        break
                    }
                } catch {
                    io.err("Can't match window '\(window.windowId)': \(error.localizedDescription)")
                    failures += 1
                    failed = true
                    break
                }
            }
            if failed { continue }
            guard let rule = matched else {
                unmatched += 1
                continue
            }
            let targetWorkspace = Workspace.get(byName: rule.workspace.raw)
            if targetWorkspace == currentWorkspace {
                unchanged += 1
                continue
            }
            switch moveWindowToWorkspace(window, targetWorkspace, io, focusFollowsWindow: false, failIfNoop: false) {
                case .succ: moved += 1
                case .fail: failures += 1
            }
        }

        io.out("auto-place: moved \(moved), unchanged \(unchanged), unmatched \(unmatched), skipped \(skipped)")
        return failures == 0 ? .succ : .fail
    }
}

/// The label the Option chooser displays for a Ghostty window: the app name plus the actual current window title,
/// normalized the same way as the chooser but never truncated. The title is read on demand rather than reusing the
/// chooser's cache, because the cache is only populated while the chooser is visible.
@MainActor
private func autoPlaceGhosttyLabel(_ window: Window) async throws -> String {
    let appName = window.app.name?.takeIf { !$0.isEmpty } ?? "Ghostty"
    return ghosttyWorkspaceLabel(appName: appName, title: sanitizedWorkspaceTitle(try await window.getTitle(.nonCancellable)))
}
