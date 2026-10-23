import Foundation

func workspaceChooserSearch(workspaces: [WorkspaceViewModel], query: String) -> [WorkspaceViewModel] {
    let query = normalizeChooserSearch(query)
    guard !query.isEmpty else { return workspaces }
    let pinyinQuery = query.filter { !$0.isWhitespace }
    let matchesPinyin = pinyinQuery.contains { $0.isASCII && $0.isLetter }
    var aliasCache: [String: [String]] = [:]
    return workspaces.enumerated().compactMap { index, workspace -> (WorkspaceViewModel, Int, Int)? in
        let labels = [workspace.name] + workspace.appLabels
        var scores = (labels + [labels.joined(separator: " ")])
            .compactMap { chooserSearchScore(query, in: $0).map { $0 * 2 } }
        if matchesPinyin {
            for label in labels {
                let aliases: [String]
                if let cached = aliasCache[label] {
                    aliases = cached
                } else {
                    aliases = chooserSearchPinyinAliases(label)
                    aliasCache[label] = aliases
                }
                scores += aliases.compactMap { chooserSearchScore(pinyinQuery, in: $0).map { $0 * 2 + 1 } }
            }
        }
        guard let score = scores.min() else { return nil }
        return (workspace, score, index)
    }.sorted { $0.1 == $1.1 ? $0.2 < $1.2 : $0.1 < $1.1 }.map { $0.0 }
}

private func normalizeChooserSearch(_ text: String) -> String {
    text.precomposedStringWithCanonicalMapping
        .folding(options: [.diacriticInsensitive, .widthInsensitive], locale: nil)
        .lowercased()
        .split(whereSeparator: { $0.isWhitespace || $0.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) })
        .joined(separator: " ")
}

private func chooserSearchScore(_ query: String, in label: String) -> Int? {
    let label = normalizeChooserSearch(label)
    if label == query { return 0 }
    if label.hasPrefix(query) { return 1 }
    let characters = Array(label)
    var cursor = 0
    for character in query {
        guard let match = characters[cursor...].firstIndex(of: character) else { return nil }
        cursor = match + 1
    }
    return 2 + cursor - query.count
}

private func chooserSearchPinyinAliases(_ label: String) -> [String] {
    let han = label.precomposedStringWithCanonicalMapping
        .filter { $0.unicodeScalars.allSatisfy(\.properties.isIdeographic) }
    guard !han.isEmpty else { return [] }
    let syllables = (han.applyingTransform(.toLatin, reverse: false) ?? "")
        .folding(options: [.diacriticInsensitive, .widthInsensitive], locale: nil)
        .lowercased()
        .split(whereSeparator: \.isWhitespace)
        .map { String($0.filter(\.isLetter)) }
        .filter { !$0.isEmpty }
    guard !syllables.isEmpty else { return [] }
    let full = syllables.joined()
    let initials = String(syllables.compactMap(\.first))
    return initials == full ? [full] : [full, initials]
}
