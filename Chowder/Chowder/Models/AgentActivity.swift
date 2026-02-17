import Foundation

/// Category of tool being used — drives the icon shown in the activity row.
enum ToolCategory: String {
    case thinking       // Internal reasoning
    case terminal       // exec, bash, shell commands
    case browser        // agent-browser, web browsing
    case network        // curl, wget, http fetch
    case fileSystem     // file read/write, fs operations
    case search         // search, vector lookup
    case generic        // fallback for unknown tools

    /// SF Symbol name for this category.
    var iconName: String {
        switch self {
        case .thinking:   return "arrow.turn.down.right"
        case .terminal:   return "terminal"
        case .browser:    return "globe"
        case .network:    return "arrow.down.circle"
        case .fileSystem: return "doc"
        case .search:     return "magnifyingglass"
        case .generic:    return "gearshape"
        }
    }
}

/// Represents one step the agent performed during a turn.
struct ActivityStep: Identifiable {
    let id = UUID()
    let timestamp = Date()
    let type: StepType
    let label: String            // "Thinking", "Reading IDENTITY.md...", etc.
    var detail: String            // Full thinking text or tool path/args summary
    var status: Status = .inProgress
    var completedAt: Date?       // Set when status changes to .completed
    var toolCategory: ToolCategory = .generic  // Category for icon selection

    enum StepType {
        case thinking
        case toolCall
    }

    enum Status {
        case inProgress
        case completed
        case failed
    }

    /// Elapsed time for this step:
    /// - For completed steps: duration from start to completion
    /// - For in-progress steps: duration from start to now
    var elapsed: TimeInterval {
        if let completedAt {
            return completedAt.timeIntervalSince(timestamp)
        }
        return Date().timeIntervalSince(timestamp)
    }
}

/// Tracks all activity (thinking + tool calls) for a single agent turn.
/// Ephemeral — not persisted to disk.
struct AgentActivity {
    /// The label currently shown on the shimmer line.
    var currentLabel: String = ""

    /// Accumulated full thinking content from the turn.
    var thinkingText: String = ""

    /// Ordered history of all steps for the detail card.
    var steps: [ActivityStep] = []

    /// All steps that have finished (for inline rendering in the chat).
    var completedSteps: [ActivityStep] {
        steps.filter { $0.status == .completed }
    }

    /// Mark all in-progress steps as completed (used when a new step starts or the turn ends).
    mutating func finishCurrentSteps() {
        let now = Date()
        for i in steps.indices where steps[i].status == .inProgress {
            steps[i].status = .completed
            steps[i].completedAt = now
        }
    }
}
