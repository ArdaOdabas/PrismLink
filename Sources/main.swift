import AppKit
import ApplicationServices
import ServiceManagement

let prismBundleID = "com.GraphPad.Prism"
let powerPointBundleID = "com.microsoft.Powerpoint"
let namePrefix = "PrismLink:"
let imageTypes: [NSPasteboard.PasteboardType] = [.pdf, .png, .tiff]

enum LinkError: LocalizedError {
    case message(String)
    var errorDescription: String? {
        if case .message(let text) = self { return text }
        return nil
    }
}

// MARK: - Link storage

struct LinkRecord: Codable {
    let id: String
    let originalPath: String
    let bookmark: Data?
    let snapshot: String
    let created: Date
}

/// Shapes only carry an ID; the project location and a safety copy live here.
final class LinkStore {
    private let objectsDirectory: URL
    private let indexFile: URL
    private var links: [String: LinkRecord] = [:]

    init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("PrismLink", isDirectory: true)
        objectsDirectory = support.appendingPathComponent("Objects", isDirectory: true)
        indexFile = support.appendingPathComponent("links.json")
        try? FileManager.default.createDirectory(at: objectsDirectory, withIntermediateDirectories: true)
        if let data = try? Data(contentsOf: indexFile),
           let decoded = try? JSONDecoder().decode([String: LinkRecord].self, from: data) {
            links = decoded
        }
    }

    func add(project: URL) throws -> LinkRecord {
        let id = UUID().uuidString
        let snapshotName = "\(id).\(project.pathExtension)"
        try FileManager.default.copyItem(at: project, to: objectsDirectory.appendingPathComponent(snapshotName))
        let record = LinkRecord(
            id: id,
            originalPath: project.path,
            bookmark: try? project.bookmarkData(),
            snapshot: snapshotName,
            created: Date()
        )
        links[id] = record
        let data = try JSONEncoder().encode(links)
        try data.write(to: indexFile, options: .atomic)
        return record
    }

    /// Prefers the live project (following moves); falls back to the safety copy.
    func projectURL(for id: String) -> URL? {
        guard let record = links[id] else { return nil }
        if let bookmark = record.bookmark {
            var stale = false
            if let url = try? URL(resolvingBookmarkData: bookmark, options: [.withoutUI], relativeTo: nil, bookmarkDataIsStale: &stale),
               FileManager.default.fileExists(atPath: url.path),
               !url.path.contains("/.Trash/") {
                return url
            }
        }
        if FileManager.default.fileExists(atPath: record.originalPath) {
            return URL(fileURLWithPath: record.originalPath)
        }
        let snapshot = objectsDirectory.appendingPathComponent(record.snapshot)
        return FileManager.default.fileExists(atPath: snapshot.path) ? snapshot : nil
    }
}

// MARK: - PowerPoint

enum PowerPoint {
    static var isRunning: Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: powerPointBundleID).isEmpty
    }

    @discardableResult
    private static func run(_ body: String) throws -> String {
        guard isRunning else { throw LinkError.message("PowerPoint açık değil.") }
        let source = """
        with timeout of 8 seconds
        tell application id "\(powerPointBundleID)"
        \(body)
        end tell
        end timeout
        """
        var errorInfo: NSDictionary?
        guard let script = NSAppleScript(source: source) else {
            throw LinkError.message("AppleScript oluşturulamadı.")
        }
        let result = script.executeAndReturnError(&errorInfo)
        if let errorInfo {
            let text = errorInfo[NSAppleScript.errorMessage] as? String ?? "bilinmeyen hata"
            throw LinkError.message("PowerPoint hatası: \(text)")
        }
        return result.stringValue ?? ""
    }

    /// Name of the single selected shape, or "" when no shape is selected.
    static func selectedShapeName() throws -> String {
        try run("""
        set w to active window
        if selection type of selection of w is not selection type shapes then return ""
        return name of shape range of selection of w
        """)
    }

    static func setSelectedShapeName(_ name: String) throws {
        try run("""
        set w to active window
        set name of shape range of selection of w to "\(name)"
        """)
    }

    /// Pastes the clipboard, moves it onto the linked shape, then removes the old
    /// shape. The old shape is only deleted once the paste has produced a new one.
    static func replaceSelectedShape(linkName: String) throws {
        try run("""
        set w to active window
        set r to shape range of selection of w
        set oldLeft to left position of r
        set oldTop to top of r
        set oldWidth to width of r
        set sl to slide of view of w
        set countBefore to count of shapes of sl
        paste object (view of w)
        delay 0.4
        if (count of shapes of sl) is not (countBefore + 1) then error "Pano yapıştırılamadı."
        set oldShape to missing value
        repeat with i from 1 to count of shapes of sl
            if name of shape i of sl is "\(linkName)" then
                set oldShape to shape i of sl
                exit repeat
            end if
        end repeat
        if oldShape is missing value then error "Eski grafik bulunamadı."
        delete oldShape
        set newShape to shape (count of shapes of sl) of sl
        set width of newShape to oldWidth
        set left position of newShape to oldLeft
        set top of newShape to oldTop
        set name of newShape to "\(linkName)"
        select newShape
        """)
    }
}

