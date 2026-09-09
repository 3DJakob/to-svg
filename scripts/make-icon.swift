import Cocoa
// The same scalable geometry as assets/logo.svg, rendered at every macOS icon size.
let output = URL(fileURLWithPath: CommandLine.arguments[1])
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
func render(_ size: Int) throws -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let ctx = NSGraphicsContext.current!.cgContext
    ctx.scaleBy(x: CGFloat(size) / 1024, y: CGFloat(size) / 1024)
    ctx.translateBy(x: 0, y: 1024); ctx.scaleBy(x: 1, y: -1)
    let tile = CGPath(roundedRect: CGRect(x: 100, y: 100, width: 824, height: 824), cornerWidth: 184, cornerHeight: 184, transform: nil)
    ctx.saveGState(); ctx.addPath(tile); ctx.clip()
    let colors = [CGColor(red: 81/255, green: 37/255, blue: 102/255, alpha: 1), CGColor(red: 48/255, green: 44/255, blue: 80/255, alpha: 1), CGColor(red: 28/255, green: 89/255, blue: 100/255, alpha: 1)]
    let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors as CFArray, locations: [0, 0.52, 1])!
    ctx.drawLinearGradient(gradient, start: CGPoint(x: 100, y: 100), end: CGPoint(x: 924, y: 924), options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    ctx.restoreGState()
    ctx.addPath(tile); ctx.setStrokeColor(CGColor(gray: 1, alpha: 0.18)); ctx.setLineWidth(2); ctx.strokePath()
    ctx.setStrokeColor(CGColor(red: 244/255, green: 240/255, blue: 1, alpha: 1)); ctx.setLineWidth(30); ctx.setLineCap(.round)
    ctx.move(to: CGPoint(x: 420, y: 395)); ctx.addCurve(to: CGPoint(x: 604, y: 629), control1: CGPoint(x: 420, y: 515), control2: CGPoint(x: 604, y: 465)); ctx.strokePath()
    for (x, y) in [(420, 355), (604, 669)] {
        ctx.strokeEllipse(in: CGRect(x: x - 40, y: y - 40, width: 80, height: 80))
    }
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}
for size in [16, 32, 128, 256, 512] {
    try render(size).write(to: output.appendingPathComponent("icon_\(size)x\(size).png"))
    try render(size * 2).write(to: output.appendingPathComponent("icon_\(size)x\(size)@2x.png"))
}
try render(1024).write(to: output.deletingLastPathComponent().appendingPathComponent("logo.png"))
