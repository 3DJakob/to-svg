import Cocoa
import SwiftUI
import CoreGraphics
import UniformTypeIdentifiers

struct ConversionError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

private enum SVGStrokeFlattener {
    static func flatten(_ data: Data) throws -> Data {
        guard var svg = String(data: data, encoding: .utf8) else { return data }
        let pattern = #"<(path|circle|ellipse|rect|line|polyline|polygon)\b[^>]*?(?:/>|>)"#
        let regex = try NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
        let matches = regex.matches(in: svg, range: NSRange(svg.startIndex..., in: svg)).reversed()
        for match in matches {
            guard let range = Range(match.range, in: svg) else { continue }
            let tag = String(svg[range])
            let inherited = inheritedAttributes(before: match.range.location, in: svg)
            let style = styleAttributes(in: tag)
            let stroke = attribute("stroke", in: tag) ?? style["stroke"] ?? inherited["stroke"]
            guard let stroke, stroke.lowercased() != "none" else { continue }
            let width = CGFloat(Double(attribute("stroke-width", in: tag) ?? style["stroke-width"] ?? inherited["stroke-width"] ?? "1") ?? 1)
            let cap = CGLineCap(rawValue: capValue(attribute("stroke-linecap", in: tag) ?? style["stroke-linecap"] ?? inherited["stroke-linecap"])) ?? .butt
            let join = CGLineJoin(rawValue: joinValue(attribute("stroke-linejoin", in: tag) ?? style["stroke-linejoin"] ?? inherited["stroke-linejoin"])) ?? .miter
            let miter = CGFloat(Double(attribute("stroke-miterlimit", in: tag) ?? style["stroke-miterlimit"] ?? inherited["stroke-miterlimit"] ?? "4") ?? 4)
            let element = tag.dropFirst().split(separator: " ", maxSplits: 1).first.map(String.init) ?? "path"
            guard let path = shapePath(element, tag: tag) else { continue }
            let outline = path.copy(strokingWithWidth: width, lineCap: cap, lineJoin: join, miterLimit: miter)
            let outlineD = serialize(outline)
            let cleaned = removeStrokeAttributes(from: tag)
            let outlineBase = removeFillAttributes(from: cleaned)
            let outlineAttributes = outlineBase.replacingOccurrences(of: "\\s+d\\s*=\\s*[\\\"'][^\\\"']*[\\\"']", with: "", options: .regularExpression)
                .replacingOccurrences(of: "\\s*/?>$", with: " fill=\"\(escape(stroke))\" d=\"\(escape(outlineD))\"/>", options: .regularExpression)
            let fillTag = outlineAttributes
            let originalFill = attribute("fill", in: cleaned) ?? style["fill"] ?? inherited["fill"]
            let replacement = originalFill == nil || originalFill == "none" ? fillTag : cleaned + "\n" + fillTag
            svg.replaceSubrange(range, with: replacement)
        }
        let groupRegex = try NSRegularExpression(pattern: #"<(svg|g)\b[^>]*>"#, options: [.caseInsensitive])
        for match in groupRegex.matches(in: svg, range: NSRange(svg.startIndex..., in: svg)).reversed() {
            guard let range = Range(match.range, in: svg) else { continue }
            svg.replaceSubrange(range, with: removeStrokeAttributes(from: String(svg[range])))
        }
        return Data(svg.utf8)
    }

    private static func inheritedAttributes(before location: Int, in svg: String) -> [String: String] {
        let prefix = String(svg.prefix(location))
        let regex = try? NSRegularExpression(pattern: #"</?([A-Za-z][\w:.-]*)([^>]*)>"#)
        var stack: [[String: String]] = []
        for match in regex?.matches(in: prefix, range: NSRange(prefix.startIndex..., in: prefix)) ?? [] {
            guard let range = Range(match.range, in: prefix) else { continue }
            let token = String(prefix[range])
            if token.hasPrefix("</") { if !stack.isEmpty { stack.removeLast() }; continue }
            if token.hasPrefix("<?") || token.hasPrefix("<!") || token.hasSuffix("/>") { continue }
            let name = Range(match.range(at: 1), in: prefix).map { String(prefix[$0]).lowercased() } ?? ""
            guard name == "svg" || name == "g" else { continue }
            var values = stack.last ?? [:]
            values.merge(styleAttributes(in: token)) { _, new in new }
            for key in ["stroke", "stroke-width", "stroke-linecap", "stroke-linejoin", "stroke-miterlimit", "fill"] {
                if let value = attribute(key, in: token) { values[key] = value }
            }
            stack.append(values)
        }
        return stack.last ?? [:]
    }

    private static func shapePath(_ element: String, tag: String) -> CGMutablePath? {
        if element == "path" { return attribute("d", in: tag).flatMap(path(from:)) }
        let result = CGMutablePath()
        switch element {
        case "circle":
            guard let cx = numberAttribute("cx", in: tag), let cy = numberAttribute("cy", in: tag), let r = numberAttribute("r", in: tag) else { return nil }
            let box = CGRect(x: cx - r, y: cy - r, width: r * 2, height: r * 2); result.addEllipse(in: box)
        case "ellipse":
            guard let cx = numberAttribute("cx", in: tag), let cy = numberAttribute("cy", in: tag), let rx = numberAttribute("rx", in: tag), let ry = numberAttribute("ry", in: tag) else { return nil }
            result.addEllipse(in: CGRect(x: cx - rx, y: cy - ry, width: rx * 2, height: ry * 2))
        case "line":
            guard let x1 = numberAttribute("x1", in: tag), let y1 = numberAttribute("y1", in: tag), let x2 = numberAttribute("x2", in: tag), let y2 = numberAttribute("y2", in: tag) else { return nil }
            result.move(to: CGPoint(x: x1, y: y1)); result.addLine(to: CGPoint(x: x2, y: y2))
        default: return nil
        }
        return result
    }

    private static func numberAttribute(_ name: String, in tag: String) -> CGFloat? {
        guard let value = attribute(name, in: tag) else { return nil }
        return Double(value).map { CGFloat($0) }
    }

    private static func attribute(_ name: String, in tag: String) -> String? {
        let escaped = NSRegularExpression.escapedPattern(for: name)
        guard let regex = try? NSRegularExpression(pattern: "\\b(\(escaped))\\s*=\\s*[\\\"']([^\\\"']*)[\\\"']"),
              let match = regex.firstMatch(in: tag, range: NSRange(tag.startIndex..., in: tag)),
              let value = Range(match.range(at: 2), in: tag) else { return nil }
        return String(tag[value])
    }

    private static func styleAttributes(in tag: String) -> [String: String] {
        guard let style = attribute("style", in: tag) else { return [:] }
        return style.split(separator: ";").reduce(into: [:]) { result, part in
            let pair = part.split(separator: ":", maxSplits: 1).map(String.init)
            if pair.count == 2 { result[pair[0].trimmingCharacters(in: .whitespaces)] = pair[1].trimmingCharacters(in: .whitespaces) }
        }
    }

    private static func removeStrokeAttributes(from tag: String) -> String {
        var result = tag
        for name in ["stroke", "stroke-width", "stroke-linecap", "stroke-linejoin", "stroke-miterlimit", "stroke-opacity", "stroke-dasharray", "stroke-dashoffset"] {
            let escaped = NSRegularExpression.escapedPattern(for: name)
            result = result.replacingOccurrences(of: "\\s+(\(escaped))\\s*=\\s*[\\\"'][^\\\"']*[\\\"']", with: "", options: .regularExpression)
        }
        if let style = attribute("style", in: result) {
            let filtered = style.split(separator: ";").filter { !$0.trimmingCharacters(in: .whitespaces).lowercased().hasPrefix("stroke") }.joined(separator: ";")
            result = result.replacingOccurrences(of: style, with: filtered)
        }
        return result
    }

    private static func removeFillAttributes(from tag: String) -> String {
        var result = tag.replacingOccurrences(of: "\\s+fill\\s*=\\s*[\\\"'][^\\\"']*[\\\"']", with: "", options: .regularExpression)
        if let style = attribute("style", in: result) {
            let filtered = style.split(separator: ";").filter { !$0.trimmingCharacters(in: .whitespaces).lowercased().hasPrefix("fill") }.joined(separator: ";")
            result = result.replacingOccurrences(of: style, with: filtered)
        }
        return result
    }

    private static func capValue(_ value: String?) -> Int32 {
        switch value?.lowercased() { case "round": return 1; case "square": return 2; default: return 0 }
    }
    private static func joinValue(_ value: String?) -> Int32 {
        switch value?.lowercased() { case "round": return 1; case "bevel": return 2; default: return 0 }
    }
    private static func escape(_ value: String) -> String { value.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "\"", with: "&quot;") }

    private static func path(from d: String) -> CGMutablePath? {
        let tokenRegex = try? NSRegularExpression(pattern: #"[A-Za-z]|[-+]?(?:\d*\.\d+|\d+\.?)(?:[eE][-+]?\d+)?"#)
        let tokens = tokenRegex?.matches(in: d, range: NSRange(d.startIndex..., in: d)).compactMap { match -> String? in
            guard let range = Range(match.range, in: d) else { return nil }
            return String(d[range])
        } ?? []
        var path = CGMutablePath(), i = 0, command = "", current = CGPoint.zero, start = CGPoint.zero
        func number() -> CGFloat? { guard i < tokens.count, let value = Double(tokens[i]) else { return nil }; i += 1; return CGFloat(value) }
        while i < tokens.count {
            if tokens[i].count == 1, tokens[i].first!.isLetter { command = tokens[i]; i += 1 }
            guard !command.isEmpty else { return nil }
            let relative = command == command.lowercased(), upper = command.uppercased()
            func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint { relative ? CGPoint(x: current.x + x, y: current.y + y) : CGPoint(x: x, y: y) }
            switch upper {
            case "M", "L":
                guard let x = number(), let y = number() else { return path.isEmpty ? nil : path }
                let p = point(x, y); if upper == "M" { path.move(to: p); start = p; command = relative ? "l" : "L" } else { path.addLine(to: p) }; current = p
            case "C":
                guard let x1 = number(), let y1 = number(), let x2 = number(), let y2 = number(), let x = number(), let y = number() else { return nil }
                let p1 = point(x1, y1), p2 = relative ? CGPoint(x: current.x + x2, y: current.y + y2) : CGPoint(x: x2, y: y2), p = point(x, y); path.addCurve(to: p, control1: p1, control2: p2); current = p
            case "A":
                guard let rx = number(), let ry = number(), let rotation = number(), let largeArc = number(), let sweep = number(), let x = number(), let y = number() else { return nil }
                let p = point(x, y)
                appendArc(to: path, from: current, end: p, radiusX: rx, radiusY: ry, rotation: rotation, largeArc: largeArc != 0, sweep: sweep != 0)
                current = p
            case "H": guard let x = number() else { return nil }; let p = relative ? CGPoint(x: current.x + x, y: current.y) : CGPoint(x: x, y: current.y); path.addLine(to: p); current = p
            case "V": guard let y = number() else { return nil }; let p = relative ? CGPoint(x: current.x, y: current.y + y) : CGPoint(x: current.x, y: y); path.addLine(to: p); current = p
            case "Z": path.closeSubpath(); current = start; command = ""
            default: return nil
            }
        }
        return path
    }

    private static func appendArc(to path: CGMutablePath, from start: CGPoint, end: CGPoint, radiusX: CGFloat, radiusY: CGFloat, rotation: CGFloat, largeArc: Bool, sweep: Bool) {
        var rx = abs(radiusX), ry = abs(radiusY)
        if rx == 0 || ry == 0 { path.addLine(to: end); return }
        if abs(start.x - end.x) < 0.000001 && abs(start.y - end.y) < 0.000001 { return }
        let phi = rotation * .pi / 180
        let cosPhi = cos(phi), sinPhi = sin(phi)
        let dx = (start.x - end.x) / 2, dy = (start.y - end.y) / 2
        let xPrime = cosPhi * dx + sinPhi * dy
        let yPrime = -sinPhi * dx + cosPhi * dy
        let radiusScale = (xPrime * xPrime) / (rx * rx) + (yPrime * yPrime) / (ry * ry)
        if radiusScale > 1 { let scale = sqrt(radiusScale); rx *= scale; ry *= scale }
        let denominator = rx * rx * yPrime * yPrime + ry * ry * xPrime * xPrime
        let numerator = max(0, (rx * rx * ry * ry - rx * rx * yPrime * yPrime - ry * ry * xPrime * xPrime) / max(denominator, 0.0000001))
        let sign: CGFloat = largeArc == sweep ? -1 : 1
        let coefficient = sign * sqrt(numerator)
        let centerXPrime = coefficient * (rx * yPrime / ry)
        let centerYPrime = coefficient * (-ry * xPrime / rx)
        let center = CGPoint(x: cosPhi * centerXPrime - sinPhi * centerYPrime + (start.x + end.x) / 2,
                             y: sinPhi * centerXPrime + cosPhi * centerYPrime + (start.y + end.y) / 2)
        func vectorAngle(_ ux: CGFloat, _ uy: CGFloat, _ vx: CGFloat, _ vy: CGFloat) -> CGFloat {
            let dot = ux * vx + uy * vy
            let length = sqrt((ux * ux + uy * uy) * (vx * vx + vy * vy))
            let angle = acos(max(-1, min(1, dot / max(length, 0.0000001))))
            return ux * vy - uy * vx < 0 ? -angle : angle
        }
        let ux = (xPrime - centerXPrime) / rx, uy = (yPrime - centerYPrime) / ry
        let vx = (-xPrime - centerXPrime) / rx, vy = (-yPrime - centerYPrime) / ry
        var startAngle = vectorAngle(1, 0, ux, uy)
        var delta = vectorAngle(ux, uy, vx, vy)
        if !sweep && delta > 0 { delta -= 2 * .pi }
        if sweep && delta < 0 { delta += 2 * .pi }
        let segments = max(1, Int(ceil(abs(delta) / (.pi / 2))))
        let step = delta / CGFloat(segments)
        func pointAt(_ angle: CGFloat) -> CGPoint {
            CGPoint(x: center.x + rx * cosPhi * cos(angle) - ry * sinPhi * sin(angle),
                    y: center.y + rx * sinPhi * cos(angle) + ry * cosPhi * sin(angle))
        }
        func derivativeAt(_ angle: CGFloat) -> CGPoint {
            CGPoint(x: -rx * cosPhi * sin(angle) - ry * sinPhi * cos(angle),
                    y: -rx * sinPhi * sin(angle) + ry * cosPhi * cos(angle))
        }
        for _ in 0..<segments {
            let endAngle = startAngle + step
            let alpha = 4 / 3 * tan(step / 4)
            let p1 = pointAt(startAngle), p2 = pointAt(endAngle)
            let d1 = derivativeAt(startAngle), d2 = derivativeAt(endAngle)
            path.addCurve(to: p2, control1: CGPoint(x: p1.x + alpha * d1.x, y: p1.y + alpha * d1.y), control2: CGPoint(x: p2.x - alpha * d2.x, y: p2.y - alpha * d2.y))
            startAngle = endAngle
        }
    }

    private static func serialize(_ path: CGPath) -> String {
        var result = ""
        path.applyWithBlock { element in
            let p = element.pointee.points
            switch element.pointee.type { case .moveToPoint: result += "M \(p[0].x) \(p[0].y) "; case .addLineToPoint: result += "L \(p[0].x) \(p[0].y) "; case .addCurveToPoint: result += "C \(p[0].x) \(p[0].y) \(p[1].x) \(p[1].y) \(p[2].x) \(p[2].y) "; case .addQuadCurveToPoint: result += "Q \(p[0].x) \(p[0].y) \(p[1].x) \(p[1].y) "; case .closeSubpath: result += "Z "; @unknown default: break }
        }
        return result
    }
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
    func convert(_ input: URL, flattenStrokes: Bool = false) throws -> [URL] {
        let extensionName = input.pathExtension.lowercased()
        guard ["pdf", "eps", "ai", "ps", "svg"].contains(extensionName) else {
            throw ConversionError(message: "Choose a PDF, EPS, AI, PS, or SVG file.")
        }
        if extensionName == "svg" {
            let data = try Data(contentsOf: input)
            guard data.range(of: Data("<svg".utf8)) != nil else {
                throw ConversionError(message: "This is not a valid SVG file.")
            }
            let outputData = flattenStrokes ? try SVGStrokeFlattener.flatten(data) : data
            let directory = input.deletingLastPathComponent()
            let base = input.deletingPathExtension().lastPathComponent
            var number = 1
            while true {
                let suffix = number == 1 ? "" : " (\(number))"
                let target = directory.appendingPathComponent(base + suffix + ".svg")
                do {
                    try outputData.write(to: target, options: [.withoutOverwriting])
                    return [target]
                } catch let error as NSError {
                    if error.domain == NSCocoaErrorDomain && error.code == NSFileWriteFileExistsError { number += 1; continue }
                    throw error
                }
            }
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
            if flattenStrokes { try SVGStrokeFlattener.flatten(data).write(to: svg) }
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
    @Published var flattenStrokes = UserDefaults.standard.bool(forKey: "flattenStrokes")
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
                    VStack(spacing: 16) {
                        Toggle(isOn: Binding(get: { state.flattenStrokes }, set: { value in
                            state.flattenStrokes = value
                            UserDefaults.standard.set(value, forKey: "flattenStrokes")
                        })) {
                            Text("Convert strokes to outlines")
                                .font(.system(size: 11))
                                .foregroundStyle(.white.opacity(0.7))
                        }
                        .toggleStyle(.checkbox)
                        .help("Expand borders into filled paths so the SVG does not use strokes")
                        Button(action: choose) {
                            Text("Choose files").font(.system(size: 12, weight: .medium)).padding(.horizontal, 23).padding(.vertical, 10)
                                .background(.white.opacity(0.10), in: Capsule()).overlay(Capsule().stroke(.white.opacity(0.12), lineWidth: 1))
                        }.buttonStyle(.plain)
                    }.padding(.bottom, 28)
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
                    Text("PDF · EPS · AI · PS · SVG")
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
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 440, height: 390), styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
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
        panel.allowedContentTypes = ["pdf", "eps", "ai", "ps", "svg"].compactMap { UTType(filenameExtension: $0) }
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
                let flattenStrokes = self.state.flattenStrokes
                let result = Result { try Converter().convert(url, flattenStrokes: flattenStrokes) }
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
    let flattenStrokes = CommandLine.arguments.contains("--flatten-strokes")
    for path in CommandLine.arguments.dropFirst(2).filter({ $0 != "--flatten-strokes" }) {
        do { for result in try Converter().convert(URL(fileURLWithPath: path), flattenStrokes: flattenStrokes) { print(result.path) } }
        catch { fputs("\(path): \(error.localizedDescription)\n", stderr); failed = true }
    }
    exit(failed ? 1 : 0)
}
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
