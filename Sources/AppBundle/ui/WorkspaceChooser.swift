import AppKit
import Carbon
import Combine
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
        panel.orderOut(nil)
        TrayMenuModel.shared.hideWorkspaceTitles(.chooser)
    }

    private func handle(_ event: NSEvent) {
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

private final class WorkspaceChooserPanel: NSPanelHud {
    private var updates: AnyCancellable?
    private var presentationScreen: NSScreen?
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    override init() {
        super.init()
        ignoresMouseEvents = true
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

    private func render(workspaces: [WorkspaceViewModel], settings: WorkspaceChooserSettings, screen: NSScreen) {
        let layout = WorkspaceChooserLayout(workspaces: workspaces, settings: settings, availableSize: screen.visibleFrame.size)
        let width = layout.size.width
        let height = layout.size.height
        let view = NSHostingView(rootView: WorkspaceChooserView(model: TrayMenuModel.shared, layout: layout))
        view.frame = NSRect(x: 0, y: 0, width: width, height: height)
        contentView = view
        setFrame(NSRect(
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

    init(workspaces: [WorkspaceViewModel], settings: WorkspaceChooserSettings, availableSize: CGSize) {
        self.workspaces = workspaces.filter { !settings.hideEmptyWorkspaces || !$0.isEffectivelyEmpty || $0.isFocused }
        let count = max(1, self.workspaces.count)
        let maxWidth = max(1, availableSize.width - 32)
        let maxHeight = max(1, availableSize.height - 48)
        let fittingRows = max(1, Int(max(0, maxHeight - 88) / 36))
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
            height: min(maxHeight, CGFloat(rowsPerColumn) * 36 + 88),
        )
    }

    func column(_ index: Int) -> ArraySlice<WorkspaceViewModel> {
        workspaces.dropFirst(index * rowsPerColumn).prefix(rowsPerColumn)
    }
}

private struct WorkspaceChooserView: View {
    @ObservedObject var model: TrayMenuModel
    let layout: WorkspaceChooserLayout

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
                                            Text(workspace.appLabels.isEmpty
                                                 ? AttributedString(String(workspace.suffix.dropFirst(3)))
                                                 : workspaceChooserSummary(workspace.appLabels, colors: model.workspaceChooserColors))
                                                .font(.system(size: 12)).foregroundStyle(.secondary)
                                                .lineLimit(1).truncationMode(.tail)
                                        }
                                        Spacer(minLength: 0)
                                    }
                                    .padding(.horizontal, 10)
                                    .frame(height: 34)
                                    .background(workspace.isFocused ? Color.accentColor.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: 7))
                                    .id(workspace.name)
                                }
                            }
                            .frame(maxWidth: .infinity)
                        }
                    }
                }
                .onAppear { proxy.scrollTo(layout.workspaces.first(where: \.isFocused)?.name, anchor: .center) }
            }
            Text("Use your workspace shortcut to switch")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 10)
        }
        .padding(12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(.primary.opacity(0.08)))
    }
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
