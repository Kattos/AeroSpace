public struct WorkspaceChooserSearchCmdArgs: CmdArgs {
    public var commonState: CmdArgsCommonState
    public init(rawArgs: StrArrSlice) { self.commonState = .init(rawArgs) }
    public static let parser: CmdParser<Self> = .init(
        kind: .workspaceChooserSearch,
        help: workspace_chooser_search_help_generated,
        flags: [:],
        posArgs: [],
    )
}
