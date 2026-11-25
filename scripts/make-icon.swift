import AppKit

// iMarkDown 图标：824pt 圆角方块（macOS 图标网格）+ 纯色底 + 白色矢量「M↓」。
// 只用一层外落影保留系统图标的体积感，不再叠加渐变、玻璃高光与色散。
let canvas: CGFloat = 1024
let inset: CGFloat = 100
let side = canvas - inset * 2
let radius = side * 0.2246
let tileRect = NSRect(x: inset, y: inset, width: side, height: side)
let tile = NSBezierPath(roundedRect: tileRect, xRadius: radius, yRadius: radius)

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> NSColor {
    NSColor(
        srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
        green: CGFloat((hex >> 8) & 0xFF) / 255,
        blue: CGFloat(hex & 0xFF) / 255,
        alpha: alpha
    )
}

let brandBlue = color(0x2F6BF2)

let baseImage = NSImage(size: NSSize(width: canvas, height: canvas), flipped: false) { _ in
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.28)
    shadow.shadowBlurRadius = 26
    shadow.shadowOffset = NSSize(width: 0, height: -14)
    shadow.set()
    brandBlue.setFill()
    tile.fill()
    NSGraphicsContext.restoreGraphicsState()

    // 纯色底：只在最外缘压一道极淡的暗边，避免浅色桌面上边缘发虚。
    let rim = NSBezierPath(
        roundedRect: tileRect.insetBy(dx: 1, dy: 1),
        xRadius: radius - 1, yRadius: radius - 1
    )
    rim.lineWidth = 2
    NSColor.black.withAlphaComponent(0.08).setStroke()
    rim.stroke()

    // 竖向构图：更高的 M + 一个倒三角箭头 + 两行淡淡的代码文本。
    let markW = side * 0.38
    let markH = side * 0.33
    let strokeW = side * 0.09
    let triangleW = side * 0.24
    let triangleH = side * 0.115
    let triangleGap = side * 0.045
    let codeGap = side * 0.06
    let codeW = side * 0.25
    let codeH = side * 0.10
    let codeStroke = side * 0.017

    // M 的圆角笔帽会向上多出半个笔宽，把它计入总高，才能让整组图形视觉居中。
    let totalH = markH + strokeW / 2 + triangleGap + triangleH
        + codeGap + codeH
    let visualTop = tileRect.midY + totalH / 2

    let left = tileRect.midX - markW / 2
    let top = visualTop - strokeW / 2
    let bottom = top - markH

    let mPath = NSBezierPath()
    mPath.lineWidth = strokeW
    mPath.lineCapStyle = .round
    mPath.lineJoinStyle = .round
    mPath.move(to: NSPoint(x: left, y: bottom))
    mPath.line(to: NSPoint(x: left, y: top))
    mPath.line(to: NSPoint(x: left + markW / 2, y: bottom + markH * 0.22))
    mPath.line(to: NSPoint(x: left + markW, y: top))
    mPath.line(to: NSPoint(x: left + markW, y: bottom))

    // 倒三角就是箭头本身，不再保留箭杆。
    let triangleTop = bottom - triangleGap
    let triangleTip = triangleTop - triangleH
    let arrow = NSBezierPath()
    arrow.move(to: NSPoint(x: tileRect.midX - triangleW / 2, y: triangleTop))
    arrow.line(to: NSPoint(x: tileRect.midX + triangleW / 2, y: triangleTop))
    arrow.line(to: NSPoint(x: tileRect.midX, y: triangleTip))
    arrow.close()

    // 编码符号 </>：用 45% 白色压在底部，点出「代码」语义又不抢 M。
    let codeMidX = tileRect.midX
    let codeMidY = triangleTip - codeGap - codeH / 2
    let codeLeft = codeMidX - codeW / 2
    let codeRight = codeMidX + codeW / 2
    let chevronDepth = codeH * 0.42

    let codePath = NSBezierPath()
    codePath.lineWidth = codeStroke
    codePath.lineCapStyle = .round
    codePath.lineJoinStyle = .round

    codePath.move(to: NSPoint(x: codeLeft + chevronDepth, y: codeMidY + codeH / 2))
    codePath.line(to: NSPoint(x: codeLeft, y: codeMidY))
    codePath.line(to: NSPoint(x: codeLeft + chevronDepth, y: codeMidY - codeH / 2))

    codePath.move(to: NSPoint(x: codeMidX + codeH * 0.16, y: codeMidY - codeH * 0.55))
    codePath.line(to: NSPoint(x: codeMidX - codeH * 0.16, y: codeMidY + codeH * 0.55))

    codePath.move(to: NSPoint(x: codeRight - chevronDepth, y: codeMidY + codeH / 2))
    codePath.line(to: NSPoint(x: codeRight, y: codeMidY))
    codePath.line(to: NSPoint(x: codeRight - chevronDepth, y: codeMidY - codeH / 2))

    NSColor.white.setStroke()
    NSColor.white.setFill()
    mPath.stroke()
    arrow.fill()

    NSColor.white.withAlphaComponent(0.5).setStroke()
    codePath.stroke()

    return true
}

func pngData(from image: NSImage, pixels: Int) -> Data? {
    guard let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: pixels,
        pixelsHigh: pixels,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .calibratedRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    ) else { return nil }

    rep.size = NSSize(width: pixels, height: pixels)
    guard let context = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    context.imageInterpolation = .high
    image.draw(
        in: NSRect(x: 0, y: 0, width: pixels, height: pixels),
        from: NSRect(x: 0, y: 0, width: canvas, height: canvas),
        operation: .copy,
        fraction: 1
    )
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])
}

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let support = root.appendingPathComponent("Support", isDirectory: true)
let iconset = URL(fileURLWithPath: "/tmp/iMarkDown.iconset", isDirectory: true)
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

let variants: [(name: String, pixels: Int)] = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32),
    ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256),
    ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024)
]

for variant in variants {
    guard let data = pngData(from: baseImage, pixels: variant.pixels) else {
        fatalError("渲染失败：\(variant.name)")
    }
    try data.write(to: iconset.appendingPathComponent("\(variant.name).png"))
}

// 同时输出 1024 PNG，用于 DMG 文件图标与 README。
if let preview = pngData(from: baseImage, pixels: 1024) {
    try preview.write(to: support.appendingPathComponent("AppIcon.png"))
}

let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", support.appendingPathComponent("AppIcon.icns").path]
try iconutil.run()
iconutil.waitUntilExit()
guard iconutil.terminationStatus == 0 else {
    fatalError("iconutil 失败")
}
print("wrote \(support.appendingPathComponent("AppIcon.icns").path)")
