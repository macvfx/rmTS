import AppKit
import Darwin
import Foundation
import Security

@_silgen_name("TCCAuthorizationExecuteWithPrivileges")
private func TCCAuthorizationExecuteWithPrivileges(
    _ authorization: AuthorizationRef,
    _ executablePath: UnsafePointer<CChar>,
    _ arguments: UnsafePointer<UnsafeMutablePointer<CChar>>,
    _ communicationsPipe: UnsafeMutablePointer<UnsafeMutablePointer<FILE>?>
) -> OSStatus

private struct CleanupTarget: Hashable {
    let url: URL
    let displayPath: String
}

private enum CleanerError: LocalizedError {
    case unsupportedPlatform
    case rootRequired
    case tailscaleRunning
    case unsafeObject(String)
    case cannotDetermineUser
    case authorizationFailed(OSStatus)
    case privilegedRunFailed(String)

    var errorDescription: String? {
        switch self {
        case .unsupportedPlatform:
            return "This compiled app supports macOS only."
        case .rootRequired:
            return "Cleanup requires administrator access. Use Authenticate and Clean or run the executable with sudo and --apply --yes."
        case .tailscaleRunning:
            return "Tailscale is still running. Quit and uninstall it before cleanup."
        case .unsafeObject(let path):
            return "Refusing to remove unsupported filesystem object: \(path)"
        case .cannotDetermineUser:
            return "Could not determine the logged-in macOS user and home directory."
        case .authorizationFailed(let status):
            return "Administrator authorization failed (OSStatus \(status))."
        case .privilegedRunFailed(let output):
            return output.isEmpty ? "The privileged cleanup did not complete." : output
        }
    }
}

private struct CleanerEngine {
    let userHome: URL
    let systemRoot: URL

    private let bundleIDs = ["io.tailscale.ipn.macos", "io.tailscale.ipn.macsys"]

    func targets() -> [CleanupTarget] {
        var result: [CleanupTarget] = []
        var seen: Set<String> = []

        func add(_ url: URL, _ displayPath: String) {
            let path = url.standardizedFileURL.path
            guard seen.insert(path).inserted else { return }
            result.append(CleanupTarget(url: url, displayPath: displayPath))
        }

        for bundleID in bundleIDs {
            add(userHome.appendingPathComponent("Library/Application Scripts/\(bundleID)"), "~/Library/Application Scripts/\(bundleID)")
            add(userHome.appendingPathComponent("Library/Application Scripts/\(bundleID).login-item-helper"), "~/Library/Application Scripts/\(bundleID).login-item-helper")
            add(userHome.appendingPathComponent("Library/Application Scripts/\(bundleID).share-extension"), "~/Library/Application Scripts/\(bundleID).share-extension")
            add(userHome.appendingPathComponent("Library/Caches/\(bundleID)"), "~/Library/Caches/\(bundleID)")
            add(userHome.appendingPathComponent("Library/Containers/\(bundleID)"), "~/Library/Containers/\(bundleID)")
            add(userHome.appendingPathComponent("Library/Containers/\(bundleID).login-item-helper"), "~/Library/Containers/\(bundleID).login-item-helper")
            add(userHome.appendingPathComponent("Library/Containers/\(bundleID).network-extension"), "~/Library/Containers/\(bundleID).network-extension")
            add(userHome.appendingPathComponent("Library/Containers/\(bundleID).share-extension"), "~/Library/Containers/\(bundleID).share-extension")
            add(userHome.appendingPathComponent("Library/HTTPStorages/\(bundleID)"), "~/Library/HTTPStorages/\(bundleID)")
            add(userHome.appendingPathComponent("Library/Preferences/\(bundleID).plist"), "~/Library/Preferences/\(bundleID).plist")

            addSuffixMatches(parent: userHome.appendingPathComponent("Library/Application Scripts"), suffix: ".\(bundleID)", displayParent: "~/Library/Application Scripts", add: add)
            addSuffixMatches(parent: userHome.appendingPathComponent("Library/Group Containers"), suffix: ".\(bundleID)", displayParent: "~/Library/Group Containers", add: add)
        }

        add(userHome.appendingPathComponent("Library/Containers/Tailscale"), "~/Library/Containers/Tailscale")
        add(userHome.appendingPathComponent("Library/Tailscale"), "~/Library/Tailscale")
        add(userHome.appendingPathComponent("Library/Application Support/Tailscale"), "~/Library/Application Support/Tailscale")
        add(systemRoot.appendingPathComponent("Library/Application Support/Tailscale"), "/Library/Application Support/Tailscale")
        add(systemRoot.appendingPathComponent("Library/Tailscale"), "/Library/Tailscale")
        return result
    }

