// Draws the app icon: dark rounded square, white waveform, red record dot.
import AppKit
let size = 1024.0
let img = NSImage(size: NSSize(width: size, height: size))
img.lockFocus()
let rect = NSRect(x: 100, y: 100, width: 824, height: 824)
let bg = NSBezierPath(roundedRect: rect, xRadius: 185, yRadius: 185)
NSGradient(starting: NSColor(calibratedRed: 0.16, green: 0.18, blue: 0.24, alpha: 1),
           ending: NSColor(calibratedRed: 0.06, green: 0.07, blue: 0.10, alpha: 1))!.draw(in: bg, angle: -90)
let cfg = NSImage.SymbolConfiguration(pointSize: 430, weight: .semibold).applying(.init(paletteColors: [.white]))
if let wave = NSImage(systemSymbolName: "waveform", accessibilityDescription: nil)?.withSymbolConfiguration(cfg) {
    let w = wave.size
    wave.draw(in: NSRect(x: (size - w.width) / 2 - 40, y: (size - w.height) / 2 - 20, width: w.width, height: w.height))
}
NSColor(calibratedRed: 0.95, green: 0.23, blue: 0.23, alpha: 1).setFill()
NSBezierPath(ovalIn: NSRect(x: 690, y: 640, width: 170, height: 170)).fill()
img.unlockFocus()
let rep = NSBitmapImageRep(data: img.tiffRepresentation!)!
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
