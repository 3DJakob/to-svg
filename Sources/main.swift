import Cocoa
import CoreGraphics
import UniformTypeIdentifiers

struct ConversionError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

struct Converter {
    let fm = FileManager.default
    func executable(_ name: String) throws -> URL {
        for root in ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin"] {
            let url = URL(fileURLWithPath: root).appendingPathComponent(name)
            if fm.isExecutableFile(atPath: url.path) { return url }
        }
        throw ConversionError(message: "Missing \(name). Install the conversion engines in Terminal with: brew install poppler ghostscript")
    }
    func run(_ name: String, _ args: [String], in directory: URL) throws {
        let process = Process()
        process.executableURL = try executable(name)
        process.arguments = args
        let log = directory.appendingPathComponent(UUID().uuidString + ".log")
        fm.createFile(atPath: log.path, contents: nil)
        let handle = try FileHandle(forWritingTo: log)
        defer { try? handle.close() }
        process.standardOutput = handle
        process.standardError = handle
        try process.run()
        let deadline = Date().addingTimeInterval(180)
        while process.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.05) }
        if process.isRunning {
            process.terminate()
            Thread.sleep(forTimeInterval: 0.2)
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            process.waitUntilExit()
            throw ConversionError(message: "Conversion timed out after 3 minutes.")
        }
        process.waitUntilExit()
        if process.terminationStatus != 0 {
            let detail = (try? String(contentsOf: log, encoding: .utf8)) ?? ""
            throw ConversionError(message: "\(name) could not convert this file. \(detail.suffix(1600))")
        }
    }
    func convert(_ input: URL) throws -> [URL] {
        guard ["pdf", "eps", "ai", "ps"].contains(input.pathExtension.lowercased()) else {
            throw ConversionError(message: "Choose a PDF, EPS, AI, or PS file.")
        }
        let temporary = fm.temporaryDirectory.appendingPathComponent("ToSVG-" + UUID().uuidString)
        try fm.createDirectory(at: temporary, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: temporary) }
        let reader = try FileHandle(forReadingFrom: input)
        let prefix = try reader.read(upToCount: 1024) ?? Data()
        try reader.close()
        var pdf = input
        if prefix.range(of: Data("%PDF-".utf8)) == nil {
            guard prefix.range(of: Data("%!PS".utf8)) != nil || input.pathExtension.lowercased() == "eps" else {
                throw ConversionError(message: "This Illustrator file has no PDF-compatible content. In Illustrator, save it with ‘Create PDF Compatible File’ enabled, or export a PDF.")
            }
            pdf = temporary.appendingPathComponent("intermediate.pdf")
            try run("gs", ["-dSAFER", "-dBATCH", "-dNOPAUSE", "-dEPSCrop", "-sDEVICE=pdfwrite", "-sOutputFile=" + pdf.path, "-f", input.path], in: temporary)
        }
        guard let document = CGPDFDocument(pdf as CFURL), document.isUnlocked, document.numberOfPages > 0 else {
            throw ConversionError(message: "The PDF is unreadable or password protected.")
        }
        var staged: [(URL, String)] = []
        for page in 1...document.numberOfPages {
            let svg = temporary.appendingPathComponent("page-\(page).svg")
            try run("pdftocairo", ["-svg", "-f", String(page), "-l", String(page), pdf.path, svg.path], in: temporary)
            let data = try Data(contentsOf: svg)
            guard data.range(of: Data("<svg".utf8)) != nil else { throw ConversionError(message: "The converter did not produce a valid SVG.") }
            let base = input.deletingPathExtension().lastPathComponent + (document.numberOfPages > 1 ? "-page-\(page)" : "")
            staged.append((svg, base))
        }
        var outputs: [URL] = []
        do {
            for (svg, base) in staged {
                var number = 1
                while true {
                    let suffix = number == 1 ? "" : " (\(number))"
                    let target = input.deletingLastPathComponent().appendingPathComponent(base + suffix + ".svg")
                    do {
                        // copyItem refuses an existing destination, including a race with another process.
                        try fm.copyItem(at: svg, to: target)
                        outputs.append(target)
                        break
                    } catch let error as NSError {
                        if error.domain == NSCocoaErrorDomain && error.code == NSFileWriteFileExistsError { number += 1; continue }
                        throw error
                    }
                }
            }
        } catch {
            for output in outputs { try? fm.removeItem(at: output) }
            throw error
        }
        return outputs
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    var window: NSWindow!
    var status: NSTextField!
    var details: NSTextView!
    var choose: NSButton!
    var reveal: NSButton!
    var pending = 0
    var outputs: [URL] = []
    let queue = DispatchQueue(label: "ToSVG.conversion")

    func applicationDidFinishLaunching(_ notification: Notification) {
        makeWindow()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
    func makeWindow() {
        guard window == nil else { return }
        let menu = NSMenu()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Quit To SVG", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        let item = NSMenuItem(); item.submenu = appMenu; menu.addItem(item); NSApp.mainMenu = menu
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 360), styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        window.title = "To SVG"; window.center(); window.isReleasedWhenClosed = false
        let title = NSTextField(labelWithString: "Files in. SVGs out.")
        title.font = .systemFont(ofSize: 28, weight: .semibold)
        let subtitle = NSTextField(wrappingLabelWithString: "Right-click files in Finder → Open With → To SVG.\nSVGs are saved beside the originals. Existing files are kept.")
        status = NSTextField(labelWithString: "Ready for PDF, EPS, AI, and PS files")
        status.font = .systemFont(ofSize: 13, weight: .medium)
        choose = NSButton(title: "Choose Files…", target: self, action: #selector(pickFiles))
        choose.bezelStyle = .rounded
        reveal = NSButton(title: "Show SVGs in Finder", target: self, action: #selector(showFiles))
        reveal.bezelStyle = .rounded; reveal.isEnabled = false
        let buttons = NSStackView(views: [choose, reveal]); buttons.spacing = 10
        let scroll = NSScrollView(); scroll.hasVerticalScroller = true
        details = NSTextView(); details.isEditable = false; details.isSelectable = true
        details.font = .systemFont(ofSize: 12); details.autoresizingMask = [.width]
        scroll.documentView = details
        let stack = NSStackView(views: [title, subtitle, status, scroll, buttons])
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 18
        stack.translatesAutoresizingMaskIntoConstraints = false
        window.contentView!.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: window.contentView!.leadingAnchor, constant: 26),
            stack.trailingAnchor.constraint(equalTo: window.contentView!.trailingAnchor, constant: -26),
            stack.topAnchor.constraint(equalTo: window.contentView!.topAnchor, constant: 26),
            stack.bottomAnchor.constraint(equalTo: window.contentView!.bottomAnchor, constant: -26),
            scroll.widthAnchor.constraint(equalTo: stack.widthAnchor), scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 100)
        ])
    }
    @objc func pickFiles() {
        let panel = NSOpenPanel(); panel.allowsMultipleSelection = true; panel.canChooseDirectories = false
        panel.allowedContentTypes = ["pdf", "eps", "ai", "ps"].compactMap { UTType(filenameExtension: $0) }
        if panel.runModal() == .OK { enqueue(panel.urls) }
    }
    @objc func showFiles() { NSWorkspace.shared.activateFileViewerSelecting(outputs) }
    func application(_ sender: NSApplication, openFiles filenames: [String]) {
        enqueue(filenames.map { URL(fileURLWithPath: $0) })
        sender.reply(toOpenOrPrint: .success)
    }
    func enqueue(_ urls: [URL]) {
        makeWindow(); window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
        pending += urls.count; status.stringValue = "Converting \(pending) file(s)…"
        for url in urls {
            queue.async {
                let result = Result { try Converter().convert(url) }
                DispatchQueue.main.async {
                    switch result {
                    case .success(let files):
                        self.outputs += files
                        self.details.string += "✓ \(url.lastPathComponent) → \(files.map(\.lastPathComponent).joined(separator: ", "))\n"
                    case .failure(let error):
                        self.details.string += "✗ \(url.lastPathComponent): \(error.localizedDescription)\n"
                    }
                    self.pending -= 1
                    self.status.stringValue = self.pending == 0 ? "Finished. \(self.outputs.count) SVG(s) created." : "Converting \(self.pending) file(s)…"
                    self.reveal.isEnabled = !self.outputs.isEmpty
                }
            }
        }
    }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if pending == 0 { return .terminateNow }
        let alert = NSAlert(); alert.messageText = "Conversion is still running"
        alert.informativeText = "Wait for the current files to finish before quitting."
        alert.runModal(); return .terminateCancel
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { pending == 0 }
}

if CommandLine.arguments.dropFirst().first == "--convert" {
    var failed = false
    for path in CommandLine.arguments.dropFirst(2) {
        do { for result in try Converter().convert(URL(fileURLWithPath: path)) { print(result.path) } }
        catch { fputs("\(path): \(error.localizedDescription)\n", stderr); failed = true }
    }
    exit(failed ? 1 : 0)
}
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
