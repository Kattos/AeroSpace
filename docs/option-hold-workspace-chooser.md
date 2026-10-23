# Option workspace chooser

Hold either Option key on its own for 0.4 seconds by default to show the workspace list.
Set a positive integer `hold-threshold-ms` under `[workspace-chooser]` to change
the delay in milliseconds, for example `hold-threshold-ms = 250`. The default is
`400`; the timer checks every 50 milliseconds, so presentation may be slightly
later than the configured threshold. Reloading the config updates the threshold.
The list uses the same workspace names, application summaries and focus state as
the menu bar menu. Use an existing workspace shortcut while holding Option to
switch workspaces and dismiss the list. Release Option to dismiss it.

Another modifier, a key or a mouse click cancels the gesture until Option is
released and pressed again. The panel does not activate AeroSpace or capture
keyboard shortcuts. The clicked menu bar menu continues to work as before.
The chooser is unavailable while AeroSpace is disabled or Secure Input is active.

## Persistent search

Run `aerospace workspace-chooser-search`, or bind the native command yourself:

```toml
[mode.main.binding]
alt-space = 'workspace-chooser-search'
```

This is an example, not a default binding. Option+F and Option+Enter already have
bindings in the local configuration; Option+Space was absent from the inspected
AeroSpace bindings. Other applications may still register it globally.

Search stays open when Option is released. Type normally in the native search
field, use Up/Down to select, Return to switch, and Escape to cancel. Input method
composition owns Return until committed. The field and editor survive title and
workspace updates. Results use a single column and existing entry styling; no
matches shows “No matching workspaces”. Empty queries preserve ordinary workspace
order and `hide-empty-workspaces`. Matching normalizes case and whitespace and
uses ordered subsequences of full workspace names and cached app/Ghostty labels.
Exact labels rank before prefixes, then matches with fewer leading/skipped
characters; ties preserve the original workspace order.

The nonactivating panel temporarily accepts keyboard focus only during search.
AeroSpace Carbon shortcuts pause until search closes; rebuilding hotkeys during
reload keeps them paused and closing restores the current mode. Focus loss,
disable, sleep and session resignation close search. The ordinary hold gesture,
threshold, passive exclusion tap and fixed/auto columns remain unchanged outside
search. No new shortcut config key or permission is needed. External global
shortcuts can still intercept input. Physical typing, focus return and IME
composition require manual runtime verification; source checks and compilation
alone do not prove them.

The separate `.build/chooser-search/AeroSpace-Release.app` and
`.build/chooser-search/aerospace` contain the optimized search build with the
exclude-keys package resources, ad hoc signed. Previous bundles are preserved;
the application has not been launched or installed.

## Keys that other shortcuts consume

`exclude-keys` covers the case where another app's global shortcut consumes the
key press before AeroSpace can see it. Because Carbon and third-party shortcuts
can swallow the event, the chooser cannot rely on its normal event monitors for
those keys.

```toml
[workspace-chooser]
exclude-keys = ["s", "v"]
```

The default is an empty list, which disables the feature and leaves the chooser
unchanged. Names are ordinary AeroSpace key notation and follow
`key-mapping.preset` and `key-notation-to-key-code` overrides, exactly like
keybindings. Unknown names and non-string values are configuration errors.

While an Option key is held, pressing an excluded key cancels a pending timer or
dismisses a visible chooser and suppresses the chooser until every Option key is
released. Pressing an excluded key at the same time as Option is not treated as a
fresh hold, so the chooser does not reappear mid-chord. Pressing an excluded key
without Option does nothing.

Observing these keys uses a passive, listen-only event tap; AeroSpace never
consumes or rewrites the event. The tap needs Input Monitoring permission. When
the permission is not granted the chooser keeps working normally and shows a
diagnostic instead of failing. Whether an external tool's shortcut is observed
before it acts is up to that tool, so a very quick chord may not be suppressed.

## Columns and empty workspaces

These independent settings control the Option chooser only:

```toml
[workspace-chooser]
columns = "auto"
hide-empty-workspaces = false
```

These are also the defaults when the table or either setting is absent. `columns`
accepts only `"auto"`, `"fixed"`, or `"single"`; `hide-empty-workspaces` must be a
boolean. Unknown keys and invalid types/values produce configuration errors. The separate
`[workspace-chooser-colors]` table continues to control entry colors and bold text.

Use `columns = "fixed"` for exactly two balanced columns: the first holds
`ceil(workspaceCount / 2)` rows and the second holds the remainder. Zero or one
retained workspace uses one column. Fixed mode keeps two columns even when a tall
screen could fit all rows in one; 31 workspaces split 16/15. On narrow screens the
columns narrow and text truncates. Fixed mode never adds a third column to fit
height. Use `columns = "single"` for the original single-column presentation.

