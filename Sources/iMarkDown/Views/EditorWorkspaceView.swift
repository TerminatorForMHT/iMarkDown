import MarkdownKit
import SwiftUI
import UniformTypeIdentifiers

struct EditorWorkspaceView: View {
    @EnvironmentObject private var state: AppState
    @EnvironmentObject private var settings: AppSettings
    @Environment(\.colorScheme) private var colorScheme
    @State private var isDropTargeted = false

    var body: some View {
        ZStack {
            WorkspaceBackdrop()

            // 卡片背景（含阴影与圆角）放在 WebView 下层。
            // 注意：绝不能把 .shadow / .clipShape 直接作用在承载 WKWebView 的
            // NSViewRepresentable 上——那会触发 SwiftUI 将远程图层栅格化，
            // 导致预览/源码整页空白（WebKit 内容不参与该离屏合成）。
            cardBackground
                .padding(.horizontal, DesignTokens.contentInset)
                .padding(.top, 14)
                .padding(.bottom, DesignTokens.contentInset)

            MarkdownWebView(controller: state.editor, bridge: state.bridge)
                .padding(.horizontal, DesignTokens.contentInset)
                .padding(.top, 14)
                .padding(.bottom, DesignTokens.contentInset)

            if settings.showsStatusHUD {
                VStack {
                    Spacer()
                    StatusHUDView()
                        .padding(.bottom, 30)
                }
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .overlay(alignment: .center) {
            cardBorder
                .padding(.horizontal, DesignTokens.contentInset)
                .padding(.top, 14)
                .padding(.bottom, DesignTokens.contentInset)
        }
        .navigationTitle(title)
        .navigationSubtitle(state.documentSubtitle)
        .toolbar { toolbarContent }
        .onDrop(of: [UTType.fileURL, UTType.image], isTargeted: $isDropTargeted) { providers in
            state.handleDrop(providers)
        }
        .overlay {
            if isDropTargeted {
                RoundedRectangle(cornerRadius: DesignTokens.cardRadius, style: .continuous)
                    .strokeBorder(
                        Color.accentColor,
                        style: StrokeStyle(lineWidth: 2, dash: [7, 5])
                    )
                    .padding(.horizontal, DesignTokens.contentInset)
                    .padding(.top, 14)
                    .padding(.bottom, DesignTokens.contentInset)
                    .allowsHitTesting(false)
            }
        }
        .animation(.snappy(duration: 0.22), value: settings.showsStatusHUD)
    }

    private var title: String {
        state.session.isDirty ? state.session.displayName + " •" : state.session.displayName
    }

    private var cardBackground: some View {
        RoundedRectangle(cornerRadius: DesignTokens.cardRadius, style: .continuous)
            .fill(colorScheme == .dark ? Color(hex: 0x161618) : Color(hex: 0xFFFFFF))
            .shadow(
                color: .black.opacity(colorScheme == .dark ? 0.45 : 0.14),
                radius: 24,
                y: 12
            )
    }

    private var cardBorder: some View {
        RoundedRectangle(cornerRadius: DesignTokens.cardRadius, style: .continuous)
            .strokeBorder(
                Color.white.opacity(colorScheme == .dark ? 0.10 : 0.55),
                lineWidth: 1
            )
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
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

            Menu {
                Button("导出为 HTML…") { state.exportHTML() }
                Button("导出为 PDF…") { state.exportPDF() }
            } label: {
                Label("导出", systemImage: "square.and.arrow.up")
            }
            .help("导出文档")

            if state.isExporting {
                ProgressView()
                    .controlSize(.small)
            }
        }
    }
}
