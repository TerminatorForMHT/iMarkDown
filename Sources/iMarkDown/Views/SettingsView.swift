import MarkdownKit
import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var settings: AppSettings

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
                        Text("\(Int(settings.previewFontSize)) pt")
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
        .frame(width: 470)
        .padding(.top, 4)
    }
}
