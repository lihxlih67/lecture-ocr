import AppKit

let canvas: CGFloat = 1024
let master = NSImage(size: NSSize(width: canvas, height: canvas))
master.lockFocus()

let background = NSBezierPath(roundedRect: NSRect(x: 24, y: 24, width: 976, height: 976), xRadius: 220, yRadius: 220)
NSGradient(colors: [NSColor(calibratedRed: 0.12, green: 0.38, blue: 0.91, alpha: 1),
                    NSColor(calibratedRed: 0.12, green: 0.67, blue: 0.91, alpha: 1)])?.draw(in: background, angle: -45)

let paper = NSBezierPath(roundedRect: NSRect(x: 225, y: 125, width: 575, height: 760), xRadius: 56, yRadius: 56)
let shadow = NSShadow()
shadow.shadowColor = NSColor(calibratedWhite: 0.05, alpha: 0.25)
shadow.shadowBlurRadius = 32
shadow.shadowOffset = NSSize(width: 0, height: -14)
shadow.set()
NSColor(calibratedWhite: 0.99, alpha: 1).setFill()
paper.fill()
NSShadow().set()

let ink = NSColor(calibratedRed: 0.13, green: 0.22, blue: 0.39, alpha: 1)
let paleInk = NSColor(calibratedRed: 0.55, green: 0.63, blue: 0.76, alpha: 1)
let accent = NSColor(calibratedRed: 0.10, green: 0.42, blue: 0.96, alpha: 1)

func line(_ x: CGFloat, _ y: CGFloat, _ width: CGFloat, _ height: CGFloat, _ color: NSColor, _ radius: CGFloat = 8) {
    color.setFill()
    NSBezierPath(roundedRect: NSRect(x: x, y: y, width: width, height: height), xRadius: radius, yRadius: radius).fill()
}

// Header and a few text rows keep the page readable at small icon sizes.
line(330, 750, 300, 28, ink, 14)
line(330, 702, 215, 16, paleInk, 8)
line(305, 620, 405, 20, ink, 10)
line(305, 574, 375, 15, paleInk, 7)
line(305, 530, 394, 15, paleInk, 7)
line(305, 486, 340, 15, paleInk, 7)
line(305, 404, 400, 20, ink, 10)
line(305, 358, 372, 15, paleInk, 7)
line(305, 314, 390, 15, paleInk, 7)
line(305, 270, 320, 15, paleInk, 7)

// Four blue scan brackets mark the page corners.
let marks: [(CGFloat, CGFloat, Bool, Bool)] = [
    (270, 820, true, true), (755, 820, false, true),
    (270, 190, true, false), (755, 190, false, false)
]
for (x, y, left, top) in marks {
    accent.setStroke()
    let path = NSBezierPath()
    path.lineWidth = 17
    path.lineCapStyle = .round
    let horizontal: CGFloat = left ? 58 : -58
    let vertical: CGFloat = top ? -58 : 58
    path.move(to: NSPoint(x: x + horizontal, y: y))
    path.line(to: NSPoint(x: x, y: y))
    path.line(to: NSPoint(x: x, y: y + vertical))
    path.stroke()
}

master.unlockFocus()

let iconset = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
let sizes: [(Int, String)] = [
    (16, "icon_16x16.png"), (32, "icon_16x16@2x.png"),
    (32, "icon_32x32.png"), (64, "icon_32x32@2x.png"),
    (128, "icon_128x128.png"), (256, "icon_128x128@2x.png"),
    (256, "icon_256x256.png"), (512, "icon_256x256@2x.png"),
    (512, "icon_512x512.png"), (1024, "icon_512x512@2x.png")
]
for (size, name) in sizes {
    let bitmap = NSImage(size: NSSize(width: size, height: size))
    bitmap.lockFocus()
    master.draw(in: NSRect(x: 0, y: 0, width: size, height: size),
                from: NSRect(origin: .zero, size: master.size), operation: .copy, fraction: 1)
    bitmap.unlockFocus()
    guard let tiff = bitmap.tiffRepresentation,
          let rep = NSBitmapImageRep(data: tiff),
          let data = rep.representation(using: .png, properties: [:]) else {
        fatalError("Failed to encode \(name)")
    }
    try data.write(to: iconset.appendingPathComponent(name))
}

func appendBigEndian(_ value: UInt32, to data: inout Data) {
    var encoded = value.bigEndian
    data.append(Data(bytes: &encoded, count: MemoryLayout<UInt32>.size))
}

let icnsParts: [(String, String)] = [
    ("icp4", "icon_16x16.png"),
    ("icp5", "icon_32x32.png"),
    ("icp6", "icon_32x32@2x.png"),
    ("ic07", "icon_128x128.png"),
    ("ic08", "icon_128x128@2x.png"),
    ("ic09", "icon_256x256@2x.png"),
    ("ic10", "icon_512x512@2x.png")
]
var chunks = Data()
for (type, filename) in icnsParts {
    let png = try Data(contentsOf: iconset.appendingPathComponent(filename))
    chunks.append(contentsOf: type.utf8)
    appendBigEndian(UInt32(png.count + 8), to: &chunks)
    chunks.append(png)
}
var icns = Data("icns".utf8)
appendBigEndian(UInt32(chunks.count + 8), to: &icns)
icns.append(chunks)
let icnsURL = iconset.deletingLastPathComponent().appendingPathComponent("AppIcon.icns")
try icns.write(to: icnsURL)
