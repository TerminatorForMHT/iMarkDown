import AppKit
import MarkdownKit
import SwiftUI
import UniformTypeIdentifiers

struct EditorWorkspaceView: View {
    @EnvironmentObject private var state: AppState
    @EnvironmentObject private var settings: AppSettings
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isDropTargeted = false
    #if IMARKDOWN_UI_CHECK
    @Environment(\.openSettings) private var openSettings
    #endif

    var body: some View {
        ZStack(alignment: .top) {
            MarkdownWebView(controller: state.editor, bridge: state.bridge)

            // Web 内容铺到标题栏下方，双击会被 WKWebView 当成选词吞掉；
            // 这里只在标题栏高度内铺一层，补回拖拽与双击缩放。
            TitleBarDragArea()
                .frame(maxWidth: .infinity)
                .frame(height: DesignTokens.titleBarHeight)

            if settings.showsStatusHUD {
                VStack {
                    Spacer()
                    StatusHUDView()
                        .padding(.bottom, 26)
                }
                .transition(reduceMotion ? .opacity : .move(edge: .bottom).combined(with: .opacity))
            }
        }
        .overlay(alignment: .topLeading) { compactTitle }
        // 系统工具栏上下文决定 macOS 26 控件的玻璃外观与窗口非激活态。
        .toolbar {
            ToolbarSpacer(.flexible, placement: .primaryAction)
            ToolbarItem(placement: .primaryAction) {
                NativeModeControl(mode: Binding(
                    get: { state.mode },
                    set: { state.setMode($0) }
                ), isEnabled: !state.isDocumentOperationInProgress)
                .frame(width: 186, height: 32)
                .help("源码 ⌘1 · 分栏 ⌘2 · 预览 ⌘3")
            }
            ToolbarSpacer(.fixed, placement: .primaryAction)
            ToolbarItem(id: "iMarkDown.export", placement: .primaryAction) {
                exportButton
            }
            ToolbarItem(placement: .status) {
                if state.isExporting {
                    ProgressView().controlSize(.small)
                }
            }
        }
        .overlay {
            if isDropTargeted {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(
                        Color.accentColor,
                        style: StrokeStyle(lineWidth: 2, dash: [7, 5])
                    )
                    .padding(8)
                    .allowsHitTesting(false)
            }
        }
        // 只忽略顶部安全区，让控件条带覆盖到标题栏位置；
        // 左侧必须保留侧栏的安全区内缩，否则正文会横向溢出到侧栏下方被遮挡。
        .onDrop(of: [UTType.fileURL, UTType.image], isTargeted: $isDropTargeted) { providers in
            state.handleDrop(providers)
        }
        .animation(reduceMotion ? nil : .snappy(duration: 0.22), value: settings.showsStatusHUD)
        // 必须放在所有 overlay 之后：否则 overlay 仍按含标题栏安全区的坐标定位，
        // 控件会被顶到安全区下方，看起来像还有一条固定栏。
        .ignoresSafeArea(edges: .top)
        #if IMARKDOWN_UI_CHECK
        .onAppear {
            if ProcessInfo.processInfo.environment["IMARKDOWN_SETTINGS_CHECKS"] == "1" {
                openSettings()
            }
        }
        #endif
    }

    // MARK: - 顶部覆盖层

    /// 大标题移出顶部后才出现，纯前景文字，不做卡片。
    private var compactTitle: some View {
        Text(title)
            .font(.system(size: 13.5, weight: .semibold))
            .foregroundStyle(.primary)
            .lineLimit(1)
            .truncationMode(.middle)
            .frame(maxWidth: 340, alignment: .leading)
            .padding(.leading, compactTitleLeadingInset)
            .frame(height: DesignTokens.topBarHeight, alignment: .leading)
            .opacity(state.compactTitleVisible ? 1 : 0)
            .offset(y: DesignTokens.topBarRowOffset + (state.compactTitleVisible || reduceMotion ? 0 : 2))
            .animation(
                reduceMotion ? nil : .easeOut(duration: 0.2),
                value: state.compactTitleVisible
            )
            .allowsHitTesting(false)
            .accessibilityHidden(!state.compactTitleVisible)
    }

    private var exportButton: some View {
        NativeExportControl(isEnabled: !state.isDocumentOperationInProgress,
                            onHTML: { state.exportHTML() }, onPDF: { state.exportPDF() })
            .frame(width: 32, height: 32)
            .help("导出为 HTML / PDF")
    }

    // MARK: - 辅助

    private var title: String {
        state.session.isDirty ? state.session.displayName + " •" : state.session.displayName
    }

    /// 侧栏收起后，窗口左上角依次是红绿灯和系统自带的侧栏开关（玻璃圆到 131pt），
    /// 紧凑标题与开关之间还要留出 10pt 空隙。
    private var compactTitleLeadingInset: CGFloat {
        state.sidebarVisibility == .detailOnly
            ? DesignTokens.collapsedTitleLeadingInset
            : DesignTokens.topBarHorizontalInset
    }
}

