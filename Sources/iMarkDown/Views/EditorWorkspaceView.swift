import MarkdownKit
import SwiftUI
import UniformTypeIdentifiers

struct EditorWorkspaceView: View {
    @EnvironmentObject private var state: AppState
    @EnvironmentObject private var settings: AppSettings
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isDropTargeted = false
    @State private var isExportHovered = false

    var body: some View {
        ZStack(alignment: .top) {
            MarkdownWebView(controller: state.editor, bridge: state.bridge)

            // Web 内容铺到标题栏下方，双击会被 WKWebView 当成选词吞掉；
            // 这里只在标题栏高度内铺一层，补回拖拽与双击缩放。
            TitleBarDragArea()
                .frame(maxWidth: .infinity)
                .frame(height: DesignTokens.titleBarHeight)

            // 顶部材质只在正文真正进入覆盖区时出现，且只铺在控件条带内。
            topBarMaterial

            if settings.showsStatusHUD {
                VStack {
                    Spacer()
                    StatusHUDView()
                        .padding(.bottom, 26)
                }
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .overlay(alignment: .topLeading) { compactTitle }
        .overlay(alignment: .topTrailing) { topBarControls }
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
        .animation(.snappy(duration: 0.22), value: settings.showsStatusHUD)
        // 必须放在所有 overlay 之后：否则 overlay 仍按含标题栏安全区的坐标定位，
        // 控件会被顶到安全区下方，看起来像还有一条固定栏。
        .ignoresSafeArea(edges: .top)
    }

    // MARK: - 顶部覆盖层

    /// 材质仅覆盖顶部条带，下缘 16pt 渐隐；正文与侧栏都不会被模糊。
    private var topBarMaterial: some View {
        Group {
            if reduceTransparency {
                Rectangle().fill(solidTopBarColor)
            } else {
                Rectangle().fill(.ultraThinMaterial)
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: DesignTokens.topBarHeight)
        .mask(alignment: .top) {
            LinearGradient(
                stops: [
                    .init(color: .black, location: 0),
                    .init(
                        color: .black,
                        location: 1 - DesignTokens.topBarFade / DesignTokens.topBarHeight
                    ),
                    .init(color: .clear, location: 1)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
        }
        .opacity(state.chromeOverlapped ? 1 : 0)
        .animation(
            reduceMotion ? nil : .easeOut(duration: 0.2),
            value: state.chromeOverlapped
        )
        .allowsHitTesting(false)
    }

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
            .offset(y: state.compactTitleVisible || reduceMotion ? 0 : 2)
            .animation(
                reduceMotion ? nil : .easeOut(duration: 0.2),
                value: state.compactTitleVisible
            )
            .allowsHitTesting(false)
            .accessibilityHidden(!state.compactTitleVisible)
    }

    private var topBarControls: some View {
        HStack(spacing: 10) {
            Picker(
                "视图",
                selection: Binding(
                    get: { state.mode },
                    set: { state.setMode($0) }
                )
            ) {
                ForEach(EditorMode.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 168)
            .help("切换源码 / 分栏 / 预览")

            exportButton

            if state.isExporting {
                ProgressView()
                    .controlSize(.small)
            }
        }
        .frame(height: DesignTokens.topBarHeight)
        .padding(.trailing, DesignTokens.topBarHorizontalInset)
    }

    private var exportButton: some View {
        Menu {
            Button("导出为 HTML…") { state.exportHTML() }
            Button("导出为 PDF…") { state.exportPDF() }
        } label: {
            Image(systemName: "square.and.arrow.up")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(exportIconColor)
                .frame(
                    width: DesignTokens.controlHeight,
                    height: DesignTokens.controlHeight
                )
                .background(
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(exportButtonFill)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .strokeBorder(exportButtonStroke, lineWidth: 0.8)
                )
                .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .onHover { isExportHovered = $0 }
        .help("导出为 HTML / PDF")
    }

    /// 按设计稿做成独立的小圆角玻璃按钮：浅填充 + 发丝描边，
    /// 既不会像材质块那样压过分段控件，也不会淡到看不见。
    private var exportIconColor: Color {
        if colorScheme == .dark {
            return .white.opacity(isExportHovered ? 1 : 0.86)
        }
        return .black.opacity(isExportHovered ? 0.9 : 0.66)
    }

    private var exportButtonFill: Color {
        switch (colorScheme, isExportHovered) {
        case (.dark, true): return .white.opacity(0.18)
        case (.dark, false): return .white.opacity(0.11)
        case (_, true): return .black.opacity(0.10)
        case (_, false): return .black.opacity(0.05)
        }
    }

    private var exportButtonStroke: Color {
        if colorScheme == .dark {
            return .white.opacity(isExportHovered ? 0.18 : 0.12)
        }
        return .black.opacity(isExportHovered ? 0.10 : 0.07)
    }

    // MARK: - 辅助

    private var title: String {
        state.session.isDirty ? state.session.displayName + " •" : state.session.displayName
    }

    private var solidTopBarColor: Color {
        colorScheme == .dark ? Color(hex: 0x212124) : Color(hex: 0xF7F7F8)
    }

    /// 侧栏收起后，窗口左上角被红绿灯与侧栏开关占用，标题必须让开。
    private var compactTitleLeadingInset: CGFloat {
        state.sidebarVisibility == .detailOnly ? 76 : DesignTokens.topBarHorizontalInset
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
