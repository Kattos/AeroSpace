import Foundation

func workspaceChooserSearch(workspaces: [WorkspaceViewModel], query: String) -> [WorkspaceViewModel] {
    let query = normalizeChooserSearch(query)
    guard !query.isEmpty else { return workspaces }
    return workspaces.enumerated().compactMap { index, workspace -> (WorkspaceViewModel, Int, Int)? in
        let labels = [workspace.name] + workspace.appLabels
        let scores = (labels + [labels.joined(separator: " ")]).compactMap { chooserSearchScore(query, in: $0) }
        guard let score = scores.min() else { return nil }
        return (workspace, score, index)
    }.sorted { $0.1 == $1.1 ? $0.2 < $1.2 : $0.1 < $1.1 }.map { $0.0 }
}

private func normalizeChooserSearch(_ text: String) -> String {
    text.precomposedStringWithCanonicalMapping.lowercased()
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
