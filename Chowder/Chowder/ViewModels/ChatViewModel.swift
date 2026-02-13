import SwiftUI
import UIKit

@Observable
final class ChatViewModel: ChatServiceDelegate {

    var messages: [Message] = []
    var inputText: String = ""

    // MARK: - Pagination

    /// Number of messages shown from the end of the history.
    var displayLimit: Int = 50
    private let pageSize: Int = 50

    /// The slice of messages currently rendered in the chat view.
    var displayedMessages: [Message] {
        if messages.count <= displayLimit {
            return messages
        }
        return Array(messages.suffix(displayLimit))
    }

    /// Whether there are older messages beyond what's currently displayed.
    var hasEarlierMessages: Bool {
        messages.count > displayLimit
    }

    /// Load the next page of earlier messages.
    func loadEarlierMessages() {
        displayLimit += pageSize
    }
    var isLoading: Bool = false
    var isConnected: Bool = false
    var showSettings: Bool = false
    var debugLog: [String] = []
    var showDebugLog: Bool = false

    // Workspace-synced data from the gateway
    var botIdentity: BotIdentity = LocalStorage.loadBotIdentity()
    var userProfile: UserProfile = LocalStorage.loadUserProfile()

    /// The bot's display name — uses IDENTITY.md name, falls back to "Chowder".
    var botName: String {
        botIdentity.name.isEmpty ? "Chowder" : botIdentity.name
    }

    /// Tracks the agent's current turn activity (thinking, tool calls) for the shimmer display.
    /// Set to a new instance when a turn starts; nil when the turn ends.
    var currentActivity: AgentActivity?

    /// Snapshot of the last completed activity, kept around so the user can still
    /// tap to view it after the shimmer disappears.
    var lastCompletedActivity: AgentActivity?

    /// Controls presentation of the activity detail card.
    var showActivityCard: Bool = false

    private var shimmerStartTime: Date?

    /// Light haptic fired once when the assistant's response starts streaming.
    @ObservationIgnored private let responseHaptic = UIImpactFeedbackGenerator(style: .light)
    @ObservationIgnored private var hasPlayedResponseHaptic = false

    private var chatService: ChatService?

    var isConfigured: Bool {
        ConnectionConfig().isConfigured
    }
    
    // MARK: - History Parsing State
    
    /// Generation counter incremented each time a new message is sent
    /// Used to discard stale history responses from previous runs
    private var currentRunGeneration: Int = 0
    
    /// Timestamp when the current run started - used to filter old history items
    private var currentRunStartTime: Date?
    
    /// Tracks seen thinking items by their thinkingSignature.id to prevent duplicates
    private var seenThinkingIds: Set<String> = []
    
    /// Tracks seen tool calls by their id to prevent duplicates
    private var seenToolCallIds: Set<String> = []
    
    /// Metadata for tool calls, keyed by toolCallId, used to show completion info
    private var toolCallMetadata: [String: ToolCallMeta] = [:]
    
    /// Metadata stored for each tool call to derive completion labels
    struct ToolCallMeta {
        let toolName: String
        let arguments: [String: Any]
        let derivedIntent: String
    }

    // MARK: - Buffered Debug Logging

    /// Buffer for log entries — not observed by SwiftUI, so appends here are free.
    @ObservationIgnored private var logBuffer: [String] = []
    /// Whether a flush is already scheduled.
    @ObservationIgnored private var logFlushScheduled = false
    /// Interval between buffer flushes (seconds).
    @ObservationIgnored private let logFlushInterval: TimeInterval = 0.5

    private func log(_ msg: String) {
        let entry = "[\(Date().formatted(.dateTime.hour().minute().second()))] \(msg)"
        print(entry)
        logBuffer.append(entry)
        scheduleLogFlush()
    }