    func preview() -> String {
        var lines = ["Mode: preview", ""]
        for target in targets() {
            if let kind = itemKind(at: target.url) {
                lines.append("FOUND  \(target.displayPath) (\(kind))")
            } else {
                lines.append("ABSENT \(target.displayPath)")
            }
        }
        lines.append("")
        lines.append("Preview only. No files were changed.")
        return lines.joined(separator: "\n")
    }

    func apply() throws -> String {
        guard geteuid() == 0 else { throw CleanerError.rootRequired }
        guard !isTailscaleRunning() else { throw CleanerError.tailscaleRunning }

        let allTargets = targets()
        var removed: [String] = []
        for target in allTargets {
            guard let kind = itemKind(at: target.url) else { continue }
            guard kind == "directory" || kind == "file" || kind == "symbolic link" else {
                throw CleanerError.unsafeObject(target.displayPath)
            }
            try FileManager.default.removeItem(at: target.url)
            removed.append(target.displayPath)
        }

        for target in allTargets where itemKind(at: target.url) != nil {
            throw CleanerError.privilegedRunFailed("Verification failed: \(target.displayPath) still exists.")
        }

        let summary = removed.isEmpty ? "No matching Tailscale support data was present." : "Removed and verified \(removed.count) Tailscale support-data item(s)."
        return "Cleanup complete. \(summary)\nReview the Tailscale VPN configuration and Tailscale Keychain entries manually."
    }

    private func addSuffixMatches(parent: URL, suffix: String, displayParent: String, add: (URL, String) -> Void) {
        guard let children = try? FileManager.default.contentsOfDirectory(at: parent, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else { return }
        for child in children where child.lastPathComponent.hasSuffix(suffix) {
            add(child, "\(displayParent)/\(child.lastPathComponent)")
        }
    }

    private func itemKind(at url: URL) -> String? {
        var info = stat()
        if lstat(url.path, &info) != 0 { return errno == ENOENT ? nil : "unreadable object" }
        switch info.st_mode & S_IFMT {
        case S_IFDIR: return "directory"
        case S_IFREG: return "file"
        case S_IFLNK: return "symbolic link"
        default: return "special filesystem object"
        }
    }

    private func isTailscaleRunning() -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        process.arguments = ["-f", "/Tailscale.app/"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            return false
        }
    }
}

private func consoleUserHome() throws -> URL {
    if geteuid() != 0 { return FileManager.default.homeDirectoryForCurrentUser }

    if let sudoUser = ProcessInfo.processInfo.environment["SUDO_USER"], sudoUser != "root",
       let home = NSHomeDirectoryForUser(sudoUser), home.hasPrefix("/Users/") {
        return URL(fileURLWithPath: home, isDirectory: true)
    }

    var consoleInfo = stat()
    guard stat("/dev/console", &consoleInfo) == 0,
          let passwordEntry = getpwuid(consoleInfo.st_uid),
          let homePointer = passwordEntry.pointee.pw_dir else {
        throw CleanerError.cannotDetermineUser
    }
    let home = String(cString: homePointer)
    guard home.hasPrefix("/Users/") else { throw CleanerError.cannotDetermineUser }
    return URL(fileURLWithPath: home, isDirectory: true)
}

private func liveEngine() throws -> CleanerEngine {
    guard ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 12 else { throw CleanerError.unsupportedPlatform }
    return CleanerEngine(userHome: try consoleUserHome(), systemRoot: URL(fileURLWithPath: "/", isDirectory: true))
}

