import ActivityKit
import Foundation

/// Manages the Live Activity that shows agent thinking steps on the Lock Screen.
final class LiveActivityManager: @unchecked Sendable {

    static let shared = LiveActivityManager()

    private var currentActivity: Activity<ChowderActivityAttributes>?
    private var activityStartDate: Date = Date()

    private var pendingContent: ActivityContent<ChowderActivityAttributes.ContentState>?
    private var debounceTimer: Timer?
    private let debounceInterval: TimeInterval = 1.0
    private var lastStepNumber: Int = 0
    private var lastCostTotal: String?
    private var demoTask: Task<Void, Never>?

    private init() {}

    // MARK: - Public API

    /// Start a new Live Activity when the user sends a message.
    /// - Parameters:
    ///   - agentName: The bot/agent display name.
    ///   - userTask: The message the user sent (truncated for display).
    ///   - subject: Optional AI-generated subject to display immediately.
    func startActivity(agentName: String, userTask: String, subject: String? = nil) {
        if currentActivity != nil {
            endActivity()
        }

        activityStartDate = Date()
        lastStepNumber = 0
        lastCostTotal = nil

        guard ActivityAuthorizationInfo().areActivitiesEnabled else {
            print("⚡ Live Activities not enabled — skipping")
            return
        }

        let attributes = ChowderActivityAttributes(
            agentName: agentName,
            userTask: userTask
        )
        let initialState = ChowderActivityAttributes.ContentState(
            subject: subject,
            currentIntent: "Thinking...",
            previousIntent: nil,
            secondPreviousIntent: nil,
            intentStartDate: activityStartDate,
            stepNumber: 1,
            costTotal: nil
        )
        let content = ActivityContent(state: initialState, staleDate: nil)

        do {
            currentActivity = try Activity.request(
                attributes: attributes,
                content: content,
                pushType: nil
            )
            print("⚡ Live Activity started: \(currentActivity?.id ?? "?")")
        } catch {
            print("⚡ Failed to start Live Activity: \(error.localizedDescription)")
        }
    }

    /// Update the Live Activity with full state from the caller.
    /// This is the primary update method used by ChatViewModel which manages its own state.
    /// - Parameters:
    ///   - subject: Subject line for the activity (AI-generated or latched from first intent).
    ///   - currentIntent: The current step label shown at the bottom.
    ///   - previousIntent: The most recent completed intent (yellow arrow).
    ///   - secondPreviousIntent: The 2nd most recent intent (grey, fading out).
    ///   - stepNumber: The total step count.
    ///   - costTotal: Formatted cost string (e.g. "$0.049").
    ///   - isAISubject: Whether the subject was AI-generated (for potential future use).
    func update(
        subject: String?,
        currentIntent: String,
        currentIntentIcon: String? = nil,
        previousIntent: String?,
        secondPreviousIntent: String?,
        stepNumber: Int,
        costTotal: String?,
        isAISubject: Bool = false
    ) {
        guard currentActivity != nil else { return }

        lastStepNumber = stepNumber
        lastCostTotal = costTotal

        let state = ChowderActivityAttributes.ContentState(
            subject: subject,
            currentIntent: currentIntent,
            currentIntentIcon: currentIntentIcon,
            previousIntent: previousIntent,
            secondPreviousIntent: secondPreviousIntent,
            intentStartDate: activityStartDate,
            stepNumber: stepNumber,
            costTotal: costTotal
        )
        pendingContent = ActivityContent(state: state, staleDate: nil)

        debounceTimer?.invalidate()
        debounceTimer = Timer.scheduledTimer(withTimeInterval: debounceInterval, repeats: false) { [weak self] _ in
            self?.flushPendingUpdate()
        }
    }

    private func flushPendingUpdate() {
        guard let activity = currentActivity, let content = pendingContent else { return }
        pendingContent = nil

        Task {
            await activity.update(content)
        }
    }

    /// Convenience method to update with just a new intent string.
    /// Shifts intents internally - use `update(...)` for full control.
    func updateIntent(_ intent: String) {
        guard currentActivity != nil else { return }
        // This is a simplified update - ChatViewModel manages full state
        update(
            subject: nil,
            currentIntent: intent,
            previousIntent: nil,
            secondPreviousIntent: nil,
            stepNumber: 1,
            costTotal: nil
        )
    }

    /// End the Live Activity. Shows a brief "Done" state before dismissing.
    /// - Parameter completionSummary: Optional completion message to display (e.g. "Your tickets have been booked").
    func endActivity(completionSummary: String? = nil) {
        demoTask?.cancel()
        demoTask = nil

        guard let activity = currentActivity else { return }
        debounceTimer?.invalidate()
        debounceTimer = nil
        pendingContent = nil
        currentActivity = nil

        let finalState = ChowderActivityAttributes.ContentState(
            subject: completionSummary,
            currentIntent: "Complete",
            previousIntent: nil,
            secondPreviousIntent: nil,
            intentStartDate: activityStartDate,
            intentEndDate: .now,
            stepNumber: lastStepNumber,
            costTotal: lastCostTotal
        )
        let content = ActivityContent(state: finalState, staleDate: nil)

        Task {
            await activity.end(content, dismissalPolicy: .after(.now + 8))
            print("⚡ Live Activity ended")
        }
    }

    // MARK: - Demo Mode

    /// Starts a demo Live Activity that cycles through all preview steps.
    /// Holds the initial step for 5 seconds, then advances every 3 seconds until finished.
    func startDemo() {
        demoTask?.cancel()

        if currentActivity != nil {
            endActivity()
        }

        guard ActivityAuthorizationInfo().areActivitiesEnabled else {
            print("⚡ Live Activities not enabled — skipping demo")
            return
        }

        let attributes = ChowderActivityAttributes.preview
        let demoStart = Date()
        let initialContent = ActivityContent(
            state: ChowderActivityAttributes.ContentState.step1,
            staleDate: nil
        )

        do {
            currentActivity = try Activity.request(
                attributes: attributes,
                content: initialContent,
                pushType: nil
            )
            print("⚡ Demo Live Activity started")
        } catch {
            print("⚡ Failed to start demo Live Activity: \(error.localizedDescription)")
            return
        }

        demoTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled else { return }

            let steps: [ChowderActivityAttributes.ContentState] = [.step2, .step3, .step4, .step5, .step6]
            for step in steps {
                guard let activity = self?.currentActivity, !Task.isCancelled else { return }
                await activity.update(ActivityContent(state: step, staleDate: nil))
                try? await Task.sleep(for: .seconds(3))
                guard !Task.isCancelled else { return }
            }

            guard let activity = self?.currentActivity, !Task.isCancelled else { return }
            self?.currentActivity = nil

            let finishedState = ChowderActivityAttributes.ContentState.finished
            await activity.end(
                ActivityContent(state: finishedState, staleDate: nil),
                dismissalPolicy: .after(.now + 8)
            )
            print("⚡ Demo Live Activity finished")
        }
    }
}
