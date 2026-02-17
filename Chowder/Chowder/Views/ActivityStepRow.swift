import SwiftUI

/// A compact inline row showing a completed agent step (tool call or thinking)
/// directly in the chat message list. Muted styling so it doesn't compete with
/// actual message bubbles.
struct ActivityStepRow: View {
    let step: ActivityStep
    var onTap: () -> Void = {}

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: iconName)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.gray)
                .frame(width: 16, alignment: .center)

            Text(step.label)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Color(.secondaryLabel))
                .lineLimit(1)

            Spacer()

            Text(formattedElapsed)
                .font(.system(size: 11, weight: .regular, design: .monospaced))
                .foregroundStyle(Color(.tertiaryLabel))
        }
        .padding(.vertical, 1)
        .padding(.horizontal, 8)
        .contentShape(Rectangle())
        .onTapGesture { onTap() }
    }

    // MARK: - Helpers

    private var iconName: String {
        switch step.status {
        case .failed:    return "xmark.circle"
        case .inProgress: return "circle.dotted"
        case .completed: return step.toolCategory.iconName
        }
    }

    private var iconColor: Color {
        return .gray
    }

    /// Format the elapsed time as a short string: "2s", "1m 23s", etc.
    private var formattedElapsed: String {
        let seconds = Int(step.elapsed)
        if seconds < 60 {
            return "\(seconds)s"
        }
        let minutes = seconds / 60
        let remaining = seconds % 60
        return "\(minutes)m \(remaining)s"
    }
}
