import AppKit
import Carbon
import Combine
import Common
import CoreGraphics
import SwiftUI

@MainActor
final class WorkspaceChooser {
    static let shared = WorkspaceChooser()

    private let panel = WorkspaceChooserPanel()
    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var timer: Timer?
    private var optionDown = false
    private var pressedAt: TimeInterval?
    private var settingsSubscription: AnyCancellable?
    private var enabledSubscription: AnyCancellable?
    /// Carbon shortcuts (and a global NSEvent monitor) may consume keyDown before we see it, so excluded keys are
    /// observed through a passive CGEventTap. Mirrored here to keep the tap callback a cheap set lookup.
    private var excludedKeyCodes: Set<UInt32> = []
    private var eventTap: CFMachPort?
    private var eventTapSource: CFRunLoopSource?
    /// An excluded key was pressed while Option was held: stay suppressed until every Option key is released.
    private var suppressed = false
    private var reportedMissingTap = false

    private init() {}

    func start() {
        guard globalMonitor == nil, localMonitor == nil else { return }
        let events: NSEvent.EventTypeMask = [.flagsChanged, .keyDown, .keyUp, .leftMouseDown, .rightMouseDown, .otherMouseDown]
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: events) { event in
            MainActor.assumeIsolated { self.handle(event) }
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: events) { event in
            MainActor.assumeIsolated { self.handle(event) }
            return event
        }
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.sessionDidResignActiveNotification, object: nil, queue: .main,
        ) { _ in
            MainActor.assumeIsolated { self.resetState() }
        }
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.willSleepNotification, object: nil, queue: .main,
        ) { _ in
            MainActor.assumeIsolated { self.resetState() }
        }
        settingsSubscription = TrayMenuModel.shared.$workspaceChooser
            .receive(on: RunLoop.main)
            .sink { [weak self] settings in
                MainActor.assumeIsolated { self?.updateExclusions(settings.excludedKeyCodes) }
            }
        enabledSubscription = TrayMenuModel.shared.$isEnabled.sink { [weak self] enabled in
            if !enabled { self?.cancel() }
        }
    }

    /// Keeps the excluded key codes in sync with the published settings. Reload reaches this through the same
    /// subscription, so exclusions update without duplicating monitors or restarting the app.
    private func updateExclusions(_ keyCodes: Set<UInt32>) {
        excludedKeyCodes = keyCodes
        if keyCodes.isEmpty {
            // Nothing to observe: release the tap instead of keeping a listener alive for no reason
            removeEventTap()
        } else {
            installEventTap()
        }
    }

    /// A passive listen-only tap sees keyDown before normal shortcut dispatch. It never consumes or rewrites events.
    private func installEventTap() {
        guard eventTap == nil else { return }
        // Preflight without prompting: excluded keys are a best-effort refinement of a working chooser
        guard CGPreflightListenEventAccess() else {
            reportMissingEventTapOnce()
            return
        }
        let mask: UInt64 = (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.flagsChanged.rawValue)
        guard let tap = unsafe CGEvent.tapCreate(
            tap: .cghidEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: CGEventMask(mask),
            callback: workspaceChooserTapCallback,
            userInfo: nil,
        ) else {
            reportMissingEventTapOnce()
            return
        }
        guard let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0) else {
            CFMachPortInvalidate(tap)
            reportMissingEventTapOnce()
            return
        }
        eventTap = tap
        eventTapSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    private func removeEventTap() {
        if let source = eventTapSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
            CFMachPortInvalidate(tap)
        }
        eventTapSource = nil
        eventTap = nil
    }

    private func reportMissingEventTapOnce() {
        guard !reportedMissingTap else { return }
        reportedMissingTap = true
        let msg = "workspace-chooser.exclude-keys can't observe keys: grant AeroSpace Input Monitoring permission. " +
            "The chooser keeps working, but excluded keys may not take effect."
        MessageModel.shared.message = Message(body: msg, containsWarnings: true)
    }

    /// Runs on the main run loop. Must stay cheap: no AX work, no config parsing, no event mutation.
    fileprivate func handleTapEvent(_ type: CGEventType, keyCode: UInt32, optionDown: Bool) {
        guard !panel.isSearching else { return }
        switch type {
            case .tapDisabledByTimeout, .tapDisabledByUserInput:
                // A slow callback or an explicit disable stops delivery; re-arm so exclusions keep working
                if let tap = eventTap { CGEvent.tapEnable(tap: tap, enable: true) }
            case .keyDown:
                // Read the flags of this event rather than trusting the possibly stale `optionDown`
                if optionDown, excludedKeyCodes.contains(keyCode) {
                    suppressWhileOptionHeld()
                }
            case .flagsChanged:
                // Both Option keys: suppression ends only once no Option remains down
                if !optionDown {
                    self.optionDown = false
                    releaseSuppression()
                }
            default: break
        }
    }

    private func suppressWhileOptionHeld() {
        suppressed = true
        cancel()
    }

    private func releaseSuppression() {
        guard suppressed else { return }
        suppressed = false
        cancel()
    }

    /// Clears all transient state. Session resign and sleep can swallow the release events entirely.
    private func resetState() {
        cancel()
        optionDown = false
        suppressed = false
    }

    func cancel() {
        timer?.invalidate()
        timer = nil
        pressedAt = nil
        panel.dismissSearch()
        panel.orderOut(nil)
        TrayMenuModel.shared.hideWorkspaceTitles(.chooser)
    }

    private func handle(_ event: NSEvent) {
        if panel.isSearching {
            optionDown = event.modifierFlags.contains(.option)
            return
        }
        guard event.type == .flagsChanged else {
            cancel()
            return
        }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let wasDown = optionDown
        optionDown = flags.contains(.option)
        guard flags == .option else {
            cancel()
            // A real Option release ends an excluded-key suppression. Idempotent with the tap's own handling.
            if !optionDown { suppressed = false }
            return
        }
        // Only a fresh Option press may arm the chooser, never the end of a chord.
        // While suppressed, releasing a key that was pressed during the chord must not rearm.
        guard !wasDown, !suppressed, event.keyCode == UInt16(kVK_Option) || event.keyCode == UInt16(kVK_RightOption),
              NSEvent.pressedMouseButtons == 0,
              TrayMenuModel.shared.isEnabled, !IsSecureEventInputEnabled()
        else { return }
        pressedAt = ProcessInfo.processInfo.systemUptime
        let timer = Timer(timeInterval: 0.05, repeats: true) { _ in
            MainActor.assumeIsolated { self.tick() }
        }
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func tick() {
        let flags = NSEvent.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard flags == .option, NSEvent.pressedMouseButtons == 0,
              TrayMenuModel.shared.isEnabled, !IsSecureEventInputEnabled()
        else {
            optionDown = flags.contains(.option)
            cancel()
            return
        }
        guard !suppressed else {
            cancel()
            return
        }
        let threshold = Double(TrayMenuModel.shared.workspaceChooser.holdThresholdMs) / 1000
        guard let pressedAt, ProcessInfo.processInfo.systemUptime - pressedAt >= threshold else { return }
        self.pressedAt = nil
        panel.present()
    }

    func openSearch() -> Bool {
        guard TrayMenuModel.shared.isEnabled, !IsSecureEventInputEnabled() else { return false }
        timer?.invalidate()
        timer = nil
        pressedAt = nil
        return panel.presentSearch()
    }

    func cancelSearch() {
        if panel.isSearching { cancel() }
    }
}

