public struct AutoPlaceCmdArgs: CmdArgs {
    /*conforms*/ public var commonState: CmdArgsCommonState
    public init(rawArgs: StrArrSlice) { self.commonState = .init(rawArgs) }
    public static let parser: CmdParser<Self> = .init(
        kind: .autoPlace,
        help: auto_place_help_generated,
        flags: [:],
        posArgs: [],
    )
}
