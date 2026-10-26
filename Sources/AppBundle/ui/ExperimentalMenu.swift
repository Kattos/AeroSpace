import AppKit
import Common
import SwiftUI

@MainActor @ViewBuilder
func experimentalMenu(viewModel: TrayMenuModel) -> some View {
    Menu("Experimental") {
        if viewModel.axPermissionStatus == .granted, let token: RunSessionGuard = .isServerEnabled {
            let hint = autoPlaceShortcutHint()
            Button(hint.map { "Auto Place (\($0))" } ?? "Auto Place") {
                Task.startUnstructured {
                    try await runLightSession(.menuBarButton, token) {
                        let result = await AutoPlaceCommand(args: AutoPlaceCmdArgs(rawArgs: []))
                            .run(.defaultEnv, .emptyStdin)
                        if result.exitCode.rawValue != 0 {
                            MessageModel.shared.message = Message(
                                description: "Auto Place failed",
                                body: result.stderr.isEmpty ? "Auto Place failed." : result.stderr.joined(separator: "\n"),
                                containsWarnings: false,
                            )
                        }
                    }
                }
            }
            Button("Workspace Search") {
                Task.startUnstructured {
                    try await runLightSession(.menuBarButton, token) {
                        let result = await WorkspaceChooserSearchCommand(args: WorkspaceChooserSearchCmdArgs(rawArgs: []))
                            .run(.defaultEnv, .emptyStdin)
                        if result.exitCode.rawValue != 0 {
                            MessageModel.shared.message = Message(
                                description: "Workspace Search failed",
                                body: result.stderr.isEmpty ? "Workspace Search failed." : result.stderr.joined(separator: "\n"),
                                containsWarnings: false,
                            )
                        }
                    }
                }
            }
            Divider()
            Button("Restart") {
                Task.startUnstructured {
                    try await runLightSession(.menuBarButton, token) {
                        let result = await RestartCommand(args: RestartCmdArgs(rawArgs: []))
                            .run(.defaultEnv, .emptyStdin)
                        if result.exitCode.rawValue != 0 {
                            MessageModel.shared.message = Message(
                                description: "Restart failed",
                                body: result.stderr.isEmpty ? "Restart failed." : result.stderr.joined(separator: "\n"),
                                containsWarnings: false,
                            )
                        }
                    }
                }
            }
        }
        Button("Help…") { ExperimentalHelpPanel.shared.present() }
    }
}

@MainActor
private func autoPlaceShortcutHint() -> String? {
    let mode = activeMode ?? mainModeId
    return config.modes[mode]?.bindings.values
        .filter { $0.commands.flatten().contains { $0 is AutoPlaceCommand } }
        .map(\.descriptionWithKeyNotation).sorted().first
}

@MainActor
private final class ExperimentalHelpPanel: NSPanel {
    static let shared = ExperimentalHelpPanel()

    private init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 660, height: 650),
                   styleMask: [.titled, .closable, .resizable, .utilityWindow, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        title = "Experimental Help"
        isReleasedWhenClosed = false
        level = .floating
        minSize = NSSize(width: 440, height: 300)
        contentView = NSHostingView(rootView: ExperimentalHelpView())
    }

    func present() {
        if !isVisible { center() }
        makeKeyAndOrderFront(nil)
    }
}

private struct ExperimentalHelpView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("Experimental").font(.title2.bold())
                Text("Local features in this fork. Configure them in your existing TOML file, then reload config. These options keep their current names; there is no experimental namespace.")
                ForEach(experimentalHelpSections, id: \.title) { section in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(section.title).font(.headline)
                        Text(verbatim: section.body)
                    }
                }
                Text("Example").font(.headline)
                Text("Merge these fields into existing tables. Do not repeat table headers. Option+Space is only an example: check your bindings and other apps for conflicts. No search shortcut is installed by default.")
                Text(verbatim: experimentalHelpExample)
                    .font(.system(size: 12, design: .monospaced))
                    .padding(12).frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
            }
            .font(.system(size: 13)).lineSpacing(3)
            .frame(maxWidth: 640, alignment: .leading).padding(24)
        }
        .textSelection(.enabled)
    }
}