private func workspaceChooserTapCallback(
    proxy _: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    userInfo _: UnsafeMutableRawPointer?,
) -> Unmanaged<CGEvent>? {
    // Extract only Sendable primitives: CGEvent itself is not Sendable
    let keyCode = UInt32(clamping: event.getIntegerValueField(.keyboardEventKeycode))
    let optionDown = event.flags.contains(.maskAlternate)
    MainActor.assumeIsolated { WorkspaceChooser.shared.handleTapEvent(type, keyCode: keyCode, optionDown: optionDown) }
    return unsafe Unmanaged.passUnretained(event)
}

private final class WorkspaceChooserPanel: NSPanelHud, NSSearchFieldDelegate, NSWindowDelegate {
    private var updates: AnyCancellable?
    private var presentationScreen: NSScreen?
    private(set) var isSearching = false
    private let searchField = NSSearchField()
    private var searchHost: NSHostingView<WorkspaceChooserView>?
    private var searchFrame: NSRect?
    private var previousApp: NSRunningApplication?
    private var query = ""
    private var selectedName: String?
    private var results: [WorkspaceViewModel] = []
    override var canBecomeKey: Bool { isSearching }
    override var canBecomeMain: Bool { false }

    override init() {
        super.init()
        ignoresMouseEvents = true
        delegate = self
        searchField.placeholderString = "Search workspaces and applications"
        searchField.delegate = self
        searchField.sendsSearchStringImmediately = true
        searchField.sendsWholeSearchString = false
        searchField.focusRingType = .none
        let model = TrayMenuModel.shared
        updates = model.$workspaces.combineLatest(model.$workspaceChooser)
            .receive(on: RunLoop.main)
            .sink { [weak self] workspaces, settings in
                MainActor.assumeIsolated {
                    guard let self, self.isVisible, let screen = self.presentationScreen else { return }
                    self.render(workspaces: workspaces, settings: settings, screen: screen)
                }
            }
    }