// MARK: - Prism

enum Prism {
    static var application: NSRunningApplication? {
        NSRunningApplication.runningApplications(withBundleIdentifier: prismBundleID).first
    }

    /// The focused window's document. Open file handles are not a usable fallback:
    /// Prism keeps a project's file open after its window has closed.
    static func currentProject() -> URL? {
        guard let app = application else { return nil }
        let element = AXUIElementCreateApplication(app.processIdentifier)
        for attribute in [kAXFocusedWindowAttribute, kAXMainWindowAttribute] {
            var window: CFTypeRef?
            guard AXUIElementCopyAttributeValue(element, attribute as CFString, &window) == .success,
                  let window else { continue }
            var document: CFTypeRef?
            if AXUIElementCopyAttributeValue(window as! AXUIElement, kAXDocumentAttribute as CFString, &document) == .success,
               let text = document as? String,
               let url = URL(string: text), url.isFileURL {
                return url
            }
        }
        return nil
    }

    static func open(_ project: URL) throws {
        guard let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: prismBundleID) else {
            throw LinkError.message("Prism bulunamadı.")
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.open([project], withApplicationAt: appURL, configuration: configuration)
    }
}

// MARK: - Permission setup

/// Explains where the permission lives, because macOS 27 moved and renamed it.
final class SetupWindowController: NSObject {
    private static let settingsURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
    private var window: NSWindow?

    var isVisible: Bool { window?.isVisible == true }

    func show() {
        if window == nil { window = makeWindow() }
        NSApp.activate(ignoringOtherApps: true)
        window?.center()
        window?.makeKeyAndOrderFront(nil)
    }

    func close() { window?.orderOut(nil) }

    private func makeWindow() -> NSWindow {
        let isModern = ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 27

        let icon = NSImageView(image: NSApp.applicationIconImage)
        icon.imageScaling = .scaleProportionallyUpOrDown
        NSLayoutConstraint.activate([
            icon.widthAnchor.constraint(equalToConstant: 72),
            icon.heightAnchor.constraint(equalToConstant: 72)
        ])

        let title = NSTextField(labelWithString: "PrismLink'e izin vermen gerekiyor")
        title.font = .boldSystemFont(ofSize: 17)
        let intro = wrapping("PowerPoint'te çift tıklamayı algılamak ve açık Prism projesini bulmak için macOS izni gerekir. Sistem Ayarları'nda PrismLink'in anahtarını aç.")
        let heading = NSStackView(views: [title, intro])
        heading.orientation = .vertical
        heading.alignment = .leading
        heading.spacing = 6

        let top = NSStackView(views: [icon, heading])
        top.alignment = .top
        top.spacing = 16

        let modernRow = row(
            version: "macOS 27 ve üzeri",
            path: "Privacy & Security (Gizlilik ve Güvenlik) → Device Control and Data Access",
            note: "Kenar çubuğundaki “Accessibility” bölümü değil.",
            isCurrent: isModern
        )
        let legacyRow = row(
            version: "macOS 26 ve altı",
            path: "Gizlilik ve Güvenlik (Privacy & Security) → Erişilebilirlik (Accessibility)",
            note: nil,
            isCurrent: !isModern
        )

        let footer = wrapping("PrismLink listede yoksa + düğmesiyle Applications klasöründen ekle. Anahtarı açınca bu pencere kendiliğinden kapanır.")
        footer.textColor = .secondaryLabelColor
        footer.font = .systemFont(ofSize: 12)

        let later = NSButton(title: "Sonra", target: self, action: #selector(dismiss))
        let open = NSButton(title: "Sistem Ayarlarını Aç", target: self, action: #selector(openSettings))
        open.keyEquivalent = "\r"
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let buttons = NSStackView(views: [spacer, later, open])
        buttons.spacing = 10

        let content = NSStackView(views: [top, modernRow, legacyRow, footer, buttons])
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 14
        content.translatesAutoresizingMaskIntoConstraints = false
        for view in [top, modernRow, legacyRow, footer, buttons] {
            view.widthAnchor.constraint(equalToConstant: 476).isActive = true
        }

        let newWindow = NSWindow(contentRect: .zero, styleMask: [.titled, .closable], backing: .buffered, defer: false)
        newWindow.title = "PrismLink Kurulumu"
        newWindow.isReleasedWhenClosed = false
        let container = NSView()
        container.addSubview(content)
        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo: container.topAnchor, constant: 22),
            content.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -20),
            content.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 22),
            content.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -22)
        ])
        newWindow.contentView = container
        newWindow.setContentSize(container.fittingSize)
        return newWindow
    }

    private func wrapping(_ text: String) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: text)
        label.isSelectable = false
        return label
    }

    private func row(version: String, path: String, note: String?, isCurrent: Bool) -> NSView {
        let name = NSTextField(labelWithString: isCurrent ? "\(version)  ·  bu Mac" : version)
        name.font = .boldSystemFont(ofSize: 13)
        name.textColor = isCurrent ? .controlAccentColor : .secondaryLabelColor

        let pathLabel = wrapping(path)
        pathLabel.textColor = isCurrent ? .labelColor : .secondaryLabelColor

        var views: [NSView] = [name, pathLabel]
        if let note {
            let noteLabel = wrapping(note)
            noteLabel.font = .systemFont(ofSize: 12)
            noteLabel.textColor = .secondaryLabelColor
            views.append(noteLabel)
        }
        let stack = NSStackView(views: views)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 3
        return stack
    }

    @objc private func dismiss() { close() }

    @objc private func openSettings() {
        // The prompting call is what adds PrismLink to the permission list.
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
        NSWorkspace.shared.open(Self.settingsURL)
    }
}

