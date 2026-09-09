import Cocoa
import SwiftUI
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

final class ConversionState: ObservableObject {
    @Published var phase = "idle"
    @Published var dragging = false
    @Published var filename = "PDF · EPS · AI · PS"
    @Published var completed = 0
    @Published var total = 0
    @Published var errors: [String] = []
}

final class DropHostingView: NSHostingView<ConversionView> {
    var hover: (Bool) -> Void = { _ in }
    var accept: ([URL]) -> Void = { _ in }

    private func files(_ sender: NSDraggingInfo) -> [URL] {
        (sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
    }
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        let valid = !files(sender).isEmpty
        hover(valid)
        return valid ? .copy : []
    }
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        draggingEntered(sender)
    }
    override func draggingExited(_ sender: NSDraggingInfo?) { hover(false) }
    override func draggingEnded(_ sender: NSDraggingInfo) { hover(false) }
    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool { !files(sender).isEmpty }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let urls = files(sender)
        hover(false)
        guard !urls.isEmpty else { return false }
        accept(urls)
        return true
    }
}

struct ConversionView: View {
    @ObservedObject var state: ConversionState
    @Environment(\.accessibilityReduceMotion) var reduceMotion
    var choose: () -> Void
    @State private var spinning = false
    private var busy: Bool { state.phase == "working" }
    private var success: Bool { state.phase == "success" }