    func present() {
        let model = TrayMenuModel.shared
        guard !model.workspaces.isEmpty,
              let screen = NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) }) ?? NSScreen.screens.first
        else { return }
        presentationScreen = screen
        render(workspaces: model.workspaces, settings: model.workspaceChooser, screen: screen)
        orderFrontRegardless()
        model.showWorkspaceTitles(.chooser)
    }

    func presentSearch() -> Bool {
        if isSearching { return makeFirstResponder(searchField) }
        guard let screen = (isVisible ? presentationScreen : nil) ?? NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) }) ?? NSScreen.screens.first
        else { return false }
        let model = TrayMenuModel.shared
        let ordinary = WorkspaceChooserLayout(workspaces: model.workspaces, settings: model.workspaceChooser, availableSize: screen.visibleFrame.size)
        let origin = isVisible ? frame : NSRect(x: screen.visibleFrame.midX - ordinary.size.width / 2,
                                              y: screen.visibleFrame.midY - ordinary.size.height / 2,
                                              width: ordinary.size.width, height: ordinary.size.height)
        let height = min(screen.visibleFrame.height - 48, ordinary.size.height + 56)
        searchFrame = NSRect(x: origin.minX, y: max(screen.visibleFrame.minY + 24, origin.maxY - height),
                             width: origin.width, height: height)
        presentationScreen = screen
        previousApp = NSWorkspace.shared.frontmostApplication
        query = ""
        searchField.stringValue = ""
        selectedName = nil
        isSearching = true
        ignoresMouseEvents = false
        pauseHotkeysForChooserSearch(true)
        render(workspaces: TrayMenuModel.shared.workspaces, settings: TrayMenuModel.shared.workspaceChooser, screen: screen)
        makeKeyAndOrderFront(nil)
        guard isKeyWindow, makeFirstResponder(searchField) else {
            WorkspaceChooser.shared.cancel()
            return false
        }
        TrayMenuModel.shared.showWorkspaceTitles(.chooser)
        return true
    }

    func dismissSearch(restoreFocus: Bool = true) {
        guard isSearching else { return }
        isSearching = false
        orderOut(nil)
        searchHost = nil
        searchFrame = nil
        ignoresMouseEvents = true
        pauseHotkeysForChooserSearch(false)
        // A nonactivating panel normally returns key focus automatically; only reactivate if AeroSpace became active.
        if restoreFocus, NSWorkspace.shared.frontmostApplication?.processIdentifier == ProcessInfo.processInfo.processIdentifier {
            previousApp?.activate(options: [])
        }
        previousApp = nil
    }

    func windowDidResignKey(_ notification: Notification) {
        guard isSearching else { return }
        dismissSearch(restoreFocus: false)
        WorkspaceChooser.shared.cancel()
    }

    func controlTextDidChange(_ notification: Notification) {
        query = searchField.stringValue
        refreshSearch()
    }

    private func refreshSearch() {
        guard isSearching, let screen = presentationScreen else { return }
        render(workspaces: TrayMenuModel.shared.workspaces, settings: TrayMenuModel.shared.workspaceChooser, screen: screen)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        guard isSearching, !textView.hasMarkedText() else { return false }
        switch commandSelector {
            case #selector(NSResponder.cancelOperation(_:)):
                WorkspaceChooser.shared.cancel()
            case #selector(NSResponder.moveUp(_:)), #selector(NSResponder.moveDown(_:)):
                guard !results.isEmpty else { return true }
                let current = results.firstIndex(where: { $0.name == selectedName }) ?? 0
                let delta = commandSelector == #selector(NSResponder.moveUp(_:)) ? -1 : 1
                selectedName = results[min(max(0, current + delta), results.count - 1)].name
                refreshSearch()
            case #selector(NSResponder.insertNewline(_:)):
                guard let name = selectedName else { return true }
                dismissSearch(restoreFocus: false)
                WorkspaceChooser.shared.cancel()
                Task.startUnstructured {
                    try await runLightSession(.menuBarButton, .checkServerIsEnabledOrDie()) {
                        if case .cmd(let command) = parseCommand(["workspace", "--", name]) {
                            let result = await command.run(.defaultEnv, .emptyStdin)
                            if result.exitCode.rawValue != 0 {
                                MessageModel.shared.message = Message(
                                    description: "Workspace selection failed",
                                    body: result.stderr.joined(separator: "\n"), containsWarnings: false,
                                )
                            }
                        }
                    }
                }
            default: return false
        }
        return true
    }

    private func render(workspaces: [WorkspaceViewModel], settings: WorkspaceChooserSettings, screen: NSScreen) {
        var layout = WorkspaceChooserLayout(workspaces: workspaces, settings: settings, availableSize: screen.visibleFrame.size)
        if isSearching {
            results = workspaceChooserSearch(workspaces: layout.workspaces, query: query)
            if !results.contains(where: { $0.name == selectedName }) { selectedName = results.first?.name }
            layout = WorkspaceChooserLayout(workspaces: results, settings: settings, availableSize: screen.visibleFrame.size, searching: true)
        }
        let width = searchFrame?.width ?? layout.size.width
        let height = searchFrame?.height ?? layout.size.height
        let root = WorkspaceChooserView(model: TrayMenuModel.shared, layout: layout, isSearching: isSearching, selectedName: selectedName)
        let view = searchHost ?? (contentView as? NSHostingView<WorkspaceChooserView>) ?? NSHostingView(rootView: root)
        view.rootView = root
        view.frame = NSRect(x: 0, y: 0, width: width, height: height)
        if isSearching {
            if searchHost == nil {
                searchHost = view
                let container = NSView()
                container.addSubview(view)
                container.addSubview(searchField)
                contentView = container
            }
            searchField.frame = NSRect(x: 22, y: 38, width: max(1, width - 44), height: 28)
        } else {
            contentView = view
        }
        setFrame(searchFrame ?? NSRect(
            x: screen.visibleFrame.midX - width / 2,
            y: screen.visibleFrame.midY - height / 2,
            width: width, height: height,
        ), display: true)
    }
}

