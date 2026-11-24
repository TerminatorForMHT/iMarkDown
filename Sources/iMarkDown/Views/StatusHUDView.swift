import SwiftUI

struct StatusHUDView: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 9) {
            Circle()
                .fill(statusTint)
                .frame(width: 6, height: 6)

            Text(state.saveLabel)
                .fontWeight(.medium)

            separator

            Text("\(state.stats.words) 字")
                .monospacedDigit()
                .contentTransition(reduceMotion ? .identity : .numericText())
            Text("\(state.stats.lines) 行")
                .monospacedDigit()
                .contentTransition(reduceMotion ? .identity : .numericText())
        }
        .font(.system(size: 11, design: .rounded))
        .foregroundStyle(.primary)
        .padding(.horizontal, 14)
        .frame(height: DesignTokens.controlHeight)
        .glassChrome(.regular, in: Capsule(), elevated: true)
        .allowsHitTesting(false)
        .opacity(shouldFade ? 0 : 1)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: shouldFade)
        .accessibilityElement(children: .combine)
        .accessibilityHidden(shouldFade)
        .accessibilityLabel("\(state.saveLabel)，\(state.stats.words) 字，\(state.stats.lines) 行")
    }

    private var shouldFade: Bool {
        guard state.isReading else { return false }
        switch state.saveStatus {
        case .saved, .idle: return true
        case .failed, .unsaved, .saving: return false
        }
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
