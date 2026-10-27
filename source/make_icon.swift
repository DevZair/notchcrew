import AppKit

let icon = NSImage(size: NSSize(width: 512, height: 512))
icon.lockFocus()
NSColor(calibratedRed: 0.08, green: 0.13, blue: 0.10, alpha: 1).setFill()
NSBezierPath(roundedRect: NSRect(x: 0, y: 0, width: 512, height: 512), xRadius: 108, yRadius: 108).fill()
func pixel(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat, _ color: NSColor) {
    color.setFill(); NSRect(x: x, y: y, width: w, height: h).fill()
}
let cream = NSColor(calibratedRed: 0.78, green: 0.84, blue: 0.64, alpha: 1)
let dark = NSColor(calibratedRed: 0.19, green: 0.29, blue: 0.22, alpha: 1)
pixel(72, 120, 368, 230, cream)
pixel(88, 137, 336, 196, dark)
for y in 0..<3 {
    for x in 0..<4 {
        let px = CGFloat(109 + x * 76), py = CGFloat(163 + y * 55)
        pixel(px, py, 45, 32, cream)
        pixel(px + 6, py + 6, 33, 20, NSColor(calibratedRed: 0.48, green: 0.64, blue: 0.47, alpha: 1))
        pixel(px + 19, py - 6, 7, 7, cream)
    }
}
pixel(182, 366, 148, 24, cream)
pixel(215, 395, 82, 14, cream)
icon.unlockFocus()
guard CommandLine.arguments.count == 2,
      let tiff = icon.tiffRepresentation,
      let bitmap = NSBitmapImageRep(data: tiff),
      let png = bitmap.representation(using: .png, properties: [:]) else { exit(1) }
do { try png.write(to: URL(fileURLWithPath: CommandLine.arguments[1])) }
catch { fputs("Icon write failed: \(error)\n", stderr); exit(1) }