struct WorkspaceChooserLayout {
    let workspaces: [WorkspaceViewModel]
    let rowsPerColumn: Int
    let columnCount: Int
    let size: CGSize

    init(workspaces: [WorkspaceViewModel], settings: WorkspaceChooserSettings, availableSize: CGSize, searching: Bool = false) {
        self.workspaces = workspaces.filter { !settings.hideEmptyWorkspaces || !$0.isEffectivelyEmpty || $0.isFocused }
        let count = max(1, self.workspaces.count)
        let maxWidth = max(1, availableSize.width - 32)
        let maxHeight = max(1, availableSize.height - 48)
        let overhead: CGFloat = searching ? 144 : 88
        let fittingRows = max(1, Int(max(0, maxHeight - overhead) / 36))
        let fittingColumns = max(1, Int(max(0, maxWidth - 24 + 12) / 252))
        switch settings.columns {
            case .auto:
                columnCount = min((count + fittingRows - 1) / fittingRows, fittingColumns)
                rowsPerColumn = max(min(count, fittingRows), (count + columnCount - 1) / columnCount)
            case .fixed:
                columnCount = min(2, count)
                rowsPerColumn = (count + columnCount - 1) / columnCount
            case .single:
                columnCount = 1
                rowsPerColumn = count
        }
        size = CGSize(
            width: min(maxWidth, CGFloat(columnCount) * 336 + CGFloat(columnCount - 1) * 12 + 24),
            height: min(maxHeight, CGFloat(rowsPerColumn) * 36 + overhead),
        )
    }

    func column(_ index: Int) -> ArraySlice<WorkspaceViewModel> {
        workspaces.dropFirst(index * rowsPerColumn).prefix(rowsPerColumn)
    }
}

