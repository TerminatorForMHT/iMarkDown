import AppKit
import MarkdownKit
import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var settings: AppSettings
    @State private var titlebarHeight: CGFloat = 0
    @State private var hasScrolled = false

    var body: some View {
        Form {
            Section("外观") {
                Picker("主题", selection: $settings.appearance) {
                    ForEach(AppearancePreference.allCases) { preference in
                        Text(preference.title).tag(preference)
                    }
                }
                .pickerStyle(.segmented)
            }

            Section("排版") {
                Picker("预览主题", selection: $settings.previewTheme) {
                    ForEach(PreviewTheme.allCases) { theme in
                        Text(theme.title).tag(theme)
                    }
                }
                Text(settings.previewTheme.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("源码字号")
                        Spacer()
                        Text("\(Int(settings.editorFontSize)) pt")
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                    Slider(value: $settings.editorFontSize, in: 11...24, step: 1)
                }

                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("预览字号")
                        Spacer()
                        Text("\(settings.previewFontSize.formatted(.number.precision(.fractionLength(0...1)))) pt")
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                    Slider(value: $settings.previewFontSize, in: 12...26, step: 0.5)
                }

                Button("恢复默认字号") {
                    settings.resetFontSizes()
                }
            }

            Section("行为") {
                Toggle("自动保存已命名文档", isOn: $settings.autoSaveEnabled)
                Toggle("显示浮动状态条", isOn: $settings.showsStatusHUD)
            }

            Section("关于") {
                LabeledContent("版本", value: AppInfo.version)
                LabeledContent("渲染内核", value: "CodeMirror 5 · marked · DOMPurify")
                LabeledContent("界面材质", value: "macOS 26 Liquid Glass")
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        // 滚动视口覆盖标题栏，只有初始内容留出标题栏空间。
        .contentMargins(.top, titlebarHeight, for: .scrollContent)
        .scrollEdgeEffectHidden(true, for: .top)
        .onScrollGeometryChange(for: Bool.self) { geometry in
            geometry.contentOffset.y + geometry.contentInsets.top > 1
        } action: { _, scrolled in
            hasScrolled = scrolled
        }
        .frame(width: 500, height: 620)
        .background {
            Color(nsColor: .windowBackgroundColor).ignoresSafeArea()
            SettingsWindowStyle { titlebarHeight = $0 }
                .frame(width: 0, height: 0)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
        .overlay(alignment: .top) {
            SettingsScrollBackdrop(isVisible: hasScrolled, height: titlebarHeight + 16)
                .frame(height: titlebarHeight + 16)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
        .navigationTitle("设置")
        .toolbarBackground(.hidden, for: .windowToolbar)
        .ignoresSafeArea(edges: .top)
    }
}

/// 原生表单与模糊层在同一个 AppKit 合成树中，采样窗口内正在滚动的内容。
private struct SettingsScrollBackdrop: NSViewRepresentable {
    var isVisible: Bool
    var height: CGFloat

    func makeNSView(context: Context) -> BackdropView {
        let view = BackdropView()
        view.identifier = NSUserInterfaceItemIdentifier("iMarkDown.settingsBackdrop")
        view.material = .headerView
        view.blendingMode = .withinWindow
        view.state = .followsWindowActiveState
        updateNSView(view, context: context)
        return view
    }

    func updateNSView(_ view: BackdropView, context: Context) {
        view.isHidden = !isVisible
        guard view.maskImage?.size.height != height else { return }
        view.maskImage = NSImage(size: NSSize(width: 1, height: height), flipped: false) { rect in
            let fade = min(16, rect.height)
            NSColor.white.setFill()
            NSRect(x: rect.minX, y: rect.minY + fade, width: rect.width, height: rect.height - fade).fill()
            NSGradient(starting: .clear, ending: .white)?.draw(
                in: NSRect(x: rect.minX, y: rect.minY, width: rect.width, height: fade), angle: 90)
            return true
        }
    }

    final class BackdropView: NSVisualEffectView {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}

/// 对齐 editor.css 的 10 pt 轨道、4/6 pt 滑块，仅定制绘制，保留原生拖拽和淡入淡出。
private final class SettingsScroller: NSScroller {
    private var isHovered = false
    private var hoverTrackingArea: NSTrackingArea?

    override class var isCompatibleWithOverlayScrollers: Bool { self == SettingsScroller.self }

    override class func scrollerWidth(for controlSize: NSControl.ControlSize,
                                     scrollerStyle: NSScroller.Style) -> CGFloat { 10 }

    override func updateTrackingAreas() {
        if let hoverTrackingArea { removeTrackingArea(hoverTrackingArea) }
        super.updateTrackingAreas()
        let area = NSTrackingArea(rect: .zero,
                                 options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                 owner: self, userInfo: nil)
        addTrackingArea(area)
        hoverTrackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        isHovered = true
        needsDisplay = true
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        isHovered = false
        needsDisplay = true
    }

    func knobDrawingRect(highlighted: Bool) -> NSRect {
        let knob = rect(for: .knob)
        let width: CGFloat = highlighted ? 6 : 4
        return NSRect(x: bounds.midX - width / 2, y: knob.minY,
                      width: width, height: knob.height)
    }

    override func drawKnob() {
        let highlighted = isHovered || hitPart == .knob
        let knob = knobDrawingRect(highlighted: highlighted)
        guard !knob.isEmpty else { return }
        let alpha: CGFloat = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
            ? (highlighted ? 0.85 : 0.65) : (highlighted ? 0.45 : 0.28)
        NSColor(calibratedRed: 120 / 255, green: 120 / 255, blue: 128 / 255, alpha: alpha).setFill()
        NSBezierPath(roundedRect: knob, xRadius: knob.width / 2, yRadius: knob.width / 2).fill()
    }

    override func drawKnobSlot(in slotRect: NSRect, highlight flag: Bool) {
        // 与主页面一致，轨道透明；AppKit 继续管理滚动条可见性和命中范围。
    }
}

/// 只配置承载设置页面的窗口，不替换窗口代理或影响主窗口关闭保护。
private struct SettingsWindowStyle: NSViewRepresentable {
    var onTitlebarHeightChange: (CGFloat) -> Void

    func makeNSView(context: Context) -> WindowAnchor {
        let view = WindowAnchor()
        view.onTitlebarHeightChange = onTitlebarHeightChange
        return view
    }

    func updateNSView(_ view: WindowAnchor, context: Context) {
        view.onTitlebarHeightChange = onTitlebarHeightChange
        view.applyStyle()
    }

    final class WindowAnchor: NSView {
        var onTitlebarHeightChange: ((CGFloat) -> Void)?
        private var reportedHeight: CGFloat?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            applyStyle()
            // Settings Scene 创建完成后再应用一次，避免系统默认标题栏覆盖配置。
            DispatchQueue.main.async { [weak self] in self?.applyStyle() }
        }

        override func layout() {
            super.layout()
            applyScrollerStyle()
        }

        private func applyScrollerStyle() {
            func findScrollView(_ root: NSView) -> NSScrollView? {
                if let scroll = root as? NSScrollView { return scroll }
                return root.subviews.lazy.compactMap { findScrollView($0) }.first
            }
            guard let scroll = window?.contentView.flatMap({ findScrollView($0) }),
                  let original = scroll.verticalScroller,
                  !(original is SettingsScroller) else { return }
            let scroller = SettingsScroller(frame: original.frame)
            scroller.controlSize = .small
            scroller.scrollerStyle = scroll.scrollerStyle
            scroller.doubleValue = original.doubleValue
            scroller.knobProportion = original.knobProportion
            scroller.isEnabled = original.isEnabled
            scroll.verticalScroller = scroller
            scroll.tile()
        }

        func applyStyle() {
            guard let window else { return }
            window.identifier = NSUserInterfaceItemIdentifier("iMarkDown.settings")
            if !window.styleMask.contains(.fullSizeContentView) {
                window.styleMask.insert(.fullSizeContentView)
            }
            window.titlebarAppearsTransparent = true
            window.titlebarSeparatorStyle = .none
            window.backgroundColor = .windowBackgroundColor
            applyScrollerStyle()
            let height = max(0, window.frame.height - window.contentLayoutRect.height)
            if reportedHeight != height {
                reportedHeight = height
                DispatchQueue.main.async { [weak self] in self?.onTitlebarHeightChange?(height) }
            }
        }
    }
}

#if IMARKDOWN_UI_CHECK
@MainActor
enum SettingsWindowChecks {
    static func run(outputDirectory: URL) async throws {
        var settingsWindow: NSWindow?
        for _ in 0..<100 {
            settingsWindow = NSApp.windows.first {
                $0.identifier?.rawValue == "iMarkDown.settings" && $0.isVisible
            }
            if settingsWindow != nil { break }
            try await Task.sleep(nanoseconds: 30_000_000)
        }
        guard let window = settingsWindow, let frameView = window.contentView?.superview else {
            throw HeaderBackdropChecks.failure("原生 Settings Scene 未打开")
        }
        try await Task.sleep(nanoseconds: 200_000_000)
        try HeaderBackdropChecks.require(window.titlebarAppearsTransparent && window.titlebarSeparatorStyle == .none,
                                         "设置窗口使用透明标题栏，不绘制标题栏分割线")
        try HeaderBackdropChecks.require(window.backgroundColor == .windowBackgroundColor,
                                         "设置窗口标题栏与表单共用系统窗口背景色")
        try HeaderBackdropChecks.require(window.title.contains("设置"), "设置窗口显示中文标题")
        func findScrollView(_ root: NSView) -> NSScrollView? {
            if let scroll = root as? NSScrollView { return scroll }
            return root.subviews.lazy.compactMap { findScrollView($0) }.first
        }
        guard let scroll = window.contentView.flatMap({ findScrollView($0) }) else {
            throw HeaderBackdropChecks.failure("设置表单没有原生滚动视口")
        }
        func checkScroller(_ phase: String) throws {
            guard let scroller = scroll.verticalScroller as? SettingsScroller else {
                throw HeaderBackdropChecks.failure("\(phase)：设置页未安装细窄原生滚动条")
            }
            let normalKnob = scroller.knobDrawingRect(highlighted: false)
            let hoverKnob = scroller.knobDrawingRect(highlighted: true)
            try HeaderBackdropChecks.require(abs(scroller.bounds.width - 10) <= 0.5 &&
                                             normalKnob.width == 4 && hoverKnob.width == 6 &&
                                             normalKnob.midX == scroller.bounds.midX &&
                                             !normalKnob.isEmpty && scroller.bounds.contains(hoverKnob),
                                             "\(phase)：设置滚动条为 10 pt 轨道、4/6 pt 居中滑块，与主页面一致")
            try HeaderBackdropChecks.require(scroller.target != nil && scroller.action != nil &&
                                             scroller.scrollerStyle == scroll.scrollerStyle &&
                                             SettingsScroller.isCompatibleWithOverlayScrollers,
                                             "\(phase)：保留原生滚动动作及系统滚动条样式兼容性")
            print("设置滚动条 \(phase)：轨道=\(scroller.bounds.width)，滑块=\(normalKnob.width)/\(hoverKnob.width)，样式=\(scroll.scrollerStyle.rawValue)")
        }
        try checkScroller("初始布局")
        let scrollRect = scroll.convert(scroll.bounds, to: nil)
        let titlebarHeight = window.frame.height - window.contentLayoutRect.height
        print("设置滚动布局：视口顶端=\(scrollRect.maxY)，标题栏下缘=\(window.contentLayoutRect.maxY)，标题栏高度=\(titlebarHeight)")
        try HeaderBackdropChecks.require(window.styleMask.contains(.fullSizeContentView) &&
                                         scrollRect.maxY > window.contentLayoutRect.maxY + titlebarHeight - 1,
                                         "设置表单视口延伸到标题栏下方，内容可滚入顶部模糊区")
        func findBackdrop(_ root: NSView) -> NSVisualEffectView? {
            if let view = root as? NSVisualEffectView,
               view.identifier?.rawValue == "iMarkDown.settingsBackdrop" { return view }
            return root.subviews.lazy.compactMap { findBackdrop($0) }.first
        }
        guard let backdrop = window.contentView.flatMap({ findBackdrop($0) }) else {
            throw HeaderBackdropChecks.failure("设置窗口缺少原生滚动模糊层")
        }
        try HeaderBackdropChecks.require(backdrop.isHidden && backdrop.hitTest(.zero) == nil,
                                         "设置回到顶部时不加遮盖，模糊层不拦截鼠标")
        let originalOffset = scroll.contentView.bounds.origin
        defer {
            scroll.contentView.scroll(to: originalOffset)
            scroll.reflectScrolledClipView(scroll.contentView)
        }
        let originalAppAppearance = NSApp.appearance
        let originalWindowAppearance = window.appearance
        defer {
            NSApp.appearance = originalAppAppearance
            window.appearance = originalWindowAppearance
        }
        for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", NSAppearance.Name.darkAqua)] {
            NSApp.appearance = NSAppearance(named: appearance)
            window.appearance = nil
            frameView.needsDisplay = true
            try await Task.sleep(nanoseconds: 150_000_000)
            guard let bitmap = frameView.bitmapImageRepForCachingDisplay(in: frameView.bounds) else {
                throw HeaderBackdropChecks.failure("设置窗口渲染快照不可用")
            }
            window.effectiveAppearance.performAsCurrentDrawingAppearance {
                frameView.cacheDisplay(in: frameView.bounds, to: bitmap)
            }
            guard let png = bitmap.representation(using: .png, properties: [:]) else {
                throw HeaderBackdropChecks.failure("设置窗口 PNG 编码失败")
            }
            try png.write(to: outputDirectory.appendingPathComponent("settings-\(name).png"))
            scroll.contentView.scroll(to: NSPoint(x: originalOffset.x, y: originalOffset.y + 100))
            scroll.reflectScrolledClipView(scroll.contentView)
            try await Task.sleep(nanoseconds: 350_000_000)
            try HeaderBackdropChecks.require(scroll.contentView.bounds.origin.y > originalOffset.y + 1,
                                             "\(name)：设置表单实际滚动成功")
            try checkScroller("\(name)：滚动后")
            try HeaderBackdropChecks.require(!backdrop.isHidden && backdrop.material == .headerView &&
                                             backdrop.blendingMode == .withinWindow && backdrop.maskImage != nil,
                                             "\(name)：滚动开启窗口内背景采样模糊，并在底缘渐隐")
            window.effectiveAppearance.performAsCurrentDrawingAppearance {
                frameView.cacheDisplay(in: frameView.bounds, to: bitmap)
            }
            guard let scrolledPNG = bitmap.representation(using: .png, properties: [:]) else {
                throw HeaderBackdropChecks.failure("设置滚动快照编码失败")
            }
            try scrolledPNG.write(to: outputDirectory.appendingPathComponent("settings-\(name)-scrolled.png"))
            scroll.contentView.scroll(to: originalOffset)
            scroll.reflectScrolledClipView(scroll.contentView)
            try await Task.sleep(nanoseconds: 150_000_000)
            try HeaderBackdropChecks.require(backdrop.isHidden, "\(name)：回到顶部后模糊层关闭")
            try checkScroller("\(name)：回到顶部")
        }
        let originalScrollerStyle = scroll.scrollerStyle
        defer {
            scroll.scrollerStyle = originalScrollerStyle
            scroll.tile()
        }
        for style in [NSScroller.Style.overlay, .legacy] {
            scroll.scrollerStyle = style
            scroll.tile()
            try await Task.sleep(nanoseconds: 100_000_000)
            try checkScroller("系统显示样式 \(style.rawValue)")
        }
        print("SETTINGS_WINDOW_CHECK_PASSED：细窄滚动条尺寸及原生动作、设置滚动与顶部模糊开关通过，浅色/深色自身渲染已保存")
    }
}
#endif
