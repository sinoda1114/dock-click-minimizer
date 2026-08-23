import AppKit
import ApplicationServices
import DockClickMinimizerCore
import Foundation
import ServiceManagement
import UniformTypeIdentifiers

@MainActor
private final class DockClickMinimizer: NSObject, NSMenuDelegate {
    private struct PendingDockClick {
        let bundleIdentifier: String
        let pid: pid_t
        let focusedWindow: AXUIElement?
        let focusedWindowWasUnminimized: Bool
    }

    private enum Defaults {
        static let excludedBundleIdentifiers = "excludedBundleIdentifiers"
        static let didConfigureLaunchAtLogin = "didConfigureLaunchAtLogin"
    }

    private var lastHandledAt = Date.distantPast
    private var pendingDockClick: PendingDockClick?
    private var statusItem: NSStatusItem?
    private var settingsWindow: NSWindow?
    private var registeredAppsStackView: NSStackView?
    private var lastRegularFrontmostApplication: NSRunningApplication?
    private let appToggleMenuItem = NSMenuItem(title: "", action: #selector(toggleFrontmostAppExclusion), keyEquivalent: "")
    private let excludedAppsMenuItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let launchAtLoginMenuItem = NSMenuItem(title: "ログイン時に起動", action: #selector(toggleLaunchAtLogin), keyEquivalent: "")
    private let debounceInterval: TimeInterval = 0.45
    private let dockSettlingDelay: Duration = .milliseconds(80)

    func run() -> Bool {
        if CommandLine.arguments.contains("--register-login-item") {
            registerLaunchAtLoginForDiagnostics()
            return false
        }

        if CommandLine.arguments.contains("--diagnose") {
            printDiagnostics()
            return false
        }

        requestAccessibilityIfNeeded()
        installStatusItem()
        registerLaunchAtLoginIfNeeded()
        installActivationObserver()

        NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown]) { [weak self] _ in
            let clickPoint = NSEvent.mouseLocation
            Task { @MainActor [weak self] in
                self?.handleMouseDown(at: clickPoint)
            }
        }

        NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseUp]) { [weak self] _ in
            let clickPoint = NSEvent.mouseLocation
            Task { @MainActor [weak self] in
                self?.handleMouseUp(at: clickPoint)
            }
        }

        print("Dock Click Minimizer は実行中です。停止するには Ctrl-C を押してください。")
        NSApplication.shared.setActivationPolicy(.accessory)
        return true
    }

    private func handleMouseDown(at clickPoint: NSPoint) {
        let now = Date()
        guard now.timeIntervalSince(lastHandledAt) > debounceInterval else {
            return
        }

        guard isInDockArea(clickPoint) else {
            return
        }

        guard let app = NSWorkspace.shared.frontmostApplication,
              app.activationPolicy == .regular,
              let bundleIdentifier = app.bundleIdentifier,
              bundleIdentifier != "com.apple.dock",
              !isExcluded(bundleIdentifier) else {
            return
        }

        guard isDockAppIconClick(at: clickPoint, for: app) else {
            return
        }

        let focusedWindow = focusedWindow(for: app.processIdentifier)
        pendingDockClick = PendingDockClick(
            bundleIdentifier: bundleIdentifier,
            pid: app.processIdentifier,
            focusedWindow: focusedWindow,
            focusedWindowWasUnminimized: focusedWindow.map { !isMinimized($0) } ?? false
        )
    }

    private func handleMouseUp(at clickPoint: NSPoint) {
        guard isInDockArea(clickPoint), let pendingDockClick else {
            self.pendingDockClick = nil
            return
        }

        self.pendingDockClick = nil

        Task { @MainActor [weak self] in
            try? await Task.sleep(for: self?.dockSettlingDelay ?? .milliseconds(80))
            guard let self else {
                return
            }

            let current = NSWorkspace.shared.frontmostApplication
            guard current?.bundleIdentifier == pendingDockClick.bundleIdentifier else {
                return
            }

            guard pendingDockClick.focusedWindowWasUnminimized,
                  let focusedWindow = pendingDockClick.focusedWindow else {
                return
            }

            self.lastHandledAt = Date()
            if !self.minimizeWindow(focusedWindow) {
                NSRunningApplication(processIdentifier: pendingDockClick.pid)?.hide()
            }
        }
    }

    private func installStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = statusBarIcon()
        item.button?.imagePosition = .imageOnly
        item.button?.toolTip = "Dock Click Minimizer は実行中です"

        let menu = NSMenu()
        menu.delegate = self
        let status = NSMenuItem(title: "Dock Click Minimizer：実行中", action: nil, keyEquivalent: "")
        status.isEnabled = false
        menu.addItem(status)
        menu.addItem(NSMenuItem.separator())
        appToggleMenuItem.target = self
        menu.addItem(appToggleMenuItem)
        excludedAppsMenuItem.isEnabled = false
        menu.addItem(excludedAppsMenuItem)
        menu.addItem(NSMenuItem.separator())
        launchAtLoginMenuItem.target = self
        menu.addItem(launchAtLoginMenuItem)
        menu.addItem(NSMenuItem.separator())
        let settingsItem = NSMenuItem(title: "設定...", action: #selector(openSettings), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "終了", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))

        item.menu = menu
        statusItem = item
    }

    private func installActivationObserver() {
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(applicationDidActivate(_:)),
            name: NSWorkspace.didActivateApplicationNotification,
            object: nil
        )
        updateLastRegularFrontmostApplication(NSWorkspace.shared.frontmostApplication)
    }

    func menuWillOpen(_ menu: NSMenu) {
        refreshMenuItems()
    }

    private func refreshMenuItems() {
        refreshLaunchAtLoginMenuItem()

        guard let app = candidateApplication(),
              let bundleIdentifier = app.bundleIdentifier else {
            appToggleMenuItem.title = "前面アプリがありません"
            appToggleMenuItem.isEnabled = false
            excludedAppsMenuItem.title = excludedAppsSummary()
            return
        }

        let appName = app.localizedName ?? bundleIdentifier
        appToggleMenuItem.isEnabled = true
        appToggleMenuItem.title = isExcluded(bundleIdentifier)
            ? "\(appName) の除外を解除"
            : "\(appName) を除外"
        excludedAppsMenuItem.title = excludedAppsSummary()
    }

    private func registerLaunchAtLoginIfNeeded() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: Defaults.didConfigureLaunchAtLogin) else {
            return
        }

        let service = SMAppService.mainApp
        switch service.status {
        case .enabled, .requiresApproval:
            defaults.set(true, forKey: Defaults.didConfigureLaunchAtLogin)
        case .notRegistered, .notFound:
            do {
                try service.register()
                defaults.set(true, forKey: Defaults.didConfigureLaunchAtLogin)
            } catch {
                print("ログイン項目の自動登録に失敗しました: \(error.localizedDescription)")
            }
        @unknown default:
            print("ログイン項目の状態を確認できませんでした。")
        }

        refreshLaunchAtLoginMenuItem()
    }

    @objc private func toggleLaunchAtLogin() {
        let service = SMAppService.mainApp

        do {
            switch service.status {
            case .enabled:
                try service.unregister()
            case .notRegistered, .notFound:
                try service.register()
                UserDefaults.standard.set(true, forKey: Defaults.didConfigureLaunchAtLogin)
            case .requiresApproval:
                SMAppService.openSystemSettingsLoginItems()
            @unknown default:
                showLoginItemError("ログイン項目の状態を確認できませんでした。")
            }
        } catch {
            showLoginItemError(error.localizedDescription)
        }

        refreshLaunchAtLoginMenuItem()
    }

    private func refreshLaunchAtLoginMenuItem() {
        switch SMAppService.mainApp.status {
        case .enabled:
            launchAtLoginMenuItem.title = "ログイン時に起動"
            launchAtLoginMenuItem.state = .on
            launchAtLoginMenuItem.isEnabled = true
        case .notRegistered:
            launchAtLoginMenuItem.title = "ログイン時に起動"
            launchAtLoginMenuItem.state = .off
            launchAtLoginMenuItem.isEnabled = true
        case .requiresApproval:
            launchAtLoginMenuItem.title = "ログイン時に起動（承認が必要）"
            launchAtLoginMenuItem.state = .mixed
            launchAtLoginMenuItem.isEnabled = true
        case .notFound:
            launchAtLoginMenuItem.title = "ログイン時に起動"
            launchAtLoginMenuItem.state = .off
            launchAtLoginMenuItem.isEnabled = true
        @unknown default:
            launchAtLoginMenuItem.title = "ログイン時に起動（状態不明）"
            launchAtLoginMenuItem.state = .off
            launchAtLoginMenuItem.isEnabled = false
        }
    }

    private func showLoginItemError(_ message: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "ログイン時の自動起動を変更できませんでした"
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    @objc private func toggleFrontmostAppExclusion() {
        guard let app = candidateApplication(),
              let bundleIdentifier = app.bundleIdentifier else {
            return
        }

        var excluded = excludedBundleIdentifiers()
        if excluded.contains(bundleIdentifier) {
            excluded.remove(bundleIdentifier)
        } else {
            excluded.insert(bundleIdentifier)
        }
        saveExcludedBundleIdentifiers(excluded)
        refreshMenuItems()
        refreshSettingsWindow()
    }

    @objc private func applicationDidActivate(_ notification: Notification) {
        let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
        updateLastRegularFrontmostApplication(app)
    }

    private func updateLastRegularFrontmostApplication(_ app: NSRunningApplication?) {
        guard let app,
              app.activationPolicy == .regular,
              let bundleIdentifier = app.bundleIdentifier,
              bundleIdentifier != Bundle.main.bundleIdentifier else {
            return
        }
        lastRegularFrontmostApplication = app
    }

    private func candidateApplication() -> NSRunningApplication? {
        if let app = NSWorkspace.shared.frontmostApplication,
           app.activationPolicy == .regular,
           app.bundleIdentifier != Bundle.main.bundleIdentifier {
            return app
        }
        return lastRegularFrontmostApplication
    }

    @objc private func openSettings() {
        if settingsWindow == nil {
            settingsWindow = makeSettingsWindow()
        }
        refreshSettingsWindow()
        settingsWindow?.center()
        settingsWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func makeSettingsWindow() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 420),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Dock Click Minimizer 設定"
        window.isReleasedWhenClosed = false

        let contentView = NSView()
        contentView.translatesAutoresizingMaskIntoConstraints = false

        let rootStack = NSStackView()
        rootStack.orientation = .vertical
        rootStack.alignment = .leading
        rootStack.spacing = 14
        rootStack.translatesAutoresizingMaskIntoConstraints = false

        let titleLabel = NSTextField(labelWithString: "除外するアプリ")
        titleLabel.font = .systemFont(ofSize: 18, weight: .semibold)

        let descriptionLabel = NSTextField(wrappingLabelWithString: "基本的にすべてのアプリで動作します。Chrome など挙動が合わないアプリだけここに登録すると、そのアプリでは Dock クリックによる最小化を行いません。")
        descriptionLabel.textColor = .secondaryLabelColor
        descriptionLabel.font = .systemFont(ofSize: 12)
        descriptionLabel.translatesAutoresizingMaskIntoConstraints = false

        let addButton = NSButton(title: "前面アプリを除外", target: self, action: #selector(excludeCurrentAppFromSettings))
        addButton.bezelStyle = .rounded

        let listStack = NSStackView()
        listStack.orientation = .vertical
        listStack.alignment = .leading
        listStack.spacing = 8
        listStack.translatesAutoresizingMaskIntoConstraints = false
        registeredAppsStackView = listStack

        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.borderType = .bezelBorder
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        let documentView = NSView()
        documentView.translatesAutoresizingMaskIntoConstraints = false
        documentView.addSubview(listStack)
        scrollView.documentView = documentView

        rootStack.addArrangedSubview(titleLabel)
        rootStack.addArrangedSubview(descriptionLabel)
        rootStack.addArrangedSubview(addButton)
        rootStack.addArrangedSubview(scrollView)
        contentView.addSubview(rootStack)
        window.contentView = contentView

        NSLayoutConstraint.activate([
            rootStack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 20),
            rootStack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -20),
            rootStack.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 20),
            rootStack.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -20),
            descriptionLabel.widthAnchor.constraint(equalTo: rootStack.widthAnchor),
            scrollView.widthAnchor.constraint(equalTo: rootStack.widthAnchor),
            scrollView.heightAnchor.constraint(equalToConstant: 250),
            documentView.widthAnchor.constraint(equalTo: scrollView.contentView.widthAnchor),
            listStack.leadingAnchor.constraint(equalTo: documentView.leadingAnchor, constant: 10),
            listStack.trailingAnchor.constraint(equalTo: documentView.trailingAnchor, constant: -10),
            listStack.topAnchor.constraint(equalTo: documentView.topAnchor, constant: 10),
            listStack.bottomAnchor.constraint(lessThanOrEqualTo: documentView.bottomAnchor, constant: -10)
        ])

        return window
    }

    @objc private func excludeCurrentAppFromSettings() {
        guard let app = candidateApplication(),
              let bundleIdentifier = app.bundleIdentifier else {
            return
        }
        var excluded = excludedBundleIdentifiers()
        excluded.insert(bundleIdentifier)
        saveExcludedBundleIdentifiers(excluded)
        refreshMenuItems()
        refreshSettingsWindow()
    }

    @objc private func removeExcludedApp(_ sender: NSButton) {
        guard let bundleIdentifier = sender.identifier?.rawValue else {
            return
        }
        var excluded = excludedBundleIdentifiers()
        excluded.remove(bundleIdentifier)
        saveExcludedBundleIdentifiers(excluded)
        refreshMenuItems()
        refreshSettingsWindow()
    }

    private func refreshSettingsWindow() {
        guard let stackView = registeredAppsStackView else {
            return
        }

        for view in stackView.arrangedSubviews {
            stackView.removeArrangedSubview(view)
            view.removeFromSuperview()
        }

        let bundleIdentifiers = excludedBundleIdentifiers().sorted {
            appDisplayName(for: $0).localizedCaseInsensitiveCompare(appDisplayName(for: $1)) == .orderedAscending
        }

        if bundleIdentifiers.isEmpty {
            let emptyLabel = NSTextField(wrappingLabelWithString: "除外中のアプリはありません。挙動が合わないアプリを前面にして「前面アプリを除外」を押してください。")
            emptyLabel.textColor = .secondaryLabelColor
            emptyLabel.font = .systemFont(ofSize: 12)
            stackView.addArrangedSubview(emptyLabel)
            return
        }

        for bundleIdentifier in bundleIdentifiers {
            stackView.addArrangedSubview(settingsRow(for: bundleIdentifier))
        }
    }

    private func settingsRow(for bundleIdentifier: String) -> NSView {
        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 10
        row.translatesAutoresizingMaskIntoConstraints = false

        let iconView = NSImageView()
        iconView.image = appIcon(for: bundleIdentifier)
        iconView.imageScaling = .scaleProportionallyUpOrDown
        iconView.translatesAutoresizingMaskIntoConstraints = false

        let nameLabel = NSTextField(labelWithString: appDisplayName(for: bundleIdentifier))
        nameLabel.lineBreakMode = .byTruncatingTail

        let bundleLabel = NSTextField(labelWithString: bundleIdentifier)
        bundleLabel.textColor = .secondaryLabelColor
        bundleLabel.font = .systemFont(ofSize: 10)
        bundleLabel.lineBreakMode = .byTruncatingTail

        let labelStack = NSStackView()
        labelStack.orientation = .vertical
        labelStack.alignment = .leading
        labelStack.spacing = 2
        labelStack.addArrangedSubview(nameLabel)
        labelStack.addArrangedSubview(bundleLabel)

        let removeButton = NSButton(title: "除外解除", target: self, action: #selector(removeExcludedApp(_:)))
        removeButton.bezelStyle = .rounded
        removeButton.identifier = NSUserInterfaceItemIdentifier(bundleIdentifier)

        row.addArrangedSubview(iconView)
        row.addArrangedSubview(labelStack)
        row.addArrangedSubview(removeButton)

        NSLayoutConstraint.activate([
            iconView.widthAnchor.constraint(equalToConstant: 28),
            iconView.heightAnchor.constraint(equalToConstant: 28),
            labelStack.widthAnchor.constraint(greaterThanOrEqualToConstant: 260)
        ])

        return row
    }

    private func appDisplayName(for bundleIdentifier: String) -> String {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier),
              let bundle = Bundle(url: url) else {
            return bundleIdentifier
        }
        return bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
            ?? bundle.object(forInfoDictionaryKey: "CFBundleName") as? String
            ?? url.deletingPathExtension().lastPathComponent
    }

    private func appIcon(for bundleIdentifier: String) -> NSImage? {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) else {
            return NSWorkspace.shared.icon(for: .applicationBundle)
        }
        return NSWorkspace.shared.icon(forFile: url.path)
    }

    private func statusBarIcon() -> NSImage {
        let size = NSSize(width: 18, height: 18)
        let image = NSImage(size: size)
        image.lockFocus()
        defer { image.unlockFocus() }

        NSColor.labelColor.setFill()
        NSColor.labelColor.setStroke()

        let window = NSBezierPath(roundedRect: NSRect(x: 3.2, y: 4.8, width: 11.6, height: 9.5), xRadius: 1.8, yRadius: 1.8)
        window.lineWidth = 1.6
        window.stroke()

        let titleBar = NSBezierPath()
        titleBar.lineWidth = 1.4
        titleBar.lineCapStyle = .round
        titleBar.move(to: NSPoint(x: 5.2, y: 12.1))
        titleBar.line(to: NSPoint(x: 12.8, y: 12.1))
        titleBar.stroke()

        let stem = NSBezierPath()
        stem.lineWidth = 1.8
        stem.lineCapStyle = .round
        stem.move(to: NSPoint(x: 9, y: 10.5))
        stem.line(to: NSPoint(x: 9, y: 5.1))
        stem.stroke()

        let arrow = NSBezierPath()
        arrow.lineWidth = 1.8
        arrow.lineCapStyle = .round
        arrow.lineJoinStyle = .round
        arrow.move(to: NSPoint(x: 6.6, y: 7.1))
        arrow.line(to: NSPoint(x: 9, y: 4.7))
        arrow.line(to: NSPoint(x: 11.4, y: 7.1))
        arrow.stroke()

        let bar = NSBezierPath(roundedRect: NSRect(x: 5.2, y: 2.4, width: 7.6, height: 1.7), xRadius: 0.85, yRadius: 0.85)
        bar.fill()

        image.isTemplate = true
        image.accessibilityDescription = "Dock Click Minimizer"
        return image
    }

    private func requestAccessibilityIfNeeded() {
        let options = [
            "AXTrustedCheckOptionPrompt": true
        ] as CFDictionary

        if !AXIsProcessTrustedWithOptions(options) {
            print("アクセシビリティ権限が必要です。システム設定 > プライバシーとセキュリティ > アクセシビリティで Dock Click Minimizer を許可してから、起動し直してください。")
        }
    }

    private func isDockAppIconClick(at point: NSPoint, for app: NSRunningApplication) -> Bool {
        guard let appName = app.localizedName else {
            return false
        }

        return dockElementTitle(at: point)
            .map { normalizedAppName($0) == normalizedAppName(appName) }
            ?? false
    }

    private func dockElementTitle(at point: NSPoint) -> String? {
        let systemWideElement = AXUIElementCreateSystemWide()
        let candidatePoints = axCandidatePoints(for: point)

        for candidate in candidatePoints {
            var element: AXUIElement?
            let result = AXUIElementCopyElementAtPosition(
                systemWideElement,
                Float(candidate.x),
                Float(candidate.y),
                &element
            )

            guard result == .success, let element else {
                continue
            }

            if let title = stringAttribute(kAXTitleAttribute, from: element), !title.isEmpty {
                return title
            }
        }

        return nil
    }

    private func axCandidatePoints(for point: NSPoint) -> [NSPoint] {
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(point) }) else {
            return [point]
        }

        let flippedY = screen.frame.maxY - (point.y - screen.frame.minY)
        let flipped = NSPoint(x: point.x, y: flippedY)
        return [point, flipped]
    }

    private func stringAttribute(_ attribute: String, from element: AXUIElement) -> String? {
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
        guard result == .success else {
            return nil
        }
        return value as? String
    }

    private func normalizedAppName(_ value: String) -> String {
        value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
    }

    private func isExcluded(_ bundleIdentifier: String) -> Bool {
        excludedBundleIdentifiers().contains(bundleIdentifier)
    }

    private func excludedBundleIdentifiers() -> Set<String> {
        let values = UserDefaults.standard.stringArray(forKey: Defaults.excludedBundleIdentifiers) ?? []
        return Set(values)
    }

    private func saveExcludedBundleIdentifiers(_ values: Set<String>) {
        UserDefaults.standard.set(values.sorted(), forKey: Defaults.excludedBundleIdentifiers)
    }

    private func excludedAppsSummary() -> String {
        let count = excludedBundleIdentifiers().count
        return count == 0 ? "除外アプリなし" : "除外アプリ：\(count) 件"
    }

    private func focusedWindow(for pid: pid_t) -> AXUIElement? {
        let appElement = AXUIElementCreateApplication(pid)
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(appElement, kAXFocusedWindowAttribute as CFString, &value)

        guard result == .success else {
            return nil
        }
        return value.map { unsafeDowncast($0, to: AXUIElement.self) }
    }

    private func isMinimized(_ window: AXUIElement) -> Bool {
        var minimizedValue: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(
            window,
            kAXMinimizedAttribute as CFString,
            &minimizedValue
        )

        guard result == .success else {
            return true
        }

        return (minimizedValue as? Bool) ?? true
    }

    private func minimizeWindow(_ window: AXUIElement) -> Bool {
        AXUIElementSetAttributeValue(
            window,
            kAXMinimizedAttribute as CFString,
            kCFBooleanTrue
        ) == .success
    }

    private func isInDockArea(_ point: NSPoint) -> Bool {
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(point) }) else {
            return false
        }

        return dockGeometry(for: screen).contains(point)
    }

    private func dockGeometry(for screen: NSScreen) -> DockGeometry {
        let defaults = UserDefaults(suiteName: "com.apple.dock")
        let orientationValue = defaults?.string(forKey: "orientation") ?? "bottom"
        let orientation = DockOrientation(rawValue: orientationValue) ?? .bottom
        let tileSize = defaults?.double(forKey: "tilesize") ?? 64
        let magnificationEnabled = defaults?.bool(forKey: "magnification") ?? false
        let magnificationSize = defaults?.double(forKey: "largesize") ?? tileSize

        return DockGeometry(
            orientation: orientation,
            screenFrame: screen.frame,
            tileSize: CGFloat(tileSize),
            magnificationEnabled: magnificationEnabled,
            magnificationSize: CGFloat(magnificationSize)
        )
    }

    private func printDiagnostics() {
        let accessibility = AXIsProcessTrusted() ? "trusted" : "not-trusted"
        let screen = NSScreen.main ?? NSScreen.screens.first

        print("accessibility=\(accessibility)")
        print("launch-at-login=\(launchAtLoginStatusText(SMAppService.mainApp.status))")
        if let screen {
            let geometry = dockGeometry(for: screen)
            print("orientation=\(geometry.orientation.rawValue)")
            print("dock-thickness=\(Int(geometry.activeDockThickness))")
            print("screen=\(Int(geometry.screenFrame.width))x\(Int(geometry.screenFrame.height))")
        } else {
            print("screen=unavailable")
        }
    }

    private func registerLaunchAtLoginForDiagnostics() {
        let service = SMAppService.mainApp
        print("launch-at-login-before=\(launchAtLoginStatusText(service.status))")

        do {
            try service.register()
            UserDefaults.standard.set(true, forKey: Defaults.didConfigureLaunchAtLogin)
            print("launch-at-login-after=\(launchAtLoginStatusText(service.status))")
        } catch {
            print("launch-at-login-error=\(error.localizedDescription)")
        }
    }

    private func launchAtLoginStatusText(_ status: SMAppService.Status) -> String {
        switch status {
        case .notRegistered:
            return "not-registered"
        case .enabled:
            return "enabled"
        case .requiresApproval:
            return "requires-approval"
        case .notFound:
            return "not-found"
        @unknown default:
            return "unknown"
        }
    }
}

private let app = NSApplication.shared
private let minimizer = DockClickMinimizer()
if minimizer.run() {
    app.run()
}
