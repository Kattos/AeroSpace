import Common

/// A rule of the `auto-place` config option. It reuses the legacy `on-window-detected` matcher fields and semantics,
/// but it is a pure matcher: it never runs commands or callbacks. 'aerospace auto-place' applies the rules
/// to the already existing windows.
struct AutoPlaceRule: ConvenienceMutable {
    var matcher: AutoPlaceMatcher = AutoPlaceMatcher()
    var workspace: WorkspaceName? = nil
}

struct AutoPlaceMatcher: ConvenienceMutable {
    var appId: String?
    var appNameRegexSubstring: CaseInsensitiveRegex?
    var windowTitleRegexSubstring: CaseInsensitiveRegex?

    var hasAnyMatcher: Bool {
        appId != nil || appNameRegexSubstring != nil || windowTitleRegexSubstring != nil
    }
}

private let autoPlaceRuleParser: [String: any ParserProtocol<AutoPlaceRule>] = [
    "if": Parser(\.matcher, parseAutoPlaceMatcher),
    "workspace": Parser(\.workspace, upcast(parseWorkspaceName)),
]

private let autoPlaceMatcherParser: [String: any ParserProtocol<AutoPlaceMatcher>] = [
    "app-id": Parser(\.appId, upcast(parseString)),
    "app-name-regex-substring": Parser(\.appNameRegexSubstring, upcast(parseCasInsensitiveRegex)),
    "window-title-regex-substring": Parser(\.windowTitleRegexSubstring, upcast(parseCasInsensitiveRegex)),
]

func parseAutoPlaceArray(_ raw: OrderedJson, _ backtrace: ConfigBacktrace, _ c: inout ConfigParserContext) -> [AutoPlaceRule] {
    guard let array = raw.asArrayOrNil else {
        c.errors += [expectedActualTypeDiagnostic(expected: .array, actual: raw.tomlType, backtrace)]
        return []
    }
    return array.enumerated().compactMap { (index, raw) in
        parseAutoPlaceRule(raw, backtrace + .index(index), &c)
    }
}

private func parseAutoPlaceMatcher(_ raw: OrderedJson, _ backtrace: ConfigBacktrace, _ c: inout ConfigParserContext) -> AutoPlaceMatcher {
    parseTable(raw, AutoPlaceMatcher(), autoPlaceMatcherParser, backtrace, &c)
}

private func parseWorkspaceName(_ raw: OrderedJson, _ backtrace: ConfigBacktrace) -> ResOrConfigParseDiagnostic<WorkspaceName> {
    parseString(raw, backtrace).flatMap { WorkspaceName.parse($0).toParsedConfig(backtrace) }
}

private func parseAutoPlaceRule(_ raw: OrderedJson, _ backtrace: ConfigBacktrace, _ c: inout ConfigParserContext) -> AutoPlaceRule? {
    var myContext = ConfigParserContext(configVersion: c.configVersion, errors: [], warnings: [])
    let rule = parseTable(raw, AutoPlaceRule(), autoPlaceRuleParser, backtrace, &myContext)

    if !rule.matcher.hasAnyMatcher {
        myContext.errors.append(.init(
            backtrace,
            "'if' must contain at least one of 'app-id', 'app-name-regex-substring', 'window-title-regex-substring'",
        ))
    }
    // Distinguished from an invalid workspace name, which is reported by the parser itself
    let hasWorkspaceKey = raw.asDictOrNil?.contains { $0.key == "workspace" } ?? false
    if !hasWorkspaceKey {
        myContext.errors.append(.init(backtrace, "'workspace' is mandatory key"))
    }

    if !myContext.errors.isEmpty {
        c.errors += myContext.errors
        c.warnings += myContext.warnings
        return nil
    }
    return rule
}

extension AutoPlaceRule {
    /// Conjunction of the specified matchers. Same semantics as the legacy 'on-window-detected' matcher
    @MainActor
    func matches(_ window: Window) async throws -> Bool {
        if let appId = matcher.appId, appId != window.app.rawAppBundleId {
            return false
        }
        if let regex = matcher.appNameRegexSubstring, !(window.app.name ?? "").contains(caseInsensitiveRegex: regex) {
            return false
        }
        if let regex = matcher.windowTitleRegexSubstring {
            if !(try await window.getTitle(.nonCancellable)).contains(caseInsensitiveRegex: regex) {
                return false
            }
        }
        return true
    }
}
