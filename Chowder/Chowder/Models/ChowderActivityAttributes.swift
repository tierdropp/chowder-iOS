import ActivityKit
import Foundation

/// ActivityAttributes for the agent thinking steps Live Activity.
/// This file must be added to both the main app target and the widget extension target.
struct ChowderActivityAttributes: ActivityAttributes {
    /// Static context set when the activity starts (does not change).
    var agentName: String
    var userTask: String

    /// Dynamic state that updates as the agent works.
    struct ContentState: Codable, Hashable {
        /// Short subject line summarizing the task (latched from first thinking summary).
        var subject: String?
        /// The latest intent -- shown in the footer.
        var currentIntent: String
        /// SF Symbol name for the current intent's tool category.
        var currentIntentIcon: String?
        /// The previous intent -- shown as the top card.
        var previousIntent: String?
        /// The 2nd most previous intent -- shown as the card behind.
        var secondPreviousIntent: String?
        /// When the current intent started -- used for the live timer.
        var intentStartDate: Date
        /// When the current intent ended
        var intentEndDate: Date?
        /// Total step number (completed + current).
        var stepNumber: Int
        /// Formatted cost string (e.g. "$0.49"), nil until first usage event.
        var costTotal: String?
        /// Whether the agent has finished and the activity should dismiss.
        var isFinished: Bool {
            intentEndDate != nil
        }
    }
}

// MARK: - Preview Data

extension ChowderActivityAttributes {
    static var preview: ChowderActivityAttributes {
        ChowderActivityAttributes(
            agentName: "OddJob",
            userTask: "Can you help me book trains for a trip to Margate on the 28th?"
        )
    }
}

extension ChowderActivityAttributes.ContentState {
    static var inProgress: ChowderActivityAttributes.ContentState {
        ChowderActivityAttributes.ContentState(
            subject: "Train to Margate",
            currentIntent: "Searching available trains",
            currentIntentIcon: "magnifyingglass",
            previousIntent: "Reading project files",
            secondPreviousIntent: "Identifying dependencies",
            intentStartDate: Date(),
            stepNumber: 3,
            costTotal: "$0.49"
        )
    }

    static var finished: ChowderActivityAttributes.ContentState {
        ChowderActivityAttributes.ContentState(
            subject: "Your train to Margate has been booked.",
            currentIntent: "Complete",
            previousIntent: nil,
            secondPreviousIntent: nil,
            intentStartDate: startDate,
            intentEndDate: startDate.addingTimeInterval(38),
            stepNumber: 7,
            costTotal: "$1.23"
        )
    }

    // MARK: - Progressive States (for cycling through)
    
    static var startDate: Date = .now

    static var step1: ChowderActivityAttributes.ContentState {
        ChowderActivityAttributes.ContentState(
            subject: "Train to Margate",
            currentIntent: "Searched trains from London to Margate on Feb 28",
            previousIntent: nil,
            secondPreviousIntent: nil,
            intentStartDate: startDate,
            stepNumber: 1,
            costTotal: nil,
        )
    }

    static var step2: ChowderActivityAttributes.ContentState {
        ChowderActivityAttributes.ContentState(
            subject: "Train to Margate",
            currentIntent: "Comparing options…",
            previousIntent: "Searched trains from London to Margate on Feb 28",
            secondPreviousIntent: nil,
            intentStartDate: startDate,
            stepNumber: 2,
            costTotal: "$0.12",
        )
    }

    static var step3: ChowderActivityAttributes.ContentState {
        ChowderActivityAttributes.ContentState(
            subject: "Train to Margate",
            currentIntent: "Evaluating 10:15 departure…",
            currentIntentIcon: "clock",
            previousIntent: "Compared departure times and prices",
            secondPreviousIntent: "Searched trains from London to Margate on Feb 28",
            intentStartDate: startDate,
            stepNumber: 3,
            costTotal: "$0.34",
        )
    }

    static var step4: ChowderActivityAttributes.ContentState {
        ChowderActivityAttributes.ContentState(
            subject: "Train to Margate",
            currentIntent: "Entering passenger details…",
            currentIntentIcon: "person",
            previousIntent: "Picked the 10:15 departure—best price!",
            secondPreviousIntent: "Compared departure times and prices",
            intentStartDate: startDate,
            stepNumber: 4,
            costTotal: "$0.56",
        )
    }

    static var step5: ChowderActivityAttributes.ContentState {
        ChowderActivityAttributes.ContentState(
            subject: "Train to Margate",
            currentIntent: "Making payment…",
            currentIntentIcon: "dollarsign",
            previousIntent: "Entered passenger details",
            secondPreviousIntent: "Picked the 10:15 departure—best price!",
            intentStartDate: startDate,
            stepNumber: 5,
            costTotal: "$0.78",
        )
    }
    
    static var step6: ChowderActivityAttributes.ContentState {
        ChowderActivityAttributes.ContentState(
            subject: "Train to Margate",
            currentIntent: "Confirming booking…",
            currentIntentIcon: "receipt",
            previousIntent: "Made payment of $34",
            secondPreviousIntent: "Entered passenger details",
            intentStartDate: startDate,
            stepNumber: 6,
            costTotal: "$1.20",
        )
    }
}