The existing `adaptive-columns` boolean remains a compatibility alias:
`true` means `columns = "auto"`, and `false` means `columns = "single"`. Prefer
the new `columns` key; specifying both keys is a configuration error.

Automatic columns (`columns = "auto"`) fill from top to bottom, then left to right, preserving workspace
order. The chooser calculates row capacity from the selected screen's visible
height, keeping 34-point rows, 2-point spacing and room for the header/footer.
It creates only the needed columns, aiming for 336 points of row width per column.
Width stays within the visible screen with a 32-point horizontal margin; columns
can narrow to roughly 240 points before additional columns are stopped. Titles
retain single-line tail truncation. For 31 rows, visible heights of 900 and 800
points need two columns (21 and 18 rows per column respectively), provided the
screen has room for two readable columns. The panel retains its mouse-screen
selection and does not activate or capture mouse events.

With `hide-empty-workspaces = true`, only workspaces with zero owned windows are
omitted; the focused workspace always remains visible even when empty. Floating
windows and hidden-app windows count because they remain descendants of their
workspace. Minimized windows live in a global container without workspace
ownership, so they cannot keep a row visible by themselves. Filtering only changes
this chooser: it does not remove workspaces or change shortcut targets. Filtering
runs before geometry is calculated, and both settings update an open panel on
configuration reload, as do changes to its workspace list.

In fixed or single mode, if rows exceed available height, the scroll view remains,
but this click-through
panel offers no practical mouse scrolling. Extremely narrow/short screens or very
large workspace counts can also exceed the adaptive layout's readable capacity;
all entries remain in the scroll view rather than being dropped. Adaptive columns
do not guarantee that arbitrary workspace counts fit simultaneously.

## Entry text colors

Add one optional table to your `aerospace.toml` to color individual application or
window entries in the Option chooser:

```toml
[workspace-chooser-colors]
"herdr" = "#A6E3A1"
"dev" = "#89B4FA"
"微信" = "#F9E2AF"
```

Each key is a case-insensitive literal substring of an individual displayed entry:
the application name plus its Ghostty title, when available. For example, `微信`
matches both `企业微信` and `微信`; `herdr` and `dev` can color different Ghostty
windows in the same workspace. Rules run in the order written, and the first match
wins: `Ghostty: HERDR dev` matches `herdr` first above. Characters such as `.`, `*`
and `[` are literal text, not regular expressions. Matching includes the window
number when present and colors the entire segment in bold 12-point system text.
Unmatched entries and separators retain their existing font weight. Each segment
is matched separately, before any visual ellipsis, using its full unshortened text.

Empty and whitespace-only keys are rejected. Nonempty patterns are preserved
exactly, including meaningful leading or trailing spaces. Window title whitespace
and control characters are normalized to single spaces and surrounding whitespace
is removed before matching; write patterns against that normalized text. Values
must be quoted `#RRGGBB` colors (six hexadecimal digits, uppercase or lowercase).
Invalid patterns or values produce normal configuration errors.

Other applications match their already available app display names; only Ghostty
has titles in the shared cache. No additional app title reads are performed. Up
to three Ghostty windows per workspace remain separate, even if titles match.
The `+N more Ghostty windows` label is matched independently by the same rules.
Unmatched entries and separators keep secondary text. Workspace names, focus
indicators, monitor fallback labels and the native dropdown keep their existing
colors. The summary remains one compact line with a trailing ellipsis when needed.

Run `aerospace reload-config` after editing, or use existing automatic reload with
`auto-reload-config = true`. Rules update on reload, including an open chooser;
titles still refresh on the next opening. Omitting the table or removing a rule
restores secondary text for unmatched entries. Place root-level settings before
TOML tables, as usual.

## Developer build

With the repository's dependencies and generated files already available:

```sh
swift build --skip-update -Xswiftc -warnings-as-errors
```

The app executable is `.build/debug/AeroSpaceApp`; the CLI is
`.build/debug/aerospace`.

A minimal ARM64 developer bundle was assembled at
`.build/option-hold/AeroSpace-Debug.app` using the SwiftPM executable, bundled
default configuration, and the agent-app metadata from `xcode/project.yml`.
It has an ad hoc signature, rather than a distribution signature, and omits the
Xcode-compiled app icon and asset catalog. It has not been installed or launched.
The repository's existing debug startup can disable the running release server;
plan any manual runtime validation accordingly.

## Optimized Release build

SwiftPM can compile optimized Release executables without Xcode. The repository's
official distribution script still requires Xcode for its app packaging pipeline.
With existing dependencies, generate version metadata and compile with:

