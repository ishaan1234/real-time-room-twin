import Combine
import ElevenLabs
import Foundation

/// A spoken conversation with RoomTwin's agent on ElevenLabs, set up by
/// Voice/setup_agent.py. ElevenLabs listens, its LLM decides what the user
/// wants, the app carries it out through `perform`, and the agent answers
/// out loud. The phone only has the agent's ID, from Library/voice-agent.json;
/// the API key stays on the Mac.
@MainActor
final class VoiceAgent: ObservableObject {
    enum Status: Equatable {
        case off, connecting, listening, thinking, speaking
    }

    /// A tool call the app couldn't carry out; the agent is told why.
    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    struct TranscriptEntry: Codable, Identifiable {
        enum Speaker: String, Codable {
            case user
            case assistant
        }

        let id: UUID
        let date: Date
        let speaker: Speaker
        let text: String
    }

    @Published private(set) var status = Status.off
    /// The last thing the user said.
    @Published private(set) var heard: String?
    /// The agent's last answer.
    @Published private(set) var caption: String?
    @Published var errorMessage: String?
    /// A free, on-device transcript. It is persisted as JSON so the History
    /// sheet can be closed or the app relaunched before the user exports it.
    @Published private(set) var transcript: [TranscriptEntry] = []

    /// Carries out a tool call: its name and parameters in, a short account
    /// of what happened out, for the agent to talk about. Throws to report
    /// why it couldn't; the error's description goes to the agent.
    var perform: ((String, [String: Any]) async throws -> String)?
    /// The room as it is now, in words for the agent, e.g. its objects' names.
    var describeRoom: (() -> String)?

    private var conversation: Conversation?
    /// What was said and done at earlier presses of Talk, oldest first. Each
    /// press is a conversation of its own, so this is how a later one knows
    /// what "it" or "another one" means.
    private var history: [String] = []
    private var subscriptions = Set<AnyCancellable>()
    private var handledCalls = Set<String>()
    private var idleStop: Task<Void, Never>?
    /// Talk is one-shot: one committed user utterance, one short answer, then
    /// the connection closes as soon as playback finishes.
    private var receivedCommand = false

    private static let configFile = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("voice-agent.json")
    private static let transcriptFile = FileManager.default.urls(for: .applicationSupportDirectory,
                                                                  in: .userDomainMask)[0]
        .appendingPathComponent("RoomTwin/voice-history.json")
    private static let exportFile = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("RoomTwin Conversation History.json")

    private struct Config: Decodable {
        let agentId: String
    }

    init() {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let data = try? Data(contentsOf: Self.transcriptFile),
           let saved = try? decoder.decode([TranscriptEntry].self, from: data) {
            transcript = saved
        }
    }

    /// The always-current JSON file used by ShareLink in the History sheet.
    var transcriptExportURL: URL? {
        transcript.isEmpty ? nil : Self.exportFile
    }

    func clearTranscript() {
        transcript.removeAll()
        history.removeAll()
        try? FileManager.default.removeItem(at: Self.transcriptFile)
        try? FileManager.default.removeItem(at: Self.exportFile)
    }

    func toggle() {
        Task {
            if status == .off { await start() } else { await stop() }
        }
    }

