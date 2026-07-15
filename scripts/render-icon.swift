// Рендер иконки Vox: сквиркл с градиентом + белая волна.
// Запуск: swift scripts/render-icon.swift <output-dir>
import AppKit

let outputDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "design/AppIcon.iconset"
try? FileManager.default.createDirectory(atPath: outputDir, withIntermediateDirectories: true)

func drawIcon(size: CGFloat) -> NSImage {
    let image = NSImage(size: NSSize(width: size, height: size))
    image.lockFocus()
    guard let ctx = NSGraphicsContext.current?.cgContext else {
        image.unlockFocus()
        return image
    }

    let scale = size / 1024.0

    // Контент занимает ~82% полотна (маргин как у системных иконок)
    let inset = 92.0 * scale
    let rect = CGRect(x: inset, y: inset, width: size - inset * 2, height: size - inset * 2)
    let radius = 210.0 * scale

    // Тень
    ctx.saveGState()
    ctx.setShadow(
        offset: CGSize(width: 0, height: -10 * scale), blur: 24 * scale,
        color: NSColor.black.withAlphaComponent(0.3).cgColor)
    let path = CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
    ctx.addPath(path)
    ctx.setFillColor(NSColor.white.cgColor)
    ctx.fillPath()
    ctx.restoreGState()

    // Градиент фона: индиго
    ctx.saveGState()
    ctx.addPath(path)
    ctx.clip()
    let colors = [
        NSColor(calibratedRed: 0.545, green: 0.537, blue: 1.0, alpha: 1).cgColor,   // #8B89FF
        NSColor(calibratedRed: 0.337, green: 0.325, blue: 0.859, alpha: 1).cgColor, // #5653DB
        NSColor(calibratedRed: 0.243, green: 0.231, blue: 0.702, alpha: 1).cgColor, // #3E3BB3
    ]
    let gradient = CGGradient(
        colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors as CFArray,
        locations: [0.0, 0.62, 1.0])!
    ctx.drawLinearGradient(
        gradient,
        start: CGPoint(x: rect.midX, y: rect.maxY),
        end: CGPoint(x: rect.midX, y: rect.minY),
        options: [])

    // Лёгкий блик сверху
    let glossColors = [
        NSColor.white.withAlphaComponent(0.18).cgColor,
        NSColor.white.withAlphaComponent(0.0).cgColor,
    ]
    let gloss = CGGradient(
        colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: glossColors as CFArray,
        locations: [0.0, 1.0])!
    ctx.drawLinearGradient(
        gloss,
        start: CGPoint(x: rect.midX, y: rect.maxY),
        end: CGPoint(x: rect.midX, y: rect.midY),
        options: [])

    // Волна: 5 столбиков с круглыми торцами
    let heights: [CGFloat] = [0.30, 0.54, 0.78, 0.46, 0.28]
    let barWidth = 64.0 * scale
    let gap = 54.0 * scale
    let totalWidth = barWidth * CGFloat(heights.count) + gap * CGFloat(heights.count - 1)
    var x = rect.midX - totalWidth / 2

    ctx.setShadow(
        offset: CGSize(width: 0, height: -6 * scale), blur: 14 * scale,
        color: NSColor.black.withAlphaComponent(0.22).cgColor)
    ctx.setFillColor(NSColor.white.cgColor)
    for height in heights {
        let barHeight = rect.height * height
        let barRect = CGRect(
            x: x, y: rect.midY - barHeight / 2, width: barWidth, height: barHeight)
        let barPath = CGPath(
            roundedRect: barRect, cornerWidth: barWidth / 2, cornerHeight: barWidth / 2,
            transform: nil)
        ctx.addPath(barPath)
        ctx.fillPath()
        x += barWidth + gap
    }
    ctx.restoreGState()

    image.unlockFocus()
    return image
}

func savePNG(_ image: NSImage, size: Int, name: String) {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8,
        samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
        bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = NSSize(width: size, height: size)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    image.draw(in: NSRect(x: 0, y: 0, width: size, height: size))
    NSGraphicsContext.restoreGraphicsState()
    let data = rep.representation(using: .png, properties: [:])!
    try! data.write(to: URL(fileURLWithPath: "\(outputDir)/\(name).png"))
}

// Все размеры для .icns
let specs: [(Int, String)] = [
    (16, "icon_16x16"), (32, "icon_16x16@2x"),
    (32, "icon_32x32"), (64, "icon_32x32@2x"),
    (128, "icon_128x128"), (256, "icon_128x128@2x"),
    (256, "icon_256x256"), (512, "icon_256x256@2x"),
    (512, "icon_512x512"), (1024, "icon_512x512@2x"),
]
for (size, name) in specs {
    savePNG(drawIcon(size: CGFloat(size)), size: size, name: name)
}
print("iconset: \(outputDir)")