/// 与模式控件使用同一 AppKit 工具栏布局，让系统直接居中图标及绘制玻璃圆形按钮。
private struct NativeExportControl: NSViewRepresentable {
    var isEnabled: Bool
    var onHTML: () -> Void
    var onPDF: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSButton {
        let symbol = NSImage(systemSymbolName: "square.and.arrow.up", accessibilityDescription: "导出文档") ?? NSImage()
        // 独立模板图像不参与工具栏的文字基线排版；绘制保留纵横比及 Retina 分辨率。
        let image = NSImage(size: NSSize(width: 18, height: 20), flipped: false) { rect in
            let size = symbol.size
            guard size.width > 0, size.height > 0 else { return false }
            let scale = min(rect.width / size.width, rect.height / size.height)
            let target = NSRect(x: rect.midX - size.width * scale / 2,
                                y: rect.midY - size.height * scale / 2,
                                width: size.width * scale, height: size.height * scale)
            symbol.draw(in: target)
            return true
        }
        image.isTemplate = true
        let button = NSButton(image: image, target: context.coordinator, action: #selector(Coordinator.openMenu(_:)))
        button.identifier = NSUserInterfaceItemIdentifier("iMarkDown.exportControl")
        button.bezelStyle = .automatic
        button.borderShape = .circle
        button.controlSize = .large
        button.imagePosition = .imageOnly
        button.imageScaling = .scaleNone
        button.setAccessibilityLabel("导出文档")
        button.toolTip = "导出为 HTML / PDF"
        let menu = NSMenu(title: "导出文档")
        menu.autoenablesItems = false
        for (index, title) in ["导出为 HTML…", "导出为 PDF…"].enumerated() {
            let item = NSMenuItem(title: title, action: #selector(Coordinator.export(_:)), keyEquivalent: "")
            item.tag = index
            item.target = context.coordinator
            menu.addItem(item)
        }
        button.menu = menu
        updateNSView(button, context: context)
        return button
    }

    func updateNSView(_ button: NSButton, context: Context) {
        context.coordinator.parent = self
        button.isEnabled = isEnabled
        button.menu?.items.forEach { $0.isEnabled = isEnabled }
    }

    final class Coordinator: NSObject {
        var parent: NativeExportControl
        init(_ parent: NativeExportControl) { self.parent = parent }

        @objc func openMenu(_ button: NSButton) {
            guard parent.isEnabled, let menu = button.menu else { return }
            button.highlight(true)
            defer { button.highlight(false) }
            // 锚定实际按钮的底边，键盘和鼠标激活均使用同一原生菜单。
            let origin = NSPoint(x: button.bounds.minX,
                                 y: button.isFlipped ? button.bounds.maxY : button.bounds.minY)
            menu.popUp(positioning: nil, at: origin, in: button)
        }

        @objc func export(_ item: NSMenuItem) {
            guard parent.isEnabled else { return }
            if item.tag == 0 { parent.onHTML() }
            else if item.tag == 1 { parent.onPDF() }
        }
    }
}

/// 使用工具栏内的 AppKit 胶囊分段控件，选中、焦点和按压绘制均由系统负责。
private struct NativeModeControl: NSViewRepresentable {
    @Binding var mode: EditorMode
    var isEnabled: Bool

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSSegmentedControl {
        let control = NSSegmentedControl(
            labels: EditorMode.allCases.map(\.title),
            trackingMode: .selectOne,
            target: context.coordinator,
            action: #selector(Coordinator.selectMode(_:))
        )
        control.identifier = NSUserInterfaceItemIdentifier("iMarkDown.viewMode")
        control.segmentStyle = .automatic
        control.borderShape = .capsule
        control.controlSize = .large
        control.segmentDistribution = .fillEqually
        control.setAccessibilityLabel("视图模式")
        for (index, item) in EditorMode.allCases.enumerated() {
            control.setToolTip("\(item.title) ⌘\(index + 1)", forSegment: index)
        }
        updateNSView(control, context: context)
        return control
    }

    func updateNSView(_ control: NSSegmentedControl, context: Context) {
        context.coordinator.parent = self
        control.selectedSegment = EditorMode.allCases.firstIndex(of: mode) ?? 0
        control.isEnabled = isEnabled
    }

    final class Coordinator: NSObject {
        var parent: NativeModeControl
        init(_ parent: NativeModeControl) { self.parent = parent }

        @objc func selectMode(_ sender: NSSegmentedControl) {
            guard sender.isEnabled,
                  EditorMode.allCases.indices.contains(sender.selectedSegment) else { return }
            parent.mode = EditorMode.allCases[sender.selectedSegment]
        }
    }
}

/// 标题栏条带：Web 内容铺满到窗口顶部后，双击会被 WKWebView 当作选词吞掉。
/// 用一层透明的 AppKit 视图接管这条 28pt，保证拖动窗口和双击缩放都保持系统行为。
private struct TitleBarDragArea: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { DragView() }

    func updateNSView(_ nsView: NSView, context: Context) {}

    private final class DragView: NSView {
        override var mouseDownCanMoveWindow: Bool { true }

        override func mouseDown(with event: NSEvent) {
            guard event.clickCount == 2 else {
                super.mouseDown(with: event)
                return
            }
            window?.performZoom(nil)
        }
    }
}