private func authorizeAndRunCleanup() throws -> String {
    var authorization: AuthorizationRef?
    let createStatus = AuthorizationCreate(nil, nil, [.interactionAllowed, .extendRights, .preAuthorize], &authorization)
    guard createStatus == errAuthorizationSuccess, let authorization else { throw CleanerError.authorizationFailed(createStatus) }
    defer { AuthorizationFree(authorization, []) }

    let rightsStatus = kAuthorizationRightExecute.withCString { rightName in
        var right = AuthorizationItem(name: rightName, valueLength: 0, value: nil, flags: 0)
        return withUnsafeMutablePointer(to: &right) { rightPointer in
            var rights = AuthorizationRights(count: 1, items: rightPointer)
            return AuthorizationCopyRights(authorization, &rights, nil, [.interactionAllowed, .extendRights, .preAuthorize], nil)
        }
    }
    guard rightsStatus == errAuthorizationSuccess else { throw CleanerError.authorizationFailed(rightsStatus) }

    let executable = Bundle.main.executablePath ?? CommandLine.arguments[0]
    let argumentStrings = ["--apply", "--yes"]
    var argumentPointers = argumentStrings.map { strdup($0) }
    argumentPointers.append(nil)
    defer { argumentPointers.compactMap { $0 }.forEach { free($0) } }

    var communicationsPipe: UnsafeMutablePointer<FILE>?
    let executeStatus = executable.withCString { executablePointer in
        argumentPointers.withUnsafeMutableBufferPointer { buffer in
            let argumentsPointer = UnsafeRawPointer(buffer.baseAddress!).assumingMemoryBound(to: UnsafeMutablePointer<CChar>.self)
            return TCCAuthorizationExecuteWithPrivileges(authorization, executablePointer, argumentsPointer, &communicationsPipe)
        }
    }
    guard executeStatus == errAuthorizationSuccess, let communicationsPipe else { throw CleanerError.authorizationFailed(executeStatus) }

    var output = ""
    var bytes = [CChar](repeating: 0, count: 4096)
    while fgets(&bytes, Int32(bytes.count), communicationsPipe) != nil { output += String(cString: bytes) }
    fclose(communicationsPipe)

    let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
    guard trimmed.contains("Cleanup complete.") else { throw CleanerError.privilegedRunFailed(trimmed) }
    return trimmed
}

private final class AppDelegate: NSObject, NSApplicationDelegate {
    private var window: NSWindow!
    private var helpWindow: NSWindow?
    private var outputView: NSTextView!
    private var cleanButton: NSButton!

