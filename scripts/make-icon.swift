import AppKit

// iMarkDown 图标：824pt 圆角方块（macOS 图标网格）+ 液态渐变 + 「M↓」字形。
let canvas: CGFloat = 1024
let inset: CGFloat = 100          // macOS 应用图标四周留白
let side = canvas - inset * 2     // 824
let radius = side * 0.2246        // 与系统 squircle 比例接近

func roundedFont(_ size: CGFloat, _ weight: NSFont.Weight) -> NSFont {
    let base = NSFont.systemFont(ofSize: size, weight: weight)
    if let desc = base.fontDescriptor.withDesign(.rounded) {
        return NSFont(descriptor: desc, size: size) ?? base
    }
    return base
}

let image = NSImage(size: NSSize(width: canvas, height: canvas), flipped: false) { _ in
    let tileRect = NSRect(x: inset, y: inset, width: side, height: side)
    let tile = NSBezierPath(roundedRect: tileRect, xRadius: radius, yRadius: radius)

    // 落影
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.38)
    shadow.shadowBlurRadius = 26
    shadow.shadowOffset = NSSize(width: 0, height: -14)
    shadow.set()
    NSColor.black.setFill()
    tile.fill()
    NSGraphicsContext.restoreGraphicsState()

    // 主体渐变（深蓝 → 亮青）
    let gradient = NSGradient(colors: [
        NSColor(srgbRed: 0.24, green: 0.58, blue: 1.00, alpha: 1),
        NSColor(srgbRed: 0.04, green: 0.36, blue: 0.92, alpha: 1)
    ])!
    gradient.draw(in: tile, angle: -72)

    // 左上高光，做出玻璃质感
    NSGraphicsContext.saveGraphicsState()
    tile.addClip()
    let highlight = NSGradient(colorsAndLocations:
        (NSColor.white.withAlphaComponent(0.55), 0.0),
        (NSColor.white.withAlphaComponent(0.12), 0.45),
        (NSColor.white.withAlphaComponent(0.0), 0.75)
    )!
    highlight.draw(
        fromCenter: NSPoint(x: tileRect.minX + side * 0.26, y: tileRect.maxY - side * 0.18),
        radius: 0,
        toCenter: NSPoint(x: tileRect.minX + side * 0.30, y: tileRect.maxY - side * 0.22),
        radius: side * 0.78,
        options: []
    )
    // 底部内阴影，增强体积感
    let bottomShade = NSGradient(colorsAndLocations:
        (NSColor.black.withAlphaComponent(0.0), 0.55),
        (NSColor.black.withAlphaComponent(0.22), 1.0)
    )!
    bottomShade.draw(in: tile, angle: -90)
    NSGraphicsContext.restoreGraphicsState()

    // 内描边
    let rim = NSBezierPath(roundedRect: tileRect.insetBy(dx: 1.5, dy: 1.5),
                           xRadius: radius - 1.5, yRadius: radius - 1.5)
    rim.lineWidth = 3
    NSColor.white.withAlphaComponent(0.30).setStroke()
    rim.stroke()

    // 「M↓」字形
    let mFont = roundedFont(side * 0.52, .heavy)
    let arrowFont = roundedFont(side * 0.34, .heavy)
    let mText = NSAttributedString(string: "M", attributes: [.font: mFont, .foregroundColor: NSColor.white])
    let arrowText = NSAttributedString(string: "↓", attributes: [.font: arrowFont, .foregroundColor: NSColor.white.withAlphaComponent(0.92)])

    let mSize = mText.size()
    let arrowSize = arrowText.size()
    let gap = side * 0.015
    let totalWidth = mSize.width + gap + arrowSize.width

    let originX = tileRect.midX - totalWidth / 2
    // 让整组字形的视觉中心落在方块中心，箭头底部与 M 的基线对齐
    let baseline = tileRect.midY - mSize.height * 0.36

    NSGraphicsContext.saveGraphicsState()
    let glyphShadow = NSShadow()
    glyphShadow.shadowColor = NSColor.black.withAlphaComponent(0.28)
    glyphShadow.shadowBlurRadius = 18
    glyphShadow.shadowOffset = NSSize(width: 0, height: -6)
    glyphShadow.set()
    mText.draw(at: NSPoint(x: originX, y: baseline))
    arrowText.draw(at: NSPoint(x: originX + mSize.width + gap, y: baseline - mSize.height * 0.02))
    NSGraphicsContext.restoreGraphicsState()

    return true
}

guard let tiff = image.tiffRepresentation,
      let rep = NSBitmapImageRep(data: tiff),
      let png = rep.representation(using: .png, properties: [:]) else {
    fatalError("渲染失败")
}

let out = URL(fileURLWithPath: "/tmp/AppIcon-1024.png")
try png.write(to: out)
print("wrote \(out.path)")
