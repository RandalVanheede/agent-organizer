// Renders the app icon: dark rounded square, purple→indigo gradient wash,
// a folder silhouette with three "tab" notches, and a terminal prompt.
import AppKit

func render(size: CGFloat) -> NSImage {
    let img = NSImage(size: NSSize(width: size, height: size))
    img.lockFocus()
    let ctx = NSGraphicsContext.current!.cgContext
    let s = size
    let inset = s * 0.055                          // macOS icon grid margin
    let rect = CGRect(x: inset, y: inset, width: s - 2*inset, height: s - 2*inset)
    let radius = rect.width * 0.2237               // Apple's squircle-ish ratio
    let bg = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)

    // Background gradient
    ctx.saveGState()
    bg.addClip()
    let colors = [NSColor(calibratedRed: 0.13, green: 0.11, blue: 0.20, alpha: 1).cgColor,
                  NSColor(calibratedRed: 0.07, green: 0.06, blue: 0.10, alpha: 1).cgColor] as CFArray
    let grad = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 1])!
    ctx.drawLinearGradient(grad, start: CGPoint(x: rect.minX, y: rect.maxY), end: CGPoint(x: rect.maxX, y: rect.minY), options: [])
    // Soft purple glow top-left
    let glow = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                          colors: [NSColor(calibratedRed: 0.62, green: 0.36, blue: 0.85, alpha: 0.55).cgColor,
                                   NSColor.clear.cgColor] as CFArray, locations: [0, 1])!
    ctx.drawRadialGradient(glow, startCenter: CGPoint(x: rect.minX + rect.width*0.25, y: rect.maxY - rect.height*0.2), startRadius: 0,
                           endCenter: CGPoint(x: rect.minX + rect.width*0.25, y: rect.maxY - rect.height*0.2), endRadius: rect.width*0.9, options: [])
    ctx.restoreGState()

    // Folder body with tab notches (the "vertical tabs" idea)
    let purple = NSColor(calibratedRed: 0.69, green: 0.45, blue: 0.90, alpha: 1)
    let fw = rect.width * 0.64, fh = rect.height * 0.46
    let fx = rect.midX - fw/2, fy = rect.midY - fh/2 - rect.height*0.04
    let body = NSBezierPath(roundedRect: CGRect(x: fx, y: fy, width: fw, height: fh), xRadius: fw*0.07, yRadius: fw*0.07)
    // folder back-tab
    let tabW = fw * 0.38, tabH = fh * 0.16
    let backTab = NSBezierPath(roundedRect: CGRect(x: fx, y: fy + fh - tabH*0.35, width: tabW, height: tabH), xRadius: tabH*0.4, yRadius: tabH*0.4)
    purple.withAlphaComponent(0.55).setFill(); backTab.fill()
    purple.setFill(); body.fill()

    // Three horizontal "session tabs" as lighter strips near the top of the folder
    let stripH = fh * 0.10, gap = fw * 0.03
    let stripW = (fw - fw*0.16 - gap*2) / 3
    for i in 0..<3 {
        let x = fx + fw*0.08 + CGFloat(i) * (stripW + gap)
        let r = CGRect(x: x, y: fy + fh - fh*0.30, width: stripW, height: stripH)
        (i == 0 ? NSColor.white.withAlphaComponent(0.92) : NSColor.white.withAlphaComponent(0.38)).setFill()
        NSBezierPath(roundedRect: r, xRadius: stripH*0.35, yRadius: stripH*0.35).fill()
    }

    // Prompt ">_" in the folder body
    let promptFont = NSFont.monospacedSystemFont(ofSize: fh * 0.42, weight: .bold)
    let attrs: [NSAttributedString.Key: Any] = [.font: promptFont, .foregroundColor: NSColor(calibratedRed: 0.10, green: 0.07, blue: 0.16, alpha: 1)]
    let str = NSAttributedString(string: ">_", attributes: attrs)
    let sz = str.size()
    str.draw(at: CGPoint(x: fx + fw*0.10, y: fy + fh*0.12))
    _ = sz

    img.unlockFocus()
    return img
}

func writePNG(_ image: NSImage, to path: String, pixels: Int) {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = NSSize(width: pixels, height: pixels)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    image.draw(in: NSRect(x: 0, y: 0, width: pixels, height: pixels), from: .zero, operation: .copy, fraction: 1)
    NSGraphicsContext.restoreGraphicsState()
    try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: path))
}

let out = CommandLine.arguments[1]
for (name, px) in [("16x16",16),("16x16@2x",32),("32x32",32),("32x32@2x",64),("128x128",128),("128x128@2x",256),
                   ("256x256",256),("256x256@2x",512),("512x512",512),("512x512@2x",1024)] {
    writePNG(render(size: CGFloat(px)), to: "\(out)/icon_\(name).png", pixels: px)
}
print("iconset written")
