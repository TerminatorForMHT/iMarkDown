import AppKit

// iMarkDown 图标：824pt 圆角方块（macOS 图标网格）+ 液态玻璃渐变 + 矢量「M↓」字形。
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

let baseImage = NSImage(size: NSSize(width: canvas, height: canvas), flipped: false) { _ in
    // 外落影
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.34)
    shadow.shadowBlurRadius = 30
    shadow.shadowOffset = NSSize(width: 0, height: -16)
    shadow.set()
    color(0x0A1633).setFill()
    tile.fill()
    NSGraphicsContext.restoreGraphicsState()

    NSGraphicsContext.saveGraphicsState()
    tile.addClip()

    // 主体渐变：亮蓝 → 宝蓝 → 深靛
    NSGradient(colorsAndLocations:
        (color(0x6FC0FF), 0.0),
        (color(0x2F6BF2), 0.40),
        (color(0x1B3E9E), 0.78),
        (color(0x14307A), 1.0)
    )!.draw(in: tile, angle: -68)

    // 左上冷光晕，制造玻璃受光
    NSGradient(colorsAndLocations:
        (color(0xCFF3FF, 0.52), 0.0),
        (color(0xCFF3FF, 0.0), 1.0)
    )!.draw(
        fromCenter: NSPoint(x: tileRect.minX + side * 0.26, y: tileRect.maxY - side * 0.14), radius: 0,
        toCenter: NSPoint(x: tileRect.minX + side * 0.28, y: tileRect.maxY - side * 0.16), radius: side * 0.78,
        options: []
    )

    // 右下紫色氛围，避免单色发闷
    NSGradient(colorsAndLocations:
        (color(0x8B5CF6, 0.24), 0.0),
        (color(0x8B5CF6, 0.0), 1.0)
    )!.draw(
        fromCenter: NSPoint(x: tileRect.maxX - side * 0.16, y: tileRect.minY + side * 0.24), radius: 0,
        toCenter: NSPoint(x: tileRect.maxX - side * 0.18, y: tileRect.minY + side * 0.22), radius: side * 0.66,
        options: []
    )

    // 彩色光斑：玻璃字形透出这些颜色，才有“透明玻璃”的观感
    NSGradient(colorsAndLocations:
        (color(0xFF7AD9, 0.28), 0.0),
        (color(0xFF7AD9, 0.0), 1.0)
    )!.draw(
        fromCenter: NSPoint(x: tileRect.minX + side * 0.80, y: tileRect.midY + side * 0.06), radius: 0,
        toCenter: NSPoint(x: tileRect.minX + side * 0.80, y: tileRect.midY + side * 0.06), radius: side * 0.40,
        options: []
    )

    NSGradient(colorsAndLocations:
        (color(0x35E0FF, 0.32), 0.0),
        (color(0x35E0FF, 0.0), 1.0)
    )!.draw(
        fromCenter: NSPoint(x: tileRect.minX + side * 0.22, y: tileRect.minY + side * 0.26), radius: 0,
        toCenter: NSPoint(x: tileRect.minX + side * 0.22, y: tileRect.minY + side * 0.26), radius: side * 0.38,
        options: []
    )

    // 斜向玻璃反光：两端归零，避免出现硬边界
    NSGraphicsContext.saveGraphicsState()
    let ctx = NSGraphicsContext.current!.cgContext
    ctx.translateBy(x: tileRect.midX, y: tileRect.midY)
    ctx.rotate(by: -0.50)
    let band = NSRect(x: -side * 0.95, y: side * 0.02, width: side * 1.9, height: side * 0.46)
    NSGradient(colorsAndLocations:
        (NSColor.white.withAlphaComponent(0.0), 0.0),
        (NSColor.white.withAlphaComponent(0.13), 0.46),
        (NSColor.white.withAlphaComponent(0.0), 1.0)
    )!.draw(in: band, angle: 90)
    NSGraphicsContext.restoreGraphicsState()

    // 底部内阴影，增强体积
    NSGradient(colorsAndLocations:
        (NSColor.black.withAlphaComponent(0.0), 0.52),
        (NSColor.black.withAlphaComponent(0.26), 1.0)
    )!.draw(in: tile, angle: -90)

    NSGraphicsContext.restoreGraphicsState()

    // 外沿暗边 + 内沿高光
    let darkRim = NSBezierPath(
        roundedRect: tileRect.insetBy(dx: 1, dy: 1),
        xRadius: radius - 1, yRadius: radius - 1
    )
    darkRim.lineWidth = 2
    color(0x05122E, 0.45).setStroke()
    darkRim.stroke()

    let rim = NSBezierPath(
        roundedRect: tileRect.insetBy(dx: 2.5, dy: 2.5),
        xRadius: radius - 2.5, yRadius: radius - 2.5
    )
    rim.lineWidth = 2.5
    NSColor.white.withAlphaComponent(0.28).setStroke()
    rim.stroke()

    // 矢量「M↓」
    let markW = side * 0.315
    let markH = side * 0.295
    let strokeW = side * 0.086
    let gap = side * 0.088
    let headW = side * 0.152
    let totalW = markW + gap + headW

    let left = tileRect.midX - totalW / 2
    let bottom = tileRect.midY - markH / 2
    let top = bottom + markH

    let mPath = NSBezierPath()
    mPath.lineWidth = strokeW
    mPath.lineCapStyle = .round
    mPath.lineJoinStyle = .round
    mPath.move(to: NSPoint(x: left, y: bottom))
    mPath.line(to: NSPoint(x: left, y: top))
    mPath.line(to: NSPoint(x: left + markW / 2, y: bottom + markH * 0.18))
    mPath.line(to: NSPoint(x: left + markW, y: top))
    mPath.line(to: NSPoint(x: left + markW, y: bottom))

    // 实心箭头：头部明显宽于竖杆，小尺寸下更清晰
    let arrowX = left + markW + gap + headW / 2
    let shaftW = side * 0.076
    let arrowTop = top - markH * 0.05
    let tipY = bottom + markH * 0.02
    let headY = tipY + markH * 0.26

    let arrow = NSBezierPath()
    arrow.move(to: NSPoint(x: arrowX - shaftW / 2, y: arrowTop))
    arrow.line(to: NSPoint(x: arrowX + shaftW / 2, y: arrowTop))
    arrow.line(to: NSPoint(x: arrowX + shaftW / 2, y: headY))
    arrow.line(to: NSPoint(x: arrowX + headW / 2, y: headY))
    arrow.line(to: NSPoint(x: arrowX, y: tipY))
    arrow.line(to: NSPoint(x: arrowX - headW / 2, y: headY))
    arrow.line(to: NSPoint(x: arrowX - shaftW / 2, y: headY))
    arrow.close()

    // 液态玻璃字形：先把描边 M 转成可填充轮廓，与实心箭头一起做玻璃材质
    let mStroke = mPath.cgPath.copy(
        strokingWithWidth: strokeW,
        lineCap: .round,
        lineJoin: .round,
        miterLimit: 10
    )
    let mOutline = NSBezierPath(cgPath: mStroke)
    // M 与箭头是两个互不相交的路径，必须先合并再 addClip，否则交集为空
    let glyphUnion = NSBezierPath(cgPath: mStroke)
    glyphUnion.append(arrow)
    let glyphBox = mOutline.bounds.union(arrow.bounds)

    // 背后柔和暗晕，让玻璃字形从底色中浮起来
    NSGradient(colorsAndLocations:
        (color(0x04122E, 0.34), 0.0),
        (color(0x04122E, 0.0), 1.0)
    )!.draw(
        fromCenter: NSPoint(x: glyphBox.midX, y: glyphBox.midY), radius: 0,
        toCenter: NSPoint(x: glyphBox.midX, y: glyphBox.midY), radius: glyphBox.width * 0.66,
        options: []
    )

    // 落影：只保留字形外侧的投影，本体用 destinationOut 挖掉，避免把玻璃涂成灰色
    NSGraphicsContext.saveGraphicsState()
    let shadowCtx = NSGraphicsContext.current!.cgContext
    shadowCtx.beginTransparencyLayer(auxiliaryInfo: nil)
    shadowCtx.setShadow(
        offset: CGSize(width: 0, height: -8),
        blur: 20,
        color: color(0x02102E, 0.42).cgColor
    )
    shadowCtx.setFillColor(color(0x02102E, 1.0).cgColor)
    shadowCtx.addPath(mStroke)
    shadowCtx.addPath(arrow.cgPath)
    shadowCtx.fillPath()
    shadowCtx.setShadow(offset: .zero, blur: 0, color: nil)
    shadowCtx.setBlendMode(.destinationOut)
    shadowCtx.setFillColor(NSColor.black.cgColor)
    shadowCtx.addPath(mStroke)
    shadowCtx.addPath(arrow.cgPath)
    shadowCtx.fillPath()
    shadowCtx.endTransparencyLayer()
    NSGraphicsContext.restoreGraphicsState()

    // —— 液态玻璃主体 ——
    NSGraphicsContext.saveGraphicsState()
    glyphUnion.addClip()

    // 玻璃底色：保持通透，只在最上缘与下缘略微提亮
    NSGradient(colorsAndLocations:
        (NSColor.white.withAlphaComponent(0.16), 0.0),
        (NSColor.white.withAlphaComponent(0.0), 0.42),
        (color(0xBFE8FF, 0.12), 1.0)
    )!.draw(in: glyphBox, angle: -90)

    // 折射：背景里的彩色光斑透过玻璃后偏移、增亮
    NSGradient(colorsAndLocations:
        (color(0xFF7AD9, 0.30), 0.0),
        (color(0xFF7AD9, 0.0), 1.0)
    )!.draw(
        fromCenter: NSPoint(x: glyphBox.midX + glyphBox.width * 0.26, y: glyphBox.midY + glyphBox.height * 0.06), radius: 0,
        toCenter: NSPoint(x: glyphBox.midX + glyphBox.width * 0.26, y: glyphBox.midY + glyphBox.height * 0.06), radius: glyphBox.height * 0.62,
        options: []
    )
    NSGradient(colorsAndLocations:
        (color(0x35E0FF, 0.32), 0.0),
        (color(0x35E0FF, 0.0), 1.0)
    )!.draw(
        fromCenter: NSPoint(x: glyphBox.midX - glyphBox.width * 0.30, y: glyphBox.minY + glyphBox.height * 0.34), radius: 0,
        toCenter: NSPoint(x: glyphBox.midX - glyphBox.width * 0.30, y: glyphBox.minY + glyphBox.height * 0.34), radius: glyphBox.height * 0.60,
        options: []
    )

    // 镜面扫光：斜向高光带，玻璃最直观的「液态」信号
    NSGraphicsContext.saveGraphicsState()
    glyphUnion.addClip()
    let glossCtx = NSGraphicsContext.current!.cgContext
    glossCtx.translateBy(x: glyphBox.midX, y: glyphBox.midY)
    glossCtx.rotate(by: -0.42)
    let glossBand = NSRect(
        x: -glyphBox.width * 4,
        y: glyphBox.height * 0.08,
        width: glyphBox.width * 8,
        height: glyphBox.height * 0.34
    )
    NSGradient(colorsAndLocations:
        (NSColor.white.withAlphaComponent(0.0), 0.0),
        (NSColor.white.withAlphaComponent(0.40), 0.40),
        (NSColor.white.withAlphaComponent(0.07), 0.70),
        (NSColor.white.withAlphaComponent(0.0), 1.0)
    )!.draw(in: glossBand, angle: 90)
    NSGraphicsContext.restoreGraphicsState()

    // 顶部受光：只有靠近上缘的一段变亮，避免整块发白
    NSGradient(colorsAndLocations:
        (NSColor.white.withAlphaComponent(0.46), 0.0),
        (NSColor.white.withAlphaComponent(0.0), 0.24)
    )!.draw(in: glyphBox, angle: -90)

    // 湿润感：沿竖笔的椭圆高光，像液体表面被光拉出的一道亮条
    func wetHighlight(center: NSPoint, radius: CGFloat, stretch: CGFloat, tint: NSColor) {
        NSGraphicsContext.saveGraphicsState()
        let ctx = NSGraphicsContext.current!.cgContext
        ctx.translateBy(x: center.x, y: center.y)
        ctx.scaleBy(x: 1, y: stretch)
        NSGradient(colorsAndLocations:
            (tint, 0.0),
            (tint.withAlphaComponent(tint.alphaComponent * 0.35), 0.55),
            (tint.withAlphaComponent(0.0), 1.0)
        )!.draw(fromCenter: .zero, radius: 0, toCenter: .zero, radius: radius, options: [])
        NSGraphicsContext.restoreGraphicsState()
    }

    wetHighlight(
        center: NSPoint(x: left - strokeW * 0.12, y: top - markH * 0.30),
        radius: strokeW * 0.24, stretch: 2.8,
        tint: NSColor.white.withAlphaComponent(0.42)
    )
    wetHighlight(
        center: NSPoint(x: left + markW - strokeW * 0.12, y: top - markH * 0.30),
        radius: strokeW * 0.24, stretch: 2.8,
        tint: NSColor.white.withAlphaComponent(0.38)
    )
    wetHighlight(
        center: NSPoint(x: arrowX - shaftW * 0.12, y: arrowTop - markH * 0.24),
        radius: shaftW * 0.26, stretch: 3.0,
        tint: NSColor.white.withAlphaComponent(0.34)
    )

    // 竖笔顶端与箭头顶端的锐利反光点
    let glints: [(NSPoint, CGFloat)] = [
        (NSPoint(x: left, y: top - strokeW * 0.14), strokeW * 0.30),
        (NSPoint(x: left + markW, y: top - strokeW * 0.14), strokeW * 0.30),
        (NSPoint(x: arrowX, y: arrowTop), headW * 0.26)
    ]
    for (center, radius) in glints {
        NSGradient(colorsAndLocations:
            (NSColor.white.withAlphaComponent(1.0), 0.0),
            (NSColor.white.withAlphaComponent(0.50), 0.38),
            (NSColor.white.withAlphaComponent(0.0), 1.0)
        )!.draw(
            fromCenter: center, radius: 0,
            toCenter: center, radius: radius,
            options: []
        )
    }

    // 底部冷蓝折射：玻璃下缘积聚背景色
    NSGradient(colorsAndLocations:
        (color(0x1F6BFF, 0.34), 0.0),
        (color(0x1F6BFF, 0.0), 1.0)
    )!.draw(
        fromCenter: NSPoint(x: glyphBox.midX, y: glyphBox.minY), radius: 0,
        toCenter: NSPoint(x: glyphBox.midX, y: glyphBox.minY + glyphBox.height * 0.30), radius: glyphBox.height * 0.62,
        options: []
    )

    // 箭头独立着色，做出前后两层玻璃的层次
    NSGraphicsContext.saveGraphicsState()
    arrow.addClip()
    NSGradient(colorsAndLocations:
        (NSColor.white.withAlphaComponent(0.22), 0.0),
        (color(0x6FE4FF, 0.18), 0.55),
        (color(0x2A8CFF, 0.16), 1.0)
    )!.draw(in: arrow.bounds, angle: -90)
    NSGraphicsContext.restoreGraphicsState()

    // 焦散亮斑：光被玻璃汇聚
    NSGradient(colorsAndLocations:
        (NSColor.white.withAlphaComponent(0.24), 0.0),
        (NSColor.white.withAlphaComponent(0.0), 1.0)
    )!.draw(
        fromCenter: NSPoint(x: glyphBox.midX, y: glyphBox.minY + glyphBox.height * 0.16), radius: 0,
        toCenter: NSPoint(x: glyphBox.midX, y: glyphBox.minY + glyphBox.height * 0.16), radius: glyphBox.height * 0.30,
        options: []
    )

    // 底部厚度：向下渐深的冷色，让玻璃有体积
    NSGradient(colorsAndLocations:
        (color(0x0A2A66, 0.0), 0.52),
        (color(0x0A2A66, 0.24), 1.0)
    )!.draw(in: glyphBox, angle: -90)

    NSGraphicsContext.restoreGraphicsState()

    // —— 玻璃边缘：光晕 + 色散 + 白色镜面硬边 ——
    // 字形下方的光池（光穿过玻璃汇聚）
    NSGradient(colorsAndLocations:
        (NSColor.white.withAlphaComponent(0.16), 0.0),
        (NSColor.white.withAlphaComponent(0.0), 1.0)
    )!.draw(
        fromCenter: NSPoint(x: glyphBox.midX, y: glyphBox.minY - glyphBox.height * 0.02), radius: 0,
        toCenter: NSPoint(x: glyphBox.midX, y: glyphBox.minY - glyphBox.height * 0.02), radius: glyphBox.height * 0.44,
        options: []
    )

    // 柔和冷光：玻璃边缘向背景溢出一点亮度
    // 说明：不能对 mStroke 轮廓再次描边（会在 V 形处出现自交尾影），
    // 这里改为「中心线加宽描边 → 挖掉字形本体」，只留下贴合轮廓的外缘。
    func outerRim(shift: CGSize, width: CGFloat, tint: NSColor) {
        NSGraphicsContext.saveGraphicsState()
        let ctx = NSGraphicsContext.current!.cgContext
        ctx.beginTransparencyLayer(auxiliaryInfo: nil)
        ctx.saveGState()
        ctx.translateBy(x: shift.width, y: shift.height)
        ctx.setStrokeColor(tint.cgColor)
        ctx.setLineWidth(width)
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        ctx.addPath(mPath.cgPath)
        ctx.strokePath()
        ctx.restoreGState()
        ctx.setBlendMode(.destinationOut)
        ctx.setFillColor(NSColor.black.cgColor)
        ctx.addPath(mStroke)
        ctx.fillPath()
        ctx.endTransparencyLayer()
        NSGraphicsContext.restoreGraphicsState()
    }

    outerRim(shift: .zero, width: strokeW + 26, tint: NSColor.white.withAlphaComponent(0.20))
    // 色散彩边：青色与品红错位，模拟玻璃折射
    outerRim(shift: CGSize(width: -2.2, height: 2.2), width: strokeW + 7, tint: color(0x35E0FF, 0.55))
    outerRim(shift: CGSize(width: 2.2, height: -2.2), width: strokeW + 7, tint: color(0xFF7AD9, 0.48))
    // 白色硬边：玻璃最亮的镜面轮廓
    outerRim(shift: .zero, width: strokeW + 2.8, tint: NSColor.white.withAlphaComponent(0.94))

    // 内缘亮线：玻璃内侧的第二道高光，并在更内侧补一道暗线做出厚度
    func innerRim(width: CGFloat, cut: CGFloat, tint: NSColor) {
        NSGraphicsContext.saveGraphicsState()
        let ctx = NSGraphicsContext.current!.cgContext
        ctx.beginTransparencyLayer(auxiliaryInfo: nil)
        NSGraphicsContext.saveGraphicsState()
        mOutline.addClip()
        ctx.setStrokeColor(tint.cgColor)
        ctx.setLineWidth(width)
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        ctx.addPath(mPath.cgPath)
        ctx.strokePath()
        NSGraphicsContext.restoreGraphicsState()
        ctx.setBlendMode(.destinationOut)
        ctx.setStrokeColor(NSColor.black.cgColor)
        ctx.setLineWidth(cut)
        ctx.addPath(mPath.cgPath)
        ctx.strokePath()
        ctx.endTransparencyLayer()
        NSGraphicsContext.restoreGraphicsState()
    }

    innerRim(width: strokeW, cut: strokeW - 9, tint: NSColor.white.withAlphaComponent(0.30))
    innerRim(width: strokeW - 8, cut: strokeW - 12, tint: color(0x0B2A66, 0.20))

    // 箭头是简单闭合轮廓，直接描边不会产生尾影
    let arrowSoft = NSBezierPath(cgPath: arrow.cgPath)
    arrowSoft.lineWidth = 9
    arrowSoft.lineJoinStyle = .round
    NSColor.white.withAlphaComponent(0.20).setStroke()
    arrowSoft.stroke()

    let arrowFringe = NSBezierPath(cgPath: arrow.cgPath)
    arrowFringe.transform(using: AffineTransform(translationByX: 2.2, byY: -2.2))
    arrowFringe.lineWidth = 3.2
    arrowFringe.lineJoinStyle = .round
    color(0xFF7AD9, 0.42).setStroke()
    arrowFringe.stroke()

    let arrowRim = NSBezierPath(cgPath: arrow.cgPath)
    arrowRim.lineWidth = 2.6
    arrowRim.lineJoinStyle = .round
    NSColor.white.withAlphaComponent(0.92).setStroke()
    arrowRim.stroke()

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

// 同时输出 1024 PNG，方便预览与 README 使用
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
