public struct RestartCmdArgs: CmdArgs {
    /*conforms*/ public var commonState: CmdArgsCommonState
    public init(rawArgs: StrArrSlice) { self.commonState = .init(rawArgs) }
    public static let parser: CmdParser<Self> = .init(
        kind: .restart,
        help: restart_help_generated,
        flags: [:],
        posArgs: [],
    )
}
