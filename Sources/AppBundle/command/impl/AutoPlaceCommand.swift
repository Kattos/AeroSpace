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
            var matched: AutoPlaceRule? = nil
            var failed = false
            for rule in config.autoPlace {
                do {
                    if try await rule.matches(window) {
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
            // 'workspace' is mandatory and validated by the parser
            let targetWorkspace = Workspace.get(byName: rule.workspace.orDie().raw)
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