// MARK: - Menu bar agent

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let store = LinkStore()
    private let setup = SetupWindowController()
    private let isPreview = CommandLine.arguments.contains("--preview-setup")
    private var statusItem: NSStatusItem!
    private let statusLine = NSMenuItem(title: "Hazır", action: nil, keyEquivalent: "")
    private let permissionItem = NSMenuItem(title: "", action: #selector(requestAccessibility), keyEquivalent: "")
    private let loginItem = NSMenuItem(title: "Oturum açılışında başlat", action: #selector(toggleLogin), keyEquivalent: "")

    private var monitor: Any?
    private var lastChangeCount = NSPasteboard.general.changeCount
    private var pendingProject: URL?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let path = Bundle.main.bundlePath
        if path.hasPrefix("/Volumes/") || path.contains("/AppTranslocation/") {
            refuseTemporaryLocation()
            return
        }

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        let image = NSImage(systemSymbolName: "chart.xyaxis.line", accessibilityDescription: "PrismLink")
        image?.isTemplate = true
        statusItem.button?.image = image

        let menu = NSMenu()
        menu.delegate = self
        menu.autoenablesItems = false
        statusLine.isEnabled = false
        menu.addItem(statusLine)
        menu.addItem(permissionItem)
        menu.addItem(.separator())
        add("Seçili grafiği açık Prism projesine bağla", #selector(linkSelected), to: menu)
        add("Seçili grafiğin Prism projesini aç", #selector(openSelected), to: menu)
        add("Seçili grafiği panodakiyle güncelle", #selector(updateSelected), to: menu)
        menu.addItem(.separator())
        loginItem.target = self
        menu.addItem(loginItem)
        add("Çıkış", #selector(quit), to: menu)
        permissionItem.target = self
        statusItem.menu = menu

        if isPreview || !AXIsProcessTrusted() { setup.show() }
        Timer.scheduledTimer(withTimeInterval: 0.4, repeats: true) { [weak self] _ in self?.pollPasteboard() }
        Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.installMonitorIfTrusted() }
        installMonitorIfTrusted()
    }

    /// A copy running from the disk image would lose its permission on eject.
    private func refuseTemporaryLocation() {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Önce Applications klasörüne taşı"
        alert.informativeText = "PrismLink'i DMG penceresinden Applications klasörüne sürükle ve oradan aç. DMG içinden çalışan kopyaya verilen izin kalıcı olmaz."
        alert.addButton(withTitle: "Tamam")
        alert.runModal()
        NSApp.terminate(nil)
    }

    private func add(_ title: String, _ action: Selector, to menu: NSMenu) {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        menu.addItem(item)
    }

    func menuWillOpen(_ menu: NSMenu) {
        let trusted = AXIsProcessTrusted()
        permissionItem.title = trusted ? "macOS izni: verildi" : "macOS izni ver…"
        permissionItem.isEnabled = !trusted
        loginItem.state = SMAppService.mainApp.status == .enabled ? .on : .off
    }

    // MARK: Events

    private var frontmostBundleID: String? {
        NSWorkspace.shared.frontmostApplication?.bundleIdentifier
    }

    @objc private func requestAccessibility() { setup.show() }

    private func installMonitorIfTrusted() {
        guard AXIsProcessTrusted() else { return }
        if setup.isVisible, !isPreview { setup.close() }
        guard monitor == nil else { return }
        monitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .keyDown]) { [weak self] event in
            self?.handle(event)
        }
    }

    private func handle(_ event: NSEvent) {
        guard frontmostBundleID == powerPointBundleID else { return }
        if event.type == .leftMouseDown, event.clickCount == 2 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in self?.openIfLinked() }
        } else if event.type == .keyDown,
                  event.modifierFlags.contains(.command),
                  event.charactersIgnoringModifiers?.lowercased() == "v",
                  pendingProject != nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in self?.linkPastedShape() }
        }
    }

    /// Remembers which project a graph was copied from, for the next paste.
    private func pollPasteboard() {
        let pasteboard = NSPasteboard.general
        guard pasteboard.changeCount != lastChangeCount else { return }
        lastChangeCount = pasteboard.changeCount
        pendingProject = nil
        guard frontmostBundleID == prismBundleID,
              pasteboard.availableType(from: imageTypes) != nil else { return }
        pendingProject = Prism.currentProject()
        if pendingProject == nil {
            report("Prism projesi bulunamadı: dosyayı önce kaydet.", symbol: "!")
        }
    }

    private func linkPastedShape() {
        guard let project = pendingProject,
              let name = try? PowerPoint.selectedShapeName(),
              !name.isEmpty, !name.hasPrefix(namePrefix) else { return }
        attempt { try link(project: project) }
    }

    private func openIfLinked() {
        guard let name = try? PowerPoint.selectedShapeName(), name.hasPrefix(namePrefix) else { return }
        attempt { try open(linkName: name) }
    }

    // MARK: Actions

    private func link(project: URL) throws {
        let record = try store.add(project: project)
        try PowerPoint.setSelectedShapeName(namePrefix + record.id)
        report("Bağlandı: \(project.lastPathComponent)", symbol: "✓")
    }

    private func open(linkName: String) throws {
        let id = String(linkName.dropFirst(namePrefix.count))
        guard let project = store.projectURL(for: id) else {
            throw LinkError.message("Bu grafiğin projesi bu Mac'te kayıtlı değil.")
        }
        try Prism.open(project)
        report("Açılıyor: \(project.lastPathComponent)", symbol: "✓")
    }

    private func requireSelection() throws -> String {
        let name = try PowerPoint.selectedShapeName()
        guard !name.isEmpty else { throw LinkError.message("PowerPoint'te bir grafik seç.") }
        return name
    }

    private func requireLinkedSelection() throws -> String {
        let name = try requireSelection()
        guard name.hasPrefix(namePrefix) else { throw LinkError.message("Seçili grafik bağlı değil.") }
        return name
    }

    @objc private func linkSelected() {
        attempt {
            _ = try requireSelection()
            guard let project = Prism.currentProject() else {
                throw LinkError.message("Kayıtlı bir Prism projesi açık değil.")
            }
            try link(project: project)
        }
    }

    @objc private func openSelected() {
        attempt { try open(linkName: try requireLinkedSelection()) }
    }

    @objc private func updateSelected() {
        attempt {
            let name = try requireLinkedSelection()
            guard NSPasteboard.general.availableType(from: imageTypes) != nil else {
                throw LinkError.message("Panoda grafik yok: önce Prism'de kopyala.")
            }
            try PowerPoint.replaceSelectedShape(linkName: name)
            report("Grafik güncellendi", symbol: "✓")
        }
    }

    @objc private func toggleLogin() {
        attempt {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        }
    }

    @objc private func quit() { NSApp.terminate(nil) }

    // MARK: Feedback

    private func attempt(_ action: () throws -> Void) {
        do { try action() } catch { report(error.localizedDescription, symbol: "!") }
    }

    private func report(_ text: String, symbol: String) {
        statusLine.title = text
        statusItem.button?.title = " \(symbol)"
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in
            self?.statusItem.button?.title = ""
        }
    }
}

// MARK: - Entry point

/// Command-line hooks so the PowerPoint and Prism bridges can be tested without the UI.
func runSelfTest(_ arguments: [String]) -> Bool {
    guard let command = arguments.first, command.hasPrefix("--selftest-") else { return false }
    do {
        switch command {
        case "--selftest-read": print(try PowerPoint.selectedShapeName())
        case "--selftest-name": try PowerPoint.setSelectedShapeName(arguments[1]); print("ok")
        case "--selftest-replace": try PowerPoint.replaceSelectedShape(linkName: arguments[1]); print("ok")
        case "--selftest-project": print(Prism.currentProject()?.path ?? "<none>")
        default: print("unknown command"); exit(2)
        }
    } catch {
        print("ERROR: \(error.localizedDescription)")
        exit(1)
    }
    return true
}

if runSelfTest(Array(CommandLine.arguments.dropFirst())) { exit(0) }

let application = NSApplication.shared
let delegate = AppDelegate()
application.delegate = delegate
application.setActivationPolicy(.accessory)
application.run()