    var body: some View {
        ZStack {
            LinearGradient(colors: [Color(white: 0.12), Color(white: 0.055), Color(white: 0.025)], startPoint: .topLeading, endPoint: .bottomTrailing)
            Circle().fill(Color.white.opacity(0.12)).frame(width: 280, height: 280).blur(radius: 75).offset(x: -120, y: -150)
            Circle().fill(Color.white.opacity(0.045)).frame(width: 240, height: 240).blur(radius: 65).offset(x: 155, y: 105)
            VStack(spacing: 0) {
                Text("TO SVG").font(.system(size: 10, weight: .semibold, design: .rounded)).tracking(3).foregroundStyle(.white.opacity(0.45))
                    .padding(.top, 35)
                Spacer(minLength: 20)
                ZStack {
                    Circle().fill(.white.opacity(0.035)).frame(width: 86, height: 86)
                    Circle().stroke(.white.opacity(0.08), lineWidth: 1).frame(width: 86, height: 86)
                    if busy {
                        Circle().trim(from: 0, to: 0.72)
                            .stroke(AngularGradient(colors: [.clear, .white.opacity(0.35), .white], center: .center), style: StrokeStyle(lineWidth: 2, lineCap: .round))
                            .frame(width: 86, height: 86)
                            .rotationEffect(.degrees(spinning && !reduceMotion ? 360 : 0))
                            .onAppear { spinning = false; withAnimation(.linear(duration: 1.5).repeatForever(autoreverses: false)) { spinning = true } }
                            .onDisappear { spinning = false }
                    }
                    Image(systemName: success ? "checkmark" : state.phase == "error" ? "exclamationmark" : "point.topleft.down.to.point.bottomright.curvepath")
                        .font(.system(size: 30, weight: .light))
                        .foregroundStyle(.white.opacity(success ? 1 : 0.9))
                }
                .accessibilityLabel(busy ? "Conversion in progress" : success ? "Conversion complete" : "To SVG")
                Text(busy ? "Making vectors" : success ? "All done" : state.phase == "error" ? "Needs a little attention" : "A simpler kind of conversion")
                    .font(.system(size: 23, weight: .medium)).tracking(-0.6).padding(.top, 24)
                Text(success ? "Saved beside your originals" : state.filename)
                    .font(.system(size: 12)).foregroundStyle(.white.opacity(0.5))
                    .lineLimit(1).truncationMode(.middle).padding(.top, 9).padding(.horizontal, 32)
                Spacer(minLength: 22)
                if busy {
                    VStack(spacing: 10) {
                        ProgressView(value: Double(state.completed), total: Double(max(state.total, 1)))
                            .tint(.white.opacity(0.8)).frame(width: 180)
                        Text("\(state.completed) of \(state.total) files")
                            .font(.system(size: 10, design: .monospaced)).foregroundStyle(.white.opacity(0.4))
                    }.padding(.bottom, 28)
                } else if success {
                    Text("You're good to go").font(.system(size: 11)).foregroundStyle(.white.opacity(0.35)).padding(.bottom, 32)
                } else if state.phase == "error" {
                    ScrollView {
                        Text(state.errors.joined(separator: "\n\n")).font(.system(size: 11)).foregroundStyle(.white.opacity(0.75)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                    }.frame(height: 90).padding(.horizontal, 28).padding(.bottom, 22)
                } else {
                    Button(action: choose) {
                        Text("Choose files").font(.system(size: 12, weight: .medium)).padding(.horizontal, 23).padding(.vertical, 10)
                            .background(.white.opacity(0.10), in: Capsule()).overlay(Capsule().stroke(.white.opacity(0.12), lineWidth: 1))
                    }.buttonStyle(.plain).padding(.bottom, 28)
                }
            }
            .opacity(state.dragging ? 0 : 1)
            if state.dragging {
                RoundedRectangle(cornerRadius: 18)
                    .fill(.white.opacity(0.035))
                    .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(.white.opacity(0.3), style: StrokeStyle(lineWidth: 1, dash: [6, 5])))
                    .padding(18).padding(.top, 14)
                VStack(spacing: 16) {
                    Image(systemName: "arrow.down.doc")
                        .font(.system(size: 40, weight: .ultraLight))
                    Text("Drop to convert")
                        .font(.system(size: 23, weight: .medium)).tracking(-0.6)
                    Text("PDF · EPS · AI · PS")
                        .font(.system(size: 12)).foregroundStyle(.white.opacity(0.5))
                    Text(busy ? "Add files to the queue" : "SVGs saved beside your originals")
                        .font(.system(size: 11)).foregroundStyle(.white.opacity(0.35))
                }
                .allowsHitTesting(false)
            }
        }
        .foregroundStyle(.white)
        .preferredColorScheme(.dark)
        // Fill the hosting view, including the transparent title-bar region.
        // A fixed height here leaves a gap when AppKit adds that region.
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .ignoresSafeArea()
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.3), value: state.phase)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.18), value: state.dragging)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    var window: NSWindow!
    let state = ConversionState()
    var pending = 0
    var generation = 0
    var started = Date()
    let queue = DispatchQueue(label: "ToSVG.conversion")

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Set the running app's Dock icon even if Launch Services cached an older build.
        if let iconURL = Bundle.main.url(forResource: "AppIcon", withExtension: "icns"),
           let icon = NSImage(contentsOf: iconURL) {
            NSApp.applicationIconImage = icon
        }
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
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 440, height: 350), styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
        window.title = "To SVG"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.titlebarSeparatorStyle = .none
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        let hostingView = DropHostingView(rootView: ConversionView(state: state, choose: { [weak self] in self?.pickFiles() }))
        hostingView.sizingOptions = []
        hostingView.registerForDraggedTypes([.fileURL])
        hostingView.hover = { [weak self] active in self?.state.dragging = active }
        hostingView.accept = { [weak self] urls in self?.enqueue(urls) }
        window.contentView = hostingView
        window.center()
    }
    func pickFiles() {
        let panel = NSOpenPanel(); panel.allowsMultipleSelection = true; panel.canChooseDirectories = false
        panel.allowedContentTypes = ["pdf", "eps", "ai", "ps"].compactMap { UTType(filenameExtension: $0) }
        if panel.runModal() == .OK { enqueue(panel.urls) }
    }
    func application(_ sender: NSApplication, openFiles filenames: [String]) {
        enqueue(filenames.map { URL(fileURLWithPath: $0) })
        sender.reply(toOpenOrPrint: .success)
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        makeWindow(); window.makeKeyAndOrderFront(nil); return true
    }
    func enqueue(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        makeWindow(); window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
        generation += 1
        if pending == 0 {
            state.completed = 0; state.total = 0; state.errors = []; started = Date()
        }
        pending += urls.count; state.total += urls.count; state.phase = "working"
        for url in urls {
            queue.async {
                DispatchQueue.main.async { self.state.filename = url.lastPathComponent }
                let result = Result { try Converter().convert(url) }
                DispatchQueue.main.async {
                    if case .failure(let error) = result {
                        self.state.errors.append("\(url.lastPathComponent): \(error.localizedDescription)")
                    }
                    self.pending -= 1; self.state.completed += 1
                    if self.pending == 0 { self.finish() }
                }
            }
        }
    }
    func finish() {
        let token = generation
        // Let quick conversions settle visually before the completion checkmark.
        DispatchQueue.main.asyncAfter(deadline: .now() + max(0, 0.8 - Date().timeIntervalSince(started))) {
            guard self.generation == token, self.pending == 0 else { return }
            self.state.phase = self.state.errors.isEmpty ? "success" : "error"
            guard self.state.errors.isEmpty else { self.state.filename = "Some files could not be converted"; return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.85) {
                guard self.generation == token, self.pending == 0 else { return }
                self.closeWhenDragEnds(token: token)
            }
        }
    }
    func closeWhenDragEnds(token: Int) {
        guard generation == token, pending == 0 else { return }
        if state.dragging {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                self.closeWhenDragEnds(token: token)
            }
        } else {
            window.close()
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
