# Experimental menu

The native tray's **Experimental** submenu groups this fork's **Auto Place** and
**Workspace Search** actions. The upstream **Experimental UI Settings** menu is
unchanged. Actions require Accessibility access and an enabled server; **Help…**
is available even without either.

**Help…** opens a local, selectable, read-only native help panel covering the
chooser layout, empty-workspace filtering, hold threshold, excluded keys, icons,
entry colors, manual Auto Place rules and persistent search. The canonical help
text and example live in `Sources/AppBundle/ui/ExperimentalMenu.swift` and are
compiled into the app, so help needs no network, resource path or browser.
The window belongs to AeroSpace itself, which is excluded from its managed apps.

Auto Place's textual shortcut hint comes from the current mode (main when no mode
is active), using existing parsed command sequences, including bindings that
reload config before Auto Place. If multiple bindings match, the first key
notation in sorted order is shown. The hint does not register a shortcut or alter
configuration. All actions use the existing native command/session path and
report command failures through the existing message UI.

The separate build is `.build/experimental-menu/AeroSpace-Release.app` with CLI
`.build/experimental-menu/aerospace`. Compilation and source checks do not verify
physical menu clicks, help focus, search typing or IME behavior.