```sh
./generate.sh --ignore-xcodeproj --ignore-cmd-help --build-version 0.21.3 --generate-git-hash
swift build -c release --disable-automatic-resolution --skip-update -Xswiftc -warnings-as-errors
```

Generation updates tracked generated files; the build performed for this feature
restored their prior contents after compilation. The embedded hash identifies the
base commit, while this local build also includes the uncommitted chooser changes.

The optimized executables are `.build/release/AeroSpaceApp` and
`.build/release/aerospace`. The manually assembled ARM64 app is
`.build/option-hold/AeroSpace-Release.app`, version `0.21.3`, with bundle identifier
`bobko.aerospace`. It contains the default configuration and an ICNS generated
from the repository's app icon. Its agent-app metadata follows `xcode/project.yml`.
The Xcode-compiled asset catalog is omitted. The app has an ad hoc signature; it is
not Developer ID signed or notarized and is not an official distribution package.

This Release build has `isDebug = false`, so the Debug-only logic that disables
the installed Release server on startup is inactive. It nevertheless uses the
same app identifier and server socket as installed Release versions: do not run
both simultaneously. Neither local bundle has been installed or launched.

## Ghostty window titles

Ghostty entries include their window titles. Other applications keep their
existing app-name summaries. Whitespace, newlines and control characters in
Ghostty titles are normalized to spaces; empty or app-name-only titles fall back
to the application name. Full normalized titles remain in the display cache.

The menu bar dropdown stays on one line, with a trailing ellipsis once the label
exceeds 420 points at the menu font size. The Option chooser shows the focus
indicator, workspace name and summary on one compact, 34-point-high row. The
workspace name takes priority over the summary; both use single-line tail
truncation without shortening cached titles. Its panel is bounded by the screen
and scrolls vertically rather than growing indefinitely.
Long paths and CJK titles follow the same limits.

Multiple Ghostty windows are kept separate and numbered, ordered by window ID.
Up to three titles per workspace are shown; further windows are counted as
`+N more Ghostty windows`. Titles are requested asynchronously only when opening
the chooser or when AppKit reports that the workspace menu begins tracking.
The cached summary is visible immediately, without delaying the Option hold.
Both surfaces share one cancellable fetch task. Closing the last surface cancels
pending work, and moved, closed or replaced windows are checked before accepting
results. Titles refresh on the next opening, not continuously while a surface is
open. Menu tracking uses public NSMenu notifications, rather than assuming a
SwiftUI MenuBarExtra `onAppear` callback fires on every opening.

The updated optimized, ad hoc signed ARM64 bundle is
`.build/window-titles/AeroSpace-Release.app`, version `0.21.3`, identifier
`bobko.aerospace`. It does not overwrite either bundle in `.build/option-hold`.
It is not Developer ID signed or notarized and has not been launched or installed.

The compact single-line chooser is packaged separately at
`.build/compact-titles/AeroSpace-Release.app`, using the metadata and resources
from the window-titles bundle and a freshly compiled Release executable. It has
an ad hoc signature and has not been launched or installed. Neither prior app
bundle is overwritten. Rows are spaced 2 points apart, and panel height is
`min(workspaceCount * 36 + 88, screen.visibleFrame.height - 48)` points. For
example, visible screen heights of 900 and 1080 points allow approximately 21
and 26 rows respectively before scrolling; available space varies by display.

The app-colors build is packaged separately at
`.build/app-colors/AeroSpace-Release.app`, using the compact-titles bundle's
metadata and resources and a freshly compiled Release executable. It has an ad hoc
signature and has not been launched or installed. Earlier bundles are preserved.

The title-colors build is packaged separately at
`.build/title-colors/AeroSpace-Release.app`, using the app-colors metadata and
resources and a freshly compiled Release executable. It is ad hoc signed and has
not been launched or installed; earlier bundles are preserved.

The fixed-column build is packaged separately at
`.build/fixed-columns/AeroSpace-Release.app`, using the auto-place metadata and
resources and a freshly compiled Release executable. It is ad hoc signed and has
not been launched or installed; earlier bundles are preserved.

The adaptive chooser build is packaged separately at
`.build/adaptive-chooser/AeroSpace-Release.app`, using the bold-colors metadata and
resources and a freshly compiled Release executable. It is ad hoc signed and has
not been launched or installed; earlier bundles are preserved.

The unified entry-color build is packaged separately at
`.build/unified-colors/AeroSpace-Release.app`, using the title-colors metadata and
resources and a freshly compiled Release executable. It is ad hoc signed and has
not been launched or installed; earlier bundles are preserved.
