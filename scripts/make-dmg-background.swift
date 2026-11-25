import AppKit

// 生成 DMG 打开后的 Finder 背景图（660×392 pt，1x PNG）。
// 布局与 build-dmg.sh 中的图标坐标对应：应用在左、Applications 在右。

let arguments = CommandLine.arguments
guard arguments.count == 2 else {
    FileHandle.standardError.write(Data("用法：swift make-dmg-background.swift <输出.png>\n".utf8))
    exit(2)
}
let outputPath = arguments[1]
let size = NSSize(width: 660, height: 392)

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> NSColor {
    NSColor(
        srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
        green: CGFloat((hex >> 8) & 0xFF) / 255,
        blue: CGFloat(hex & 0xFF) / 255,
        alpha: alpha
    )
}

let image = NSImage(size: size, flipped: true) { rect in
    // 上浅下深的冷灰蓝渐变，避免纯白与系统窗口边框割裂。
    NSGradient(starting: color(0xF8FAFD), ending: color(0xE4EAF4))?
        .draw(in: rect, angle: 270)

    // 应用图标一侧的柔和高光。
    let glowRect = NSRect(x: 30, y: 44, width: 280, height: 300)
    NSGradient(
        colors: [NSColor.white.withAlphaComponent(0.5), NSColor.white.withAlphaComponent(0)]
    )?.draw(in: NSBezierPath(ovalIn: glowRect), relativeCenterPosition: NSPoint(x: -0.15, y: 0))

    // 顶部标题与说明。
    func drawCentered(_ text: String, font: NSFont, color: NSColor, top: CGFloat) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: color,
            .paragraphStyle: paragraph
        ]
        let height = (text as NSString).size(withAttributes: attributes).height
        (text as NSString).draw(
            in: NSRect(x: 0, y: top, width: rect.width, height: height + 2),
            withAttributes: attributes
        )
    }
    drawCentered("iMarkDown", font: .systemFont(ofSize: 16, weight: .semibold),
                 color: color(0x222A38), top: 42)
    drawCentered("将应用拖入 Applications 文件夹即可完成安装",
                 font: .systemFont(ofSize: 11.5), color: color(0x6E7889), top: 68)

    // 两个图标之间的细箭头。
    let arrow = NSBezierPath()
    arrow.move(to: NSPoint(x: 258, y: 204))
    arrow.line(to: NSPoint(x: 396, y: 204))
    arrow.lineWidth = 2.4
    arrow.lineCapStyle = .round
    color(0x97A3B7).setStroke()
    arrow.stroke()

    let head = NSBezierPath()
    head.move(to: NSPoint(x: 384, y: 214))
    head.line(to: NSPoint(x: 398, y: 204))
    head.line(to: NSPoint(x: 384, y: 194))
    head.lineWidth = 2.4
    head.lineCapStyle = .round
    head.lineJoinStyle = .round
    head.stroke()

    return true
}

guard let tiff = image.tiffRepresentation,
      let bitmap = NSBitmapImageRep(data: tiff),
      let png = bitmap.representation(using: .png, properties: [:]) else {
    FileHandle.standardError.write(Data("背景图渲染失败\n".utf8))
    exit(1)
}
try png.write(to: URL(fileURLWithPath: outputPath))