private struct WorkspaceChooserView: View {
    @ObservedObject var model: TrayMenuModel
    let layout: WorkspaceChooserLayout
    var isSearching = false
    var selectedName: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Workspaces").font(.system(size: 13, weight: .semibold))
                Spacer()
                Text("⌥").font(.system(size: 17, weight: .medium)).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 10)
            ScrollViewReader { proxy in
                ScrollView {
                    HStack(alignment: .top, spacing: 12) {
                        if isSearching, layout.workspaces.isEmpty {
                            Text("No matching workspaces").font(.system(size: 12)).foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, minHeight: 34)
                        }
                        ForEach(0 ..< layout.columnCount, id: \.self) { column in
                            VStack(spacing: 2) {
                                ForEach(layout.column(column), id: \.name) { workspace in
                                    HStack(spacing: 10) {
                                        Image(systemName: workspace.isFocused ? "checkmark.circle.fill" : "circle")
                                            .foregroundStyle(workspace.isFocused ? Color.accentColor : Color.secondary)
                                        Text(workspace.name)
                                            .font(.system(size: 13, weight: .semibold, design: .monospaced))
                                            .lineLimit(1).truncationMode(.tail)
                                            .layoutPriority(1)
                                        if !workspace.suffix.isEmpty {
                                            if model.workspaceChooser.showAppIcons, !workspace.appEntries.isEmpty {
                                                workspaceChooserIconSummary(workspace.appEntries, model: model)
                                                    .font(.system(size: 12)).foregroundStyle(.secondary)
                                                    .lineLimit(1).truncationMode(.tail)
                                                    .accessibilityLabel(workspace.appLabels.joined(separator: ", "))
                                            } else {
                                            Text(workspace.appLabels.isEmpty
                                                 ? AttributedString(String(workspace.suffix.dropFirst(3)))
                                                 : workspaceChooserSummary(workspace.appLabels, colors: model.workspaceChooserColors))
                                                .font(.system(size: 12)).foregroundStyle(.secondary)
                                                .lineLimit(1).truncationMode(.tail)
                                            }
                                        }
                                        Spacer(minLength: 0)
                                    }
                                    .padding(.horizontal, 10)
                                    .frame(height: 34)
                                    .background((isSearching ? workspace.name == selectedName : workspace.isFocused) ? Color.accentColor.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: 7))
                                    .id(workspace.name)
                                }
                            }
                            .frame(maxWidth: .infinity)
                        }
                    }
                }
                .onAppear { proxy.scrollTo(isSearching ? selectedName : layout.workspaces.first(where: \.isFocused)?.name, anchor: .center) }
                .onChange(of: selectedName) { name in proxy.scrollTo(name, anchor: .center) }
            }
            if isSearching {
                Color.clear.frame(height: 32)
                    .padding(.top, 4)
            }
            Text(isSearching ? "↑ ↓ Navigate · Return Switch · Esc Cancel" : "Use your workspace shortcut to switch")
                .font(.system(size: 11))
                .frame(height: isSearching ? 14 : nil)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 10)
        }
        .padding(12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(.primary.opacity(0.08)))
    }
}

@MainActor
private func workspaceChooserIconSummary(_ entries: [WorkspaceAppEntry], model: TrayMenuModel) -> Text {
    var summary = Text("")
    for (index, entry) in entries.enumerated() {
        if index > 0 { summary = summary + Text(", ") }
        if let icon = model.chooserIcon(pid: entry.pid) {
            summary = summary + Text(Image(nsImage: icon)).baselineOffset(-3) + Text(" ")
        }
        summary = summary + Text(workspaceChooserSummary([entry.label], colors: model.workspaceChooserColors))
    }
    return summary
}

func workspaceChooserSummary(_ labels: [String], colors: [(pattern: String, rgb: UInt32)]) -> AttributedString {
    var summary = AttributedString()
    for label in labels where !label.isEmpty {
        if !summary.characters.isEmpty { summary += AttributedString(", ") }
        var text = AttributedString(label)
        if let rgb = colors.first(where: { label.range(of: $0.pattern, options: .caseInsensitive) != nil })?.rgb {
            text.font = .system(size: 12, weight: .bold)
            text.foregroundColor = Color(
                .sRGB, red: Double((rgb >> 16) & 0xFF) / 255,
                green: Double((rgb >> 8) & 0xFF) / 255, blue: Double(rgb & 0xFF) / 255, opacity: 1,
            )
        }
        summary += text
    }
    return summary
}
