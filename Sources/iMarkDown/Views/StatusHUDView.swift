import SwiftUI

struct StatusHUDView: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        HStack(spacing: 9) {
            Circle()
                .fill(statusTint)
                .frame(width: 6, height: 6)

            Text(state.saveLabel)
                .fontWeight(.medium)

            separator

            Text("\(state.stats.words) 字")
                .contentTransition(.numericText())
            Text("\(state.stats.lines) 行")
                .contentTransition(.numericText())
            Text("约 \(state.stats.readingMinutes) 分钟")
        }
        .font(.system(size: 11, design: .rounded))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 14)
        .frame(height: 30)
        .background(
            GlassSurface(
                cornerRadius: DesignTokens.hudRadius,
                tint: NSColor.controlAccentColor.withAlphaComponent(0.05)
            )
        )
        .overlay(
            Capsule()
                .strokeBorder(Color.white.opacity(0.18), lineWidth: 0.8)
        )
        .shadow(color: .black.opacity(0.16), radius: 12, y: 6)
        .allowsHitTesting(false)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(state.saveLabel)，\(state.stats.words) 字，\(state.stats.lines) 行")
    }

    private var separator: some View {
        Rectangle()
            .fill(Color.secondary.opacity(0.25))
            .frame(width: 1, height: 10)
    }

    private var statusTint: Color {
        switch state.saveStatus {
        case .failed:
            return .red
        case .unsaved:
            return .orange
        case .saving:
            return .blue
        case .saved:
            return .green
        case .idle:
            return .secondary
        }
    }
}
