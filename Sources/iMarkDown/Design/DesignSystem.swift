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
    /// 控件统一胶囊化，品牌图标与内容容器保留各自的普通圆角。
    enum CornerRadius {
        /// CSS 会按控件短边自动收敛该半径，形成与原生 Capsule 一致的胶囊。
        static let capsule: CGFloat = 9999
        static let icon: CGFloat = 8
        static let surface: CGFloat = 12
        static let container: CGFloat = 18

        /// Web 查找控件随编辑器配置同步，CSS 中的数值仅作为页面初始化兜底。
        static var webConfig: [String: Double] {
            ["control": Double(capsule), "surface": Double(surface)]
        }
    }

    /// 背景、描边与焦点框共用形状，圆弧随行高变化，不再单独传入固定半径。
    static var controlShape: Capsule { Capsule(style: .circular) }
    static let rowHorizontalInset: CGFloat = 12
    /// 顶部悬浮控件条带的高度，也是 Web 侧判定重叠的阈值。
    static let topBarHeight: CGFloat = 64
    /// 材质下缘的渐隐高度。
    static let topBarFade: CGFloat = 16
    static let topBarHorizontalInset: CGFloat = 22
    static let controlHeight: CGFloat = 30
    static let sidebarIconSize: CGFloat = 24
    /// 隐藏标题栏后仍然存在的系统标题栏高度，用于补回拖拽 / 双击缩放。
    static let titleBarHeight: CGFloat = 28
    /// 侧栏收起时，紧凑标题要让开红绿灯与系统侧栏开关所占的宽度。
    static let collapsedTitleLeadingInset: CGFloat = 142
    /// 顶部控件行相对 64pt 条带的垂直偏移，让控件中心与标题栏红绿灯对齐（26pt）。
    static let topBarRowOffset: CGFloat = -6
}

/// 原生控制层共用材质；正文与系统滚动条不应用这些修饰器。
enum GlassTone: Equatable {
    case regular
    case clear
    case selection
    case inset
}

extension View {
    func glassChrome<S: InsettableShape>(
        _ tone: GlassTone = .regular,
        in shape: S,
        elevated: Bool = false
    ) -> some View {
        modifier(GlassChromeModifier(tone: tone, shape: shape, elevated: elevated))
    }

    func glassRow(
        isSelected: Bool = false,
        selectionTone: GlassTone = .selection
    ) -> some View {
        modifier(GlassRowModifier(isSelected: isSelected, selectionTone: selectionTone))
    }

    func glassIconControl() -> some View {
        buttonStyle(.glass)
            .buttonBorderShape(.circle)
            .controlSize(.small)
    }
}

private struct GlassChromeModifier<S: InsettableShape>: ViewModifier {
    let tone: GlassTone
    let shape: S
    let elevated: Bool
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    func body(content: Content) -> some View {
        Group {
            if reduceTransparency {
                content.background { shape.fill(solidColor) }
            } else {
                content.glassEffect(material, in: shape)
            }
        }
        .overlay {
            ZStack {
                if tone == .inset {
                    shape.fill(Color.black.opacity(0.015).shadow(.inner(
                        color: .black.opacity(colorScheme == .dark ? 0.20 : 0.10), radius: 3, y: 1
                    )))
                }
                shape.strokeBorder(edge, lineWidth: contrast == .increased ? 1.2 : 0.7)
            }
            .allowsHitTesting(false)
        }
        .shadow(color: .black.opacity(elevated ? (colorScheme == .dark ? 0.26 : 0.12) : 0),
                radius: elevated ? 12 : 0, y: elevated ? 5 : 0)
    }

    private var material: Glass {
        switch tone {
        case .regular: return .regular
        case .clear: return .clear
        case .selection: return .regular.tint(.accentColor.opacity(colorScheme == .dark ? 0.24 : 0.16))
        case .inset: return .clear.tint(.primary.opacity(colorScheme == .dark ? 0.07 : 0.035))
        }
    }

    private var solidColor: Color {
        if tone == .selection {
            return Color(nsColor: .windowBackgroundColor).mix(with: .accentColor, by: 0.18)
        }
        return Color(nsColor: tone == .inset ? .controlBackgroundColor : .windowBackgroundColor)
    }

    private var edge: LinearGradient {
        let strong = contrast == .increased
        let light = Color.white.opacity(strong ? 0.85 : (colorScheme == .dark ? 0.30 : 0.72))
        let shade = Color.primary.opacity(strong ? 0.35 : 0.10)
        return LinearGradient(colors: tone == .inset ? [shade, light.opacity(0.55)] : [light, light.opacity(0.2), shade],
                              startPoint: .topLeading, endPoint: .bottomTrailing)
    }
}

/// 只为选中项与当前悬停项创建玻璃，避免长大纲中的每一行都持有材质层。
private struct GlassRowModifier: ViewModifier {
    let isSelected: Bool
    let selectionTone: GlassTone
    @State private var isHovered = false
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .background {
                if isSelected || (isHovered && isEnabled) {
                    Color.clear
                        .glassChrome(isSelected ? selectionTone : .clear,
                                     in: DesignTokens.controlShape)
                        .allowsHitTesting(false)
                }
            }
            .onHover { isHovered = $0 }
            .animation(reduceMotion ? nil : .easeOut(duration: 0.14), value: isHovered)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: isSelected)
            .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// 系统侧栏负责采样窗口后方环境，玻璃层只承载原生导航。
struct SidebarGlassBackground: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        Group {
            if reduceTransparency {
                Color(nsColor: .windowBackgroundColor)
            } else {
                GlassSurface(cornerRadius: 0,
                             tint: NSColor.controlAccentColor.withAlphaComponent(colorScheme == .dark ? 0.05 : 0.035))
                    .background { SidebarBackdrop() }
            }
        }
        .overlay(alignment: .trailing) {
            Rectangle()
                .fill(LinearGradient(colors: [.white.opacity(colorScheme == .dark ? 0.18 : 0.6), .primary.opacity(0.08)],
                                     startPoint: .top, endPoint: .bottom))
                .frame(width: 0.7)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

private struct SidebarBackdrop: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .sidebar
        view.blendingMode = .behindWindow
        view.state = .followsWindowActiveState
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}

/// 官方 Liquid Glass 的 AppKit 入口。SwiftUI 浮层用 `.glassEffect`，
/// 需要在 NSView 层级上做玻璃背景（并要求自定义圆角 / tint）时走这里。
struct GlassSurface: NSViewRepresentable {
    var cornerRadius: CGFloat = DesignTokens.CornerRadius.surface
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
