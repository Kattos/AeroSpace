import Common

struct WorkspaceChooserSearchCommand: Command {
    let args: WorkspaceChooserSearchCmdArgs
    let shouldResetClosedWindowsCache = false

    func run(_ env: CmdEnv, _ io: CmdIo) -> BinaryExitCode {
        guard WorkspaceChooser.shared.openSearch() else {
            return .fail(io.err("Unable to focus workspace search (disabled, Secure Input, or no available screen)."))
        }
        return .succ
    }
}
