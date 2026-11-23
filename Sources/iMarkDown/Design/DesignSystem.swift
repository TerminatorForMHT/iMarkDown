import AppKit
import SwiftUI

extension Color {
    init(hex: UInt32) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: 1
        )
    }
}

enum DesignTokens {
    static let hudRadius: CGFloat = 15
    /// 顶部悬浮控件条带的高度，也是 Web 侧判定重叠的阈值。
    static let topBarHeight: CGFloat = 64
    /// 材质下缘的渐隐高度。
    static let topBarFade: CGFloat = 16
    static let topBarHorizontalInset: CGFloat = 22
    static let controlHeight: CGFloat = 30
    /// 隐藏标题栏后仍然存在的系统标题栏高度，用于补回拖拽 / 双击缩放。
    static let titleBarHeight: CGFloat = 28
    /// 侧栏收起时，紧凑标题要让开红绿灯与系统侧栏开关所占的宽度。
    static let collapsedTitleLeadingInset: CGFloat = 142
    /// 顶部控件行相对 64pt 条带的垂直偏移，让控件中心与标题栏红绿灯对齐（26pt）。
    static let topBarRowOffset: CGFloat = -6
}

/// 官方 Liquid Glass 的 AppKit 入口。SwiftUI 浮层用 `.glassEffect`，
/// 需要在 NSView 层级上做玻璃背景（并要求自定义圆角 / tint）时走这里。
struct GlassSurface: NSViewRepresentable {
    var cornerRadius: CGFloat = DesignTokens.hudRadius
    var tint: NSColor = .clear

    func makeNSView(context: Context) -> NSView {
        if #available(macOS 26.0, *) {
            let glass = NSGlassEffectView(frame: .zero)
            glass.style = .regular
            glass.cornerRadius = cornerRadius
            glass.tintColor = tint
            glass.wantsLayer = true
            glass.layer?.masksToBounds = true
            return glass
        }

        let fallback = NSVisualEffectView(frame: .zero)
        fallback.material = .hudWindow
        fallback.blendingMode = .withinWindow
        fallback.state = .active
        fallback.wantsLayer = true
        fallback.layer?.cornerRadius = cornerRadius
        fallback.layer?.masksToBounds = true
        return fallback
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        if #available(macOS 26.0, *), let glass = nsView as? NSGlassEffectView {
            glass.cornerRadius = cornerRadius
            glass.tintColor = tint
        }
    }
}
