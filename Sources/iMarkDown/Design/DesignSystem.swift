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
    static let cardRadius: CGFloat = 18
    static let hudRadius: CGFloat = 15
    static let contentInset: CGFloat = 18
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

/// 布局背景：用低饱和 MeshGradient 提供可被玻璃折射的内容。
struct WorkspaceBackdrop: View {
    @Environment(\.colorScheme) private var colorScheme

    private let points: [SIMD2<Float>] = [
        SIMD2(0, 0), SIMD2(0.5, 0), SIMD2(1, 0),
        SIMD2(0, 0.55), SIMD2(0.55, 0.45), SIMD2(1, 0.55),
        SIMD2(0, 1), SIMD2(0.5, 1), SIMD2(1, 1)
    ]

    var body: some View {
        MeshGradient(width: 3, height: 3, points: points, colors: colors)
            .overlay(
                LinearGradient(
                    colors: [.black.opacity(colorScheme == .dark ? 0.20 : 0.015), .clear],
                    startPoint: .top,
                    endPoint: .center
                )
            )
            .ignoresSafeArea()
    }

    private var colors: [Color] {
        if colorScheme == .dark {
            return [
                Color(hex: 0x0F1115), Color(hex: 0x121A26), Color(hex: 0x1A1524),
                Color(hex: 0x0E1A1C), Color(hex: 0x101216), Color(hex: 0x141B27),
                Color(hex: 0x1E1913), Color(hex: 0x12151B), Color(hex: 0x0F171C)
            ]
        }
        return [
            Color(hex: 0xEEF2F8), Color(hex: 0xE6EDFB), Color(hex: 0xF3EEF9),
            Color(hex: 0xE9F3F2), Color(hex: 0xF7F8FB), Color(hex: 0xEAF1FD),
            Color(hex: 0xF4EFE9), Color(hex: 0xEFF2F7), Color(hex: 0xE8F0F6)
        ]
    }
}
