import Common

/// A rule of the `auto-place` config option: a literal substring of the label that the Option chooser displays for a
/// window, mapped to the workspace that should hold the window. Matching is case insensitive and the first rule in
/// the config order wins. The rules only move windows when 'aerospace auto-place' is invoked manually.
struct AutoPlaceRule: Equatable {
    let pattern: String
    let workspace: WorkspaceName
}

func parseAutoPlace(_ raw: OrderedJson, _ backtrace: ConfigBacktrace, _ c: inout ConfigParserContext) -> [AutoPlaceRule] {
    guard let table = raw.asDictOrNil else {
        c.errors += [expectedActualTypeDiagnostic(expected: .table, actual: raw.tomlType, backtrace)]
        return []
    }
    var rules: [AutoPlaceRule] = []
    for (pattern, rawWorkspace) in table {
        let backtrace = backtrace + .key(pattern)
        guard !pattern.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            c.errors.append(.init(backtrace, "Auto-place pattern must not be empty or whitespace-only"))
            continue
        }
        guard let workspace = parseAutoPlaceWorkspace(rawWorkspace, backtrace).getOrNil(appendErrorTo: &c.errors) else { continue }
        rules.append(AutoPlaceRule(pattern: pattern, workspace: workspace))
    }
    return rules
}

/// Accepts a TOML integer (converted to a workspace name) and a TOML string. Booleans and floats are rejected.
private func parseAutoPlaceWorkspace(_ raw: OrderedJson, _ backtrace: ConfigBacktrace) -> ResOrConfigParseDiagnostic<WorkspaceName> {
    switch raw {
        case .string(let value): WorkspaceName.parse(value).toParsedConfig(backtrace)
        case .int(let value): WorkspaceName.parse(value.description).toParsedConfig(backtrace)
        default: .failure(expectedActualTypeDiagnostic(expected: [.string, .int], actual: raw.tomlType, backtrace))
    }
}

extension AutoPlaceRule {
    /// A rule is matched against the labels that the Option chooser displays for the window: the app name for every
    /// app, plus the window title for Ghostty. 'ghosttyLabel' is only called for Ghostty windows whose app name
    /// didn't already match, so the title is never read for a rule that is decided by the app name.
    @MainActor
    func matches(_ window: Window, ghosttyLabel: () async throws -> String) async throws -> Bool {
        let appName = window.app.name?.takeIf { !$0.isEmpty }
        if let appName, appName.contains(caseInsensitiveLiteral: pattern) {
            return true
        }
        guard window.app.rawAppBundleId == KnownBundleId.ghostty.rawValue else { return false }
        return try await ghosttyLabel().contains(caseInsensitiveLiteral: pattern)
    }
}