private let experimentalHelpSections: [(title: String, body: String)] = [
    ("Workspace chooser", "Hold either Option key alone to see the chooser; release it to close. Use your existing workspace shortcuts to switch. The clicked tray workspace menu remains the classic list. Ghostty labels include cached window titles; other apps show app names. No screen recording permission is needed."),
    ("[workspace-chooser]", "columns = \"auto\" (default) fits columns to the screen; \"fixed\" uses two balanced columns, or one for a single result; \"single\" uses one column.\nsearch-style = \"default\" by default. \"default\" expands the input below the screen-fitted grid; \"legacy\" uses the earlier top input with a single result column. Only these two exact strings are accepted.\ndisplay-scope = \"current\" by default. \"all\" shows the same workspaces on every screen, laid out for that screen. Search shows only on the invocation screen.\nhide-empty-workspaces = false by default. When true, empty workspaces are hidden except the focused workspace.\nhold-threshold-ms = 400 by default; use a positive integer. Timing is checked every 50 ms.\nexclude-keys = [] by default. Use ordinary AeroSpace key notation; key mappings apply. Pressing one with Option suppresses the ordinary chooser until Option is released. A passive event tap may need Input Monitoring permission; without it, exclusions are best effort.\nshow-app-icons = false by default. Enable 16×16 application icons beside each label. Missing icons fall back to text. Settings also apply to search results."),
    ("[workspace-chooser-colors]", "Map a literal part of a displayed label to a strict \"#RRGGBB\" color. Matching is case insensitive, not a regular expression. The first matching rule in source order colors the whole application/Ghostty label in bold. Full labels are matched before truncation. No rules means ordinary secondary text."),
    ("Auto Place · [auto-place]", "Run Auto Place from this submenu or with aerospace auto-place. Map display-label substrings to workspace names (strings or integers). Matching is case insensitive and literal; the first rule in source order wins. Ghostty can match its title; other apps match their application names. Hidden, minimized and macOS native fullscreen windows are skipped. With no rules nothing is moved. This is manual only: it does not run callbacks or shell commands. If a current-mode binding contains auto-place, including a reload-config + auto-place sequence, its key notation appears beside the menu action. The hint adds no binding."),
    ("Workspace Search", "Open this submenu action or run aerospace workspace-chooser-search. Search stays open after Option is released for normal typing and input methods. Names and existing full application/Ghostty labels match case-insensitive ordered characters; exact/prefix matches rank first and ties keep workspace order. Up/Down selects, Enter switches, Escape cancels; Enter during marked-text composition belongs to the input method. AeroSpace shortcuts pause while searching and restore on close. Focus loss, disable, sleep, session exit and a successful config reload close search. External global shortcuts can still intercept keys."),
    ("command-after-restart", "Top-level key, empty by default. Same syntax and native validation as after-startup-command: a TOML array of AeroSpace commands, no shell evaluation. The commands run in order, once, only in the instance launched by the Restart action or aerospace restart, after the config is loaded and existing windows are registered. Ordinary launches never run them. Example: command-after-restart = ['auto-place']. A failing command surfaces the usual diagnostics."),
    ("Restart", "Run this submenu action or aerospace restart. The command answers first, then quits AeroSpace and reopens the same running app bundle (not another build or the CLI on PATH). After the new instance has loaded the config and registered windows, it runs command-after-restart once, if configured; nothing is placed by default. Window layout is not preserved: windows are centered before quitting, so only commands you list there (for example auto-place) restore placement; unmatched windows may stay on the focused workspace or reflow. after-startup-command runs normally and on-window-detected callbacks are not re-run. There is no default shortcut and no layout guarantee. Restart fails instead of launching anything when AeroSpace isn't running from an .app bundle, in read-only mode, or while a restart is already pending."),
]

private let experimentalHelpExample = """
[workspace-chooser]
columns = "auto"
hide-empty-workspaces = false
hold-threshold-ms = 400
exclude-keys = []
show-app-icons = false

[workspace-chooser-colors]
"project" = "#89B4FA"

[auto-place]
"project" = "D"

command-after-restart = ['auto-place']

[mode.main.binding]
alt-space = "workspace-chooser-search"
"""