    /// Schedule a single coalesced flush of buffered log entries to the observable `debugLog`.
    private func scheduleLogFlush() {
        guard !logFlushScheduled else { return }
        logFlushScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + logFlushInterval) { [weak self] in
            self?.flushLogBuffer()
        }
    }

    /// Move all buffered entries into the observable `debugLog` in one batch.
    func flushLogBuffer() {
        logFlushScheduled = false
        guard !logBuffer.isEmpty else { return }
        debugLog.append(contentsOf: logBuffer)
        logBuffer.removeAll()
    }

    // MARK: - Actions

    func connect() {
        log("connect() called")

        // Restore chat history from disk on first launch
        if messages.isEmpty {
            messages = LocalStorage.loadMessages()
            if !messages.isEmpty {
                log("Restored \(messages.count) messages from disk")
            }
        }

        let config = ConnectionConfig()
        log("config — url=\(config.gatewayURL) tokenLen=\(config.token.count) session=\(config.sessionKey) configured=\(config.isConfigured)")
        guard config.isConfigured else {
            log("Not configured — showing settings")
            showSettings = true
            return
        }

        chatService?.disconnect()

        let service = ChatService(
            gatewayURL: config.gatewayURL,
            token: config.token,
            sessionKey: config.sessionKey
        )
        service.delegate = self
        self.chatService = service
        service.connect()
        log("ChatService.connect() called")
    }

    func reconnect() {
        log("reconnect()")
        chatService?.disconnect()
        chatService = nil
        isConnected = false
        connect()
    }

    func send() {
        log("send() — isConnected=\(isConnected) isLoading=\(isLoading)")
        let text = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isLoading else { return }

        hasPlayedResponseHaptic = false
        responseHaptic.prepare()

        messages.append(Message(role: .user, content: text))
        inputText = ""
        isLoading = true

        // Start a fresh activity tracker for this agent turn
        currentActivity = AgentActivity()
        currentActivity?.currentLabel = "Thinking..."
        shimmerStartTime = Date()
        
        // Increment generation counter and capture start time to filter old items
        currentRunGeneration += 1
        currentRunStartTime = Date()
        log("Starting new run generation \(currentRunGeneration) at \(currentRunStartTime!)")
        
        // Clear history parsing state for new run
        seenThinkingIds.removeAll()
        seenToolCallIds.removeAll()
        toolCallMetadata.removeAll()
        log("shimmer started — label=\"Thinking...\"")

        messages.append(Message(role: .assistant, content: ""))

        LocalStorage.saveMessages(messages)

        chatService?.send(text: text)
        log("chatService.send() called")
    }

    func clearMessages() {
        messages.removeAll()
        LocalStorage.deleteMessages()
        log("Chat history cleared")
    }

    // MARK: - ChatServiceDelegate (main chat session)

    func chatServiceDidConnect() {
        log("CONNECTED")
        isConnected = true
        
        // Workspace sync disabled - identity/profile are updated via tool events
        // when the agent writes to IDENTITY.md or USER.md
        log("Using cached identity: \(botIdentity.name)")
    }

    func chatServiceDidDisconnect() {
        log("DISCONNECTED")
        isConnected = false
    }

    func chatServiceDidReceiveDelta(_ text: String) {
        guard let lastIndex = messages.indices.last,
              messages[lastIndex].role == .assistant else { return }
        messages[lastIndex].content += text

        // Light haptic on the first streaming delta of a response
        if !hasPlayedResponseHaptic {
            hasPlayedResponseHaptic = true
            responseHaptic.impactOccurred()
            log("💬 Assistant responding")
            
            // Clear thinking steps immediately when answer starts streaming
            if currentActivity != nil {
                currentActivity?.finishCurrentSteps()
                lastCompletedActivity = currentActivity
                currentActivity = nil
                shimmerStartTime = nil
                log("Cleared activity on first delta")
            }
        }

        // Don't hide the shimmer here — for long agentic tasks the agent alternates
        // between emitting text and using tools. The shimmer and inline steps stay
        // visible until the turn finishes (chatServiceDidFinishMessage).
    }

    func chatServiceDidFinishMessage() {
        log("message.done - isLoading was \(isLoading)")
        
        // Force isLoading false
        isLoading = false
        hasPlayedResponseHaptic = false
        
        log("Set isLoading=false, hasPlayedResponseHaptic=false")

        // Mark all remaining in-progress steps as completed
        currentActivity?.finishCurrentSteps()

        // Preserve the activity for the detail card, then clear the shimmer
        if let activity = currentActivity {
            lastCompletedActivity = activity
            log("Preserved activity with \(activity.steps.count) steps")
        }
        
        // Clear current activity to prevent late history items from appearing
        currentActivity = nil
        shimmerStartTime = nil
        log("Cleared currentActivity for generation \(currentRunGeneration), isLoading=\(isLoading)")

        // If the assistant message is still empty, remove it to avoid a blank bubble
        if let lastIndex = messages.indices.last,
           messages[lastIndex].role == .assistant,
           messages[lastIndex].content.isEmpty {
            messages.remove(at: lastIndex)
            log("Removed empty assistant message bubble")
        }
        
        LocalStorage.saveMessages(messages)
    }

    func chatServiceDidReceiveError(_ error: Error) {
        log("ERROR: \(error.localizedDescription)")
        if let lastIndex = messages.indices.last,
           messages[lastIndex].role == .assistant,
           messages[lastIndex].content.isEmpty {
            messages[lastIndex].content = "Error: \(error.localizedDescription)"
        }
        isLoading = false
        currentActivity = nil
        LocalStorage.saveMessages(messages)
    }

    func chatServiceDidLog(_ message: String) {
        log("WS: \(message)")
    }

    func chatServiceDidReceiveThinkingDelta(_ text: String) {
        log("🧠 Thinking delta: \(text.count) chars")
        
        if currentActivity == nil {
            log("Creating new currentActivity for thinking")
            currentActivity = AgentActivity()
        }
        currentActivity?.thinkingText += text
        currentActivity?.currentLabel = "Thinking..."

        // Add or update the thinking step — if the last step is already a thinking
        // step, append to it; otherwise mark previous steps complete and start a new one.
        if let lastStep = currentActivity?.steps.last, lastStep.type == .thinking, lastStep.status == .inProgress {
            currentActivity?.steps[currentActivity!.steps.count - 1].detail += text
        } else {
            currentActivity?.finishCurrentSteps()
            currentActivity?.steps.append(
                ActivityStep(type: .thinking, label: "Thinking", detail: text)
            )
        }
    }

    func chatServiceDidReceiveToolEvent(name: String, path: String?, args: [String: Any]?) {
        log("🔧 Tool event received: \(name) path: \(path ?? "nil")")
        
        if currentActivity == nil {
            log("Creating new currentActivity for tool event")
            currentActivity = AgentActivity()
        }

        // Mark all previous in-progress steps as completed before adding the new one
        currentActivity?.finishCurrentSteps()

        // Build a human-readable label from the tool name + args
        let label = Self.friendlyLabel(for: name, path: path, args: args)
        let detail = Self.detailString(for: name, path: path, args: args)

        log("Setting shimmer label: '\(label)'")
        currentActivity?.currentLabel = label
        currentActivity?.steps.append(
            ActivityStep(type: .toolCall, label: label, detail: detail)
        )
        log("Activity now has \(currentActivity?.steps.count ?? 0) total steps (\(currentActivity?.completedSteps.count ?? 0) completed)")
    }

    // MARK: - Friendly Tool Labels

    /// Map a raw tool name + args into a short, human-readable status line.
    private static func friendlyLabel(for name: String, path: String?, args: [String: Any]?) -> String {
        let fileName = path.map { ($0 as NSString).lastPathComponent }

        switch name {
        // File tools
        case "write", "apply_patch":
            return "Writing \(fileName ?? "file")..."
        case "read":
            return "Reading \(fileName ?? "file")..."
        case "edit":
            return "Editing \(fileName ?? "file")..."
        case "search":
            if let query = args?["query"] as? String, !query.isEmpty {
                let short = query.count > 30 ? String(query.prefix(30)) + "..." : query
                return "Searching for \"\(short)\"..."
            }
            return "Searching files..."

        // Shell / exec
        case "bash", "exec":
            if let cmd = args?["command"] as? String, !cmd.isEmpty {
                let short = cmd.count > 30 ? String(cmd.prefix(30)) + "..." : cmd
                return "Running: \(short)"
            }
            return "Running a command..."

        // Browser / web
        case "browser", "browser.search", "web", "web.search":
            if let query = args?["query"] as? String, !query.isEmpty {
                let short = query.count > 30 ? String(query.prefix(30)) + "..." : query
                return "Searching the web for \"\(short)\"..."
            }
            if let url = args?["url"] as? String, !url.isEmpty {
                return "Browsing the web..."
            }
            return "Searching the web..."
        case "browser.click":
            return "Navigating a webpage..."
        case "browser.fill":
            return "Filling out a form..."
        case "browser.navigate":
            return "Opening a webpage..."

        // Agent / task tools
        case "llm_task":
            return "Running a sub-task..."
        case "agent_send":
            return "Coordinating with another agent..."
        case "message":
            return "Sending a message..."

        // Session tools
        case "sessions_list", "sessions_read":
            return "Checking sessions..."

        // Canvas
        case "canvas":
            return "Working on canvas..."

        // Fallback
        default:
            if let fileName {
                return "\(name) \(fileName)..."
            }
            return "Using \(name)..."
        }
    }

    /// Build a detail string for the activity card (path, URL, or command).
    private static func detailString(for name: String, path: String?, args: [String: Any]?) -> String {
        if let path, !path.isEmpty { return path }
        if let url = args?["url"] as? String, !url.isEmpty { return url }
        if let query = args?["query"] as? String, !query.isEmpty { return query }
        if let cmd = args?["command"] as? String, !cmd.isEmpty { return cmd }
        return ""
    }

    func chatServiceDidUpdateBotIdentity(_ identity: BotIdentity) {
        log("Bot identity updated via tool event — name=\(identity.name)")
        self.botIdentity = identity
        LocalStorage.saveBotIdentity(identity)
    }

    func chatServiceDidUpdateUserProfile(_ profile: UserProfile) {
        log("User profile updated via tool event — name=\(profile.name)")
        self.userProfile = profile
        LocalStorage.saveUserProfile(profile)
    }

    func chatServiceDidReceiveHistoryMessages(_ messages: [[String: Any]]) {
        log("Processing \(messages.count) new history items for generation \(currentRunGeneration)")
        
        // Discard late-arriving history from previous runs
        guard currentActivity != nil else {
            log("⚠️ No current activity - discarding stale history from previous run")
            return
        }
        
        for item in messages {
            processHistoryItem(item)
        }
    }

    /// Parse a single history item and update activity
    private func processHistoryItem(_ item: [String: Any]) {
        guard let role = item["role"] as? String else {
            log("⚠️ History item missing 'role' field, keys: \(Array(item.keys))")
            return
        }
        
        // Filter out items from before this run started (with 10 second buffer for clock skew)
        if let startTime = currentRunStartTime,
           let timestampMs = item["timestamp"] as? Double {
            let itemDate = Date(timeIntervalSince1970: timestampMs / 1000.0)
            // Allow items up to 10 seconds before run start (accounts for clock skew)
            let bufferTime = startTime.addingTimeInterval(-10)
            if itemDate < bufferTime {
                log("⏰ Skipping old item: itemDate=\(itemDate) bufferTime=\(bufferTime)")
                return
            }
        }
        
        log("📋 Processing history item: role=\(role)")
        
        switch role {
        case "assistant":
            // Check for error messages from the gateway/provider
            if let errorMessage = item["errorMessage"] as? String, !errorMessage.isEmpty {
                log("❌ History: assistant error - \(errorMessage)")
                // Show error in the chat if the current response is empty
                if let lastIndex = messages.indices.last,
                   messages[lastIndex].role == .assistant,
                   messages[lastIndex].content.isEmpty {
                    messages[lastIndex].content = "Error: \(errorMessage)"
                    LocalStorage.saveMessages(messages)
                }
                return
            }
            
            // Assistant messages contain content arrays with thinking and toolCall items
            if let contentArray = item["content"] as? [[String: Any]] {
                log("📝 Assistant message with \(contentArray.count) content items")
                for contentItem in contentArray {
                    processAssistantContentItem(contentItem)
                }
            }
            
        case "toolResult":
            // Tool completion - look up metadata and show completion line
            processToolResultItem(item)
            
        case "user":
            // User messages - we already have these in our local message list
            // Skip silently
            break
            
        default:
            log("⚠️ History: unknown role '\(role)' - item keys: \(Array(item.keys))")
            break
        }
    }
    
    /// Process individual content items from assistant messages (thinking, toolCall)
    private func processAssistantContentItem(_ contentItem: [String: Any]) {
        guard let type = contentItem["type"] as? String else {
            log("⚠️ Content item missing 'type' field, keys: \(Array(contentItem.keys))")
            return
        }
        
        log("🔍 Content item type: \(type)")
        
        switch type {
        case "thinking":
            processThinkingContent(contentItem)
            
        case "toolCall":
            processToolCallContent(contentItem)
            
        default:
            // text, image, etc - ignore for activity tracking
            log("⚠️ Skipping content type: \(type)")
            break
        }
    }
    
    /// Process thinking content items
    private func processThinkingContent(_ contentItem: [String: Any]) {
        log("🧠 processThinkingContent called")
        guard let thinking = contentItem["thinking"] as? String else {
            log("⚠️ No 'thinking' field in content item")
            return
        }
        
        log("🧠 Raw thinking text: \(thinking)")
        
        // Strip markdown ** and trim
        let cleanText = thinking
            .replacingOccurrences(of: "**", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        
        guard !cleanText.isEmpty else {
            log("⚠️ Clean thinking text is empty")
            return
        }
        
        log("🧠 Clean thinking text: \(cleanText)")
        
        // Dedupe by thinkingSignature.id if available, else use hash
        var thinkingId: String?
        if let sigString = contentItem["thinkingSignature"] as? String,
           let sigData = sigString.data(using: .utf8),
           let sig = try? JSONSerialization.jsonObject(with: sigData) as? [String: Any],
           let id = sig["id"] as? String {
            thinkingId = id
            log("🧠 Extracted thinkingId from signature: \(id)")
        } else if let sig = contentItem["thinkingSignature"] as? [String: Any],
                  let id = sig["id"] as? String {
            thinkingId = id
            log("🧠 Extracted thinkingId from dict: \(id)")
        } else {
            thinkingId = String(cleanText.hashValue)
            log("🧠 Using hash as thinkingId: \(thinkingId!)")
        }
        
        if let id = thinkingId, !seenThinkingIds.contains(id) {
            seenThinkingIds.insert(id)
            log("💭 Thinking: \(cleanText)")
            
            // Show as one-line progress
            currentActivity?.currentLabel = cleanText + "..."
            currentActivity?.steps.append(
                ActivityStep(type: .thinking, label: cleanText, detail: "")
            )
        } else {
            log("⚠️ Thinking already seen, skipping: \(thinkingId ?? "nil")")
        }
    }
    
    /// Process toolCall content items
    private func processToolCallContent(_ contentItem: [String: Any]) {
        log("🔧 processToolCallContent called")
        guard let toolCallId = contentItem["id"] as? String,
              let toolName = contentItem["name"] as? String else {
            log("⚠️ Missing id or name in toolCall content: \(Array(contentItem.keys))")
            return
        }
        
        log("🔧 Tool call id=\(toolCallId) name=\(toolName)")
        
        // Skip if already seen
        guard !seenToolCallIds.contains(toolCallId) else {
            log("⚠️ Tool call already seen, skipping")
            return
        }
        seenToolCallIds.insert(toolCallId)
        
        let arguments = contentItem["arguments"] as? [String: Any] ?? [:]
        
        // Derive intent from tool call
        let intent = deriveIntentFromToolCall(name: toolName, arguments: arguments)
        
        // Store metadata for later use when toolResult arrives
        toolCallMetadata[toolCallId] = ToolCallMeta(
            toolName: toolName,
            arguments: arguments,
            derivedIntent: intent
        )
        
        log("🔧 Tool call: \(intent)")
        
        // Show intent as progress
        currentActivity?.finishCurrentSteps()
        currentActivity?.currentLabel = intent
        currentActivity?.steps.append(
            ActivityStep(type: .toolCall, label: intent, detail: "")
        )
    }
    
    /// Process toolResult items to show completion
    private func processToolResultItem(_ item: [String: Any]) {
        guard let toolCallId = item["toolCallId"] as? String else {
            return
        }
        
        // Skip if already processed
        guard !seenToolCallIds.contains(toolCallId) else {
            return
        }
        seenToolCallIds.insert(toolCallId)
        
        let details = item["details"] as? [String: Any]
        let duration = details?["durationMs"] as? Int ?? 0
        let exitCode = details?["exitCode"] as? Int ?? 0
        let isError = item["isError"] as? Bool ?? false
        let toolName = item["toolName"] as? String ?? "Tool"
        
        // Build completion label
        let completionLabel: String
        if isError || exitCode != 0 {
            completionLabel = "Command failed"
        } else if let meta = toolCallMetadata[toolCallId] {
            // Use the intent we derived earlier
            let baseIntent = meta.derivedIntent.replacingOccurrences(of: "...", with: "")
            completionLabel = "\(baseIntent) (\(duration)ms)"
        } else {
            completionLabel = "\(toolName) completed (\(duration)ms)"
        }
        
        log("✅ Tool result: \(completionLabel)")
        
        // Mark previous step as completed and add completion
        currentActivity?.finishCurrentSteps()
        currentActivity?.steps.append(
            ActivityStep(type: .toolCall, label: completionLabel, detail: "", status: .completed)
        )
    }

    /// Derive a user-friendly intent description from a tool call
    private func deriveIntentFromToolCall(name: String, arguments: [String: Any]) -> String {
        switch name {
        case "exec", "bash":
            if let command = arguments["command"] as? String {
                // Check for file operations with output redirection
                if let filename = extractFilenameFromRedirect(command) {
                    if command.contains("cat ") && command.contains(">>") {
                        return "Appending to \(filename)..."
                    } else if command.contains(">>") {
                        return "Updating \(filename)..."
                    } else if command.contains(">") {
                        return "Writing \(filename)..."
                    }
                }
                
                // Check for other common commands
                if command.contains("curl") || command.contains("wget") {
                    return "Fetching data..."
                }
                if command.contains("git") {
                    return "Running git command..."
                }
                
                // Generic fallback
                return "Running a command..."
            }
            
        case "read", "Read":
            if let path = arguments["path"] as? String {
                let filename = (path as NSString).lastPathComponent
                return "Reading \(filename)..."
            }
            return "Reading file..."
            
        case "write", "Write":
            if let path = arguments["path"] as? String {
                let filename = (path as NSString).lastPathComponent
                return "Writing \(filename)..."
            }
            return "Writing file..."
            
        case "browser", "web":
            if let query = arguments["query"] as? String {
                return "Searching for \(query)..."
            }
            if let url = arguments["url"] as? String {
                return "Opening \(url)..."
            }
            return "Using browser..."
            
        default:
            return "Using \(name)..."
        }
        
        return "Using \(name)..."
    }
    
    /// Extract filename from shell redirect (>> or >)
    private func extractFilenameFromRedirect(_ command: String) -> String? {
        let patterns = [#">>\s*([^\s\n]+)"#, #">\s*([^\s\n]+)"#]
        for pattern in patterns {
            if let regex = try? NSRegularExpression(pattern: pattern),
               let match = regex.firstMatch(in: command, range: NSRange(command.startIndex..., in: command)),
               let range = Range(match.range(at: 1), in: command) {
                let filename = String(command[range])
                // Return just the filename, not the full path
                return (filename as NSString).lastPathComponent
            }
        }
        return nil
    }
    
    /// Extract content from history item (handles various formats)
    private func extractContent(from item: [String: Any]) -> String? {
        if let content = item["content"] as? String {
            return content
        }
        if let text = item["text"] as? String {
            return text
        }
        // Handle structured content blocks
        if let blocks = item["content"] as? [[String: Any]] {
            let texts = blocks.compactMap { block -> String? in
                guard block["type"] as? String == "text" else { return nil }
                return block["text"] as? String
            }
            return texts.joined()
        }
        return nil
    }

    // MARK: - Workspace Data Management

    /// Save workspace data to local cache (used by Settings save).
    func saveWorkspaceData(identity: BotIdentity, profile: UserProfile) {
        self.botIdentity = identity
        self.userProfile = profile
        LocalStorage.saveBotIdentity(identity)
        LocalStorage.saveUserProfile(profile)
        log("Settings saved to local cache")
    }
}