    private let outputFont = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)

    private func styledOutput(_ text: String) -> NSAttributedString {
        let result = NSMutableAttributedString(
            string: text,
            attributes: [
                .font: outputFont,
                .foregroundColor: NSColor.labelColor,
            ]
        )

        let fullText = text as NSString
        let fullRange = NSRange(location: 0, length: fullText.length)
        let statusStyles: [(String, NSColor)] = [
            ("FOUND", .systemRed),
            ("ABSENT", .systemGreen),
            ("ERROR:", .systemRed),
            ("Cleanup complete.", .systemGreen),
        ]

        for (token, color) in statusStyles {
            var searchRange = fullRange
            while searchRange.length > 0 {
                let match = fullText.range(of: token, options: [], range: searchRange)
                guard match.location != NSNotFound else { break }
                result.addAttributes(
                    [.foregroundColor: color, .font: NSFont.monospacedSystemFont(ofSize: 12, weight: .bold)],
                    range: match
                )
                let nextLocation = NSMaxRange(match)
                searchRange = NSRange(location: nextLocation, length: fullRange.length - nextLocation)
            }
        }

        return result
    }

    private func setOutput(_ text: String) {
        outputView.textStorage?.setAttributedString(styledOutput(text))
    }

    private func appendOutput(_ text: String) {
        outputView.textStorage?.append(styledOutput(text))
        outputView.scrollToEndOfDocument(nil)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildMainMenu()
        buildWindow()
        refreshPreview()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    private func buildMainMenu() {
        let mainMenu = NSMenu()

        let appMenuItem = NSMenuItem()
        mainMenu.addItem(appMenuItem)
        let appMenu = NSMenu(title: "Tailscale Cache Cleaner")
        appMenuItem.submenu = appMenu
        let aboutItem = NSMenuItem(title: "About Tailscale Cache Cleaner", action: #selector(showAbout), keyEquivalent: "")
        aboutItem.target = self
        appMenu.addItem(aboutItem)
        appMenu.addItem(.separator())

        let servicesItem = NSMenuItem(title: "Services", action: nil, keyEquivalent: "")
        let servicesMenu = NSMenu(title: "Services")
        servicesItem.submenu = servicesMenu
        NSApp.servicesMenu = servicesMenu
        appMenu.addItem(servicesItem)
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide Tailscale Cache Cleaner", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        let hideOthers = appMenu.addItem(withTitle: "Hide Others", action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        appMenu.addItem(withTitle: "Show All", action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit Tailscale Cache Cleaner", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

        let helpMenuItem = NSMenuItem()
        mainMenu.addItem(helpMenuItem)
        let helpMenu = NSMenu(title: "Help")
        helpMenuItem.submenu = helpMenu
        let helpItem = NSMenuItem(title: "Tailscale Cache Cleaner Help", action: #selector(showHelp), keyEquivalent: "?")
        helpItem.target = self
        helpMenu.addItem(helpItem)
        NSApp.helpMenu = helpMenu

        NSApp.mainMenu = mainMenu
    }

    @objc private func showAbout() {
        let credits = NSMutableAttributedString()
        let baseAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11),
            .foregroundColor: NSColor.labelColor,
        ]
        credits.append(NSAttributedString(string: "code.matx.ca\n", attributes: baseAttributes.merging([
            .link: URL(string: "https://code.matx.ca")!,
        ]) { _, new in new }))
        credits.append(NSAttributedString(string: "github.com/macvfx/rmTS", attributes: baseAttributes.merging([
            .link: URL(string: "https://github.com/macvfx/rmTS")!,
        ]) { _, new in new }))

        NSApp.orderFrontStandardAboutPanel(options: [
            .applicationName: "Tailscale Cache Cleaner",
            .applicationVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "",
            .version: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "",
            .credits: credits,
        ])
    }

    @objc private func showHelp() {
        if let helpWindow {
            helpWindow.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let help = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 560),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        help.title = "Tailscale Cache Cleaner Help"
        help.center()
        help.minSize = NSSize(width: 520, height: 400)

        let scrollView = NSScrollView(frame: help.contentView?.bounds ?? .zero)
        scrollView.autoresizingMask = [.width, .height]
        scrollView.hasVerticalScroller = true

        let textView = NSTextView(frame: scrollView.bounds)
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = true
        textView.linkTextAttributes = [
            .foregroundColor: NSColor.linkColor,
            .underlineStyle: NSUnderlineStyle.single.rawValue,
        ]
        textView.textContainerInset = NSSize(width: 24, height: 22)
        textView.textStorage?.setAttributedString(helpText())
        scrollView.documentView = textView
        help.contentView = scrollView

        helpWindow = help
        help.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func helpText() -> NSAttributedString {
        let bodyFont = NSFont.systemFont(ofSize: 13)
        let result = NSMutableAttributedString()

        func append(_ text: String, font: NSFont, color: NSColor = .labelColor, spacing: CGFloat = 8) {
            let paragraph = NSMutableParagraphStyle()
            paragraph.paragraphSpacing = spacing
            paragraph.lineSpacing = 2
            result.append(NSAttributedString(string: text, attributes: [
                .font: font,
                .foregroundColor: color,
                .paragraphStyle: paragraph,
            ]))
        }

        func appendLink(_ title: String, url: String) {
            let paragraph = NSMutableParagraphStyle()
            paragraph.paragraphSpacing = 6
            result.append(NSAttributedString(string: title + "\n", attributes: [
                .font: bodyFont,
                .foregroundColor: NSColor.linkColor,
                .link: URL(string: url)!,
                .paragraphStyle: paragraph,
            ]))
        }

        append("Tailscale Cache Cleaner\n", font: .systemFont(ofSize: 24, weight: .semibold), spacing: 12)
        append("Use this utility only when troubleshooting a duplicated Tailscale 100.x address or when you intentionally need to reset this Mac’s local Tailscale identity. It is not routine cache maintenance.\n", font: bodyFont)

        append("Before you clean\n", font: .systemFont(ofSize: 16, weight: .semibold), spacing: 5)
        append("1. Quit Tailscale.\n2. Uninstall Tailscale.\n3. Review the preview. Red FOUND entries are present and will be removed. Green ABSENT entries are already clear.\n", font: bodyFont)

        append("Cleaning\n", font: .systemFont(ofSize: 16, weight: .semibold), spacing: 5)
        append("Choose Authenticate and Clean, confirm the warning, and approve the macOS administrator prompt. The app removes only its fixed list of Tailscale support-data paths and verifies that each removed item is gone.\n", font: bodyFont)

        append("After cleaning\n", font: .systemFont(ofSize: 16, weight: .semibold), spacing: 5)
        append("Review any remaining Tailscale VPN configuration in System Settings and Tailscale entries in Keychain Access. Then reinstall Tailscale and authenticate again. The Mac should receive a new node identity and may receive a new Tailscale IP address.\n", font: bodyFont)

        append("Command-line use\n", font: .systemFont(ofSize: 16, weight: .semibold), spacing: 5)
        append("The same compiled executable supports --preview and sudo execution with --apply --yes. The app does not wrap or invoke the shell cleaner.\n", font: bodyFont)

        append("Safety boundary\n", font: .systemFont(ofSize: 16, weight: .semibold), spacing: 5)
        append("The cleaner refuses to run unless it has administrator access, refuses while Tailscale is running, does not follow symbolic links, and never searches broadly for files to delete.\n", font: bodyFont)

        append("More information\n", font: .systemFont(ofSize: 16, weight: .semibold), spacing: 5)
        appendLink("code.matx.ca", url: "https://code.matx.ca")
        appendLink("github.com/macvfx/rmTS", url: "https://github.com/macvfx/rmTS")
        appendLink(
            "Tailscale standalone macOS uninstall guide",
            url: "https://tailscale.com/docs/features/client/uninstall?tab=macos+%28standalone%29"
        )

        return result
    }

    private func buildWindow() {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 720, height: 560), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "Tailscale Cache Cleaner"
        window.center()
        window.minSize = NSSize(width: 600, height: 440)

        let content = NSView()
        content.translatesAutoresizingMaskIntoConstraints = false
        window.contentView = content

        let heading = NSTextField(labelWithString: "Tailscale local identity reset")
        heading.font = .systemFont(ofSize: 22, weight: .semibold)
        heading.translatesAutoresizingMaskIntoConstraints = false

        let warning = NSTextField(wrappingLabelWithString: "This is not routine cache maintenance. Quit and uninstall Tailscale first. Cleaning signs this Mac out and causes a new node identity and Tailscale IP after reinstalling and authenticating.")
        warning.textColor = .secondaryLabelColor
        warning.translatesAutoresizingMaskIntoConstraints = false

        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.borderType = .bezelBorder
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        outputView = NSTextView()
        outputView.isEditable = false
        outputView.isSelectable = true
        outputView.font = outputFont
        outputView.textContainerInset = NSSize(width: 8, height: 8)
        scrollView.documentView = outputView

        let refreshButton = NSButton(title: "Refresh Preview", target: self, action: #selector(refreshPreview))
        refreshButton.translatesAutoresizingMaskIntoConstraints = false
        cleanButton = NSButton(title: "Authenticate and Clean", target: self, action: #selector(clean))
        cleanButton.keyEquivalent = "\r"
        cleanButton.translatesAutoresizingMaskIntoConstraints = false
        let buttonRow = NSStackView(views: [refreshButton, cleanButton])
        buttonRow.orientation = .horizontal
        buttonRow.spacing = 12
        buttonRow.translatesAutoresizingMaskIntoConstraints = false

        [heading, warning, scrollView, buttonRow].forEach(content.addSubview)
        NSLayoutConstraint.activate([
            heading.topAnchor.constraint(equalTo: content.topAnchor, constant: 22),
            heading.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 24),
            heading.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -24),
            warning.topAnchor.constraint(equalTo: heading.bottomAnchor, constant: 10),
            warning.leadingAnchor.constraint(equalTo: heading.leadingAnchor),
            warning.trailingAnchor.constraint(equalTo: heading.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: warning.bottomAnchor, constant: 16),
            scrollView.leadingAnchor.constraint(equalTo: heading.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: heading.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: buttonRow.topAnchor, constant: -16),
            buttonRow.trailingAnchor.constraint(equalTo: heading.trailingAnchor),
            buttonRow.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -20),
        ])
    }

    @objc private func refreshPreview() {
        do { setOutput(try liveEngine().preview()) }
        catch { setOutput("ERROR: \(error.localizedDescription)") }
    }

    @objc private func clean() {
        let alert = NSAlert()
        alert.messageText = "Reset this Mac's Tailscale identity?"
        alert.informativeText = "This permanently removes the listed local Tailscale support data. VPN configuration and Keychain entries still require manual review."
        alert.alertStyle = .critical
        alert.addButton(withTitle: "Authenticate and Clean")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        cleanButton.isEnabled = false
        appendOutput("\n\nRequesting administrator authorization…")
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let result = try authorizeAndRunCleanup()
                DispatchQueue.main.async {
                    self.cleanButton.isEnabled = true
                    self.setOutput(result)
                    let complete = NSAlert()
                    complete.messageText = "Cleanup complete"
                    complete.informativeText = "Now remove any remaining Tailscale VPN configuration and Tailscale entries from Keychain Access, then reinstall and authenticate Tailscale."
                    complete.runModal()
                }
            } catch {
                DispatchQueue.main.async {
                    self.cleanButton.isEnabled = true
                    NSAlert(error: error).runModal()
                    self.refreshPreview()
                }
            }
        }
    }
}