    func start() async {
        guard status == .off else { return }
        guard let config = (try? Data(contentsOf: Self.configFile)).flatMap({ try? JSONDecoder().decode(Config.self, from: $0) }) else {
            errorMessage = "Voice isn't set up yet. With the phone connected, run python3 Voice/setup_agent.py on the Mac."
            return
        }
        Diagnostics.action("voice start")
        status = .connecting
        errorMessage = nil
        heard = nil
        caption = nil
        var options = ConversationConfig()
        options.onUserTranscript = { [weak self] text, _ in
            Task { @MainActor in
                self?.idleStop?.cancel()
                self?.receivedCommand = true
                self?.heard = text
                self?.caption = nil
                self?.remember("User: \(text)")
                self?.record(.user, text)
            }
        }
        options.onAgentResponse = { [weak self] text, _ in
            // Tags like "[happy]" direct the voice; they aren't words.
            let words = text.replacingOccurrences(of: #"\[[^\]]*\]\s*"#, with: "", options: .regularExpression)
            Task { @MainActor in
                self?.caption = words
                self?.remember("You: \(words)")
                self?.record(.assistant, words)
            }
        }
        var lastError: Error?
        for attempt in 0..<3 {
            do {
                let conversation = try await ElevenLabs.startConversation(agentId: config.agentId, config: options)
                guard status == .connecting else {
                    // Stopped while connecting or during a retry delay.
                    await conversation.endConversation()
                    return
                }
                self.conversation = conversation
                observe(conversation)
                // Lands while the user is still speaking, before the agent's first turn.
                if let memory = memory() { try? await conversation.updateContext(memory) }
                return
            } catch {
                lastError = error
                guard status == .connecting else { return }
                guard attempt < 2, Self.isTemporaryConnectionError(error) else { break }
                Diagnostics.log("voice connection retry \(attempt + 1): \(error.localizedDescription)")
                try? await Task.sleep(for: .milliseconds(600 * (attempt + 1)))
            }
        }
        status = .off
        let error = lastError?.localizedDescription ?? "unknown connection error"
        errorMessage = Self.isTemporaryConnectionError(lastError)
            ? "The voice service is temporarily unavailable. Tap Talk to retry."
            : "Couldn't reach the voice agent: \(error)"
    }

    func stop() async {
        Diagnostics.action("voice stop")
        let conversation = self.conversation
        finish()
        await conversation?.endConversation()
    }

    private func finish() {
        idleStop?.cancel()
        idleStop = nil
        conversation = nil
        subscriptions.removeAll()
        handledCalls.removeAll()
        receivedCommand = false
        status = .off
    }

    private func observe(_ conversation: Conversation) {
        conversation.$state.combineLatest(conversation.$agentState)
            .sink { [weak self] state, agentState in
                guard let self else { return }
                switch state {
                case .idle, .connecting:
                    status = .connecting
                case .active:
                    let previous = status
                    switch agentState {
                    case .listening:
                        status = .listening
                        if previous == .speaking, receivedCommand {
                            // `.listening` after `.speaking` means the final
                            // response audio has finished playing. End before
                            // a second user turn can start accruing time.
                            Task { await self.stop() }
                        } else {
                            armIdleStop(after: 15)
                        }
                    case .thinking:
                        status = .thinking
                        idleStop?.cancel()
                    case .speaking:
                        status = .speaking
                        idleStop?.cancel()
                    }
                case .ended:
                    finish()
                case .error(let error):
                    errorMessage = "The voice agent stopped: \(error.localizedDescription)"
                    finish()
                }
            }
            .store(in: &subscriptions)
        conversation.$pendingToolCalls
            .sink { [weak self] calls in
                guard let self else { return }
                for call in calls where handledCalls.insert(call.toolCallId).inserted {
                    Task { await self.run(call) }
                }
            }
            .store(in: &subscriptions)
    }

    private func remember(_ line: String) {
        history.append(String(line.prefix(240)))
        if history.count > 24 { history.removeFirst(history.count - 24) }
    }

    private func record(_ speaker: TranscriptEntry.Speaker, _ text: String) {
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return }
        // SDK events may repeat an identical final transcript. Do not make the
        // exported training example contain duplicate consecutive turns.
        if let last = transcript.last, last.speaker == speaker, last.text == clean,
           Date().timeIntervalSince(last.date) < 2 { return }
        transcript.append(TranscriptEntry(id: UUID(), date: Date(), speaker: speaker, text: clean))
        if transcript.count > 500 { transcript.removeFirst(transcript.count - 500) }
        persistTranscript()
    }

    private func persistTranscript() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(transcript) else { return }
        do {
            try FileManager.default.createDirectory(at: Self.transcriptFile.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try data.write(to: Self.transcriptFile, options: .atomic)
            try data.write(to: Self.exportFile, options: .atomic)
        } catch {
            Diagnostics.log("voice history save failed: \(error.localizedDescription)")
        }
    }

    /// Earlier presses of Talk and the room as it is, sent to a new
    /// conversation as a contextual update: the agent reads it but doesn't
    /// answer it. Kept short, as every conversation pays for it in tokens.
    private func memory() -> String? {
        var parts: [String] = []
        if !history.isEmpty {
            parts.append("Earlier this session, at previous presses of Talk (all already carried out; never redo "
                         + "them). Use it to understand words like \"it\", \"that\", \"another one\" or "
                         + "\"put it back\":\n" + history.joined(separator: "\n"))
        }
        if let room = describeRoom?() { parts.append(room) }
        return parts.isEmpty ? nil : parts.joined(separator: "\n\n")
    }

    private func armIdleStop(after seconds: UInt64) {
        idleStop?.cancel()
        idleStop = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled, let self, status == .listening else { return }
            await stop()
        }
    }

    /// ElevenLabs' public token service occasionally returns a transient 5xx.
    /// Retrying here avoids presenting it as an authentication/configuration
    /// problem, while real private-agent/401 failures still surface at once.
    private static func isTemporaryConnectionError(_ error: Error?) -> Bool {
        guard let error else { return false }
        let message = error.localizedDescription.lowercased()
        return ["http error: 500", "http error: 502", "http error: 503", "http error: 504",
                "timed out", "network connection was lost"].contains(where: message.contains)
    }

    private func run(_ call: ClientToolCallEvent) async {
        guard let conversation else { return }
        var result: String
        var isError = false
        do {
            guard let perform else { throw Failure(message: "The app isn't ready for that.") }
            result = try await perform(call.toolName, try call.getParameters())
        } catch {
            result = error.localizedDescription
            isError = true
        }
        Diagnostics.log("voice tool \(call.toolName): \(result)")
        remember((isError ? "App couldn't: " : "App did: ") + result)
        if call.expectsResponse {
            try? await conversation.sendToolResult(for: call.toolCallId, result: result, isError: isError)
        } else {
            conversation.markToolCallCompleted(call.toolCallId)
        }
    }
}