private func runSelfTest() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("tailscale-cleaner-swift-test-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let home = root.appendingPathComponent("Users/tester")
    let fixtures = [
        home.appendingPathComponent("Library/Containers/io.tailscale.ipn.macos"),
        home.appendingPathComponent("Library/Application Support/Tailscale"),
        root.appendingPathComponent("Library/Tailscale"),
    ]
    for target in fixtures { try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true) }
    let unrelated = home.appendingPathComponent("Library/Application Support/UnrelatedApp")
    try FileManager.default.createDirectory(at: unrelated, withIntermediateDirectories: true)
    try Data("keep".utf8).write(to: unrelated.appendingPathComponent("data"))

    let engine = CleanerEngine(userHome: home, systemRoot: root)
    guard engine.preview().contains("FOUND  ~/Library/Containers/io.tailscale.ipn.macos") else {
        throw CleanerError.privilegedRunFailed("Self-test preview did not find the App Store container fixture.")
    }
    for target in engine.targets() where FileManager.default.fileExists(atPath: target.url.path) {
        try FileManager.default.removeItem(at: target.url)
    }
    guard fixtures.allSatisfy({ !FileManager.default.fileExists(atPath: $0.path) }),
          FileManager.default.fileExists(atPath: unrelated.appendingPathComponent("data").path) else {
        throw CleanerError.privilegedRunFailed("Self-test cleanup boundaries failed.")
    }
    print("PASS: compiled Swift preview and disposable cleanup boundaries verified.")
}

private func runCommandLine(arguments: [String]) -> Int32 {
    do {
        if arguments.contains("--self-test") { try runSelfTest(); return 0 }
        let engine = try liveEngine()
        if arguments.contains("--preview") { print(engine.preview()); return 0 }
        if arguments.contains("--apply") {
            guard arguments.contains("--yes") else { throw CleanerError.privilegedRunFailed("Refusing cleanup without --yes.") }
            print(try engine.apply())
            return 0
        }
        throw CleanerError.privilegedRunFailed("Unknown command-line arguments: \(arguments.joined(separator: " "))")
    } catch {
        print("ERROR: \(error.localizedDescription)")
        return 1
    }
}

let arguments = Array(CommandLine.arguments.dropFirst())
if !arguments.isEmpty { exit(runCommandLine(arguments: arguments)) }

let application = NSApplication.shared
private let delegate = AppDelegate()
application.delegate = delegate
application.setActivationPolicy(.regular)
application.run()
