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

    @Published private(set) var status = Status.off
    /// The last thing said, by either side.
    @Published private(set) var caption: String?
    @Published var errorMessage: String?

    /// Carries out a tool call: its name and parameters in, a short account
    /// of what happened out, for the agent to talk about. Throws to report
    /// why it couldn't; the error's description goes to the agent.
    var perform: ((String, [String: Any]) async throws -> String)?

    private var conversation: Conversation?
    private var subscriptions = Set<AnyCancellable>()
    private var handledCalls = Set<String>()

    private static let configFile = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("voice-agent.json")

    private struct Config: Decodable {
        let agentId: String
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
        caption = nil
        var options = ConversationConfig()
        options.onUserTranscript = { [weak self] text, _ in
            Task { @MainActor in self?.caption = "“\(text)”" }
        }
        options.onAgentResponse = { [weak self] text, _ in
            // Tags like "[happy]" direct the voice; they aren't words.
            let words = text.replacingOccurrences(of: #"\[[^\]]*\]\s*"#, with: "", options: .regularExpression)
            Task { @MainActor in self?.caption = words }
        }
        do {
            let conversation = try await ElevenLabs.startConversation(agentId: config.agentId, config: options)
            guard status == .connecting else {
                // Stopped while connecting.
                await conversation.endConversation()
                return
            }
            self.conversation = conversation
            observe(conversation)
        } catch {
            status = .off
            errorMessage = "Couldn't reach the voice agent: \(error.localizedDescription)"
        }
    }

    func stop() async {
        Diagnostics.action("voice stop")
        let conversation = self.conversation
        finish()
        await conversation?.endConversation()
    }

    private func finish() {
        conversation = nil
        subscriptions.removeAll()
        handledCalls.removeAll()
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
                    status = switch agentState {
                    case .listening: .listening
                    case .thinking: .thinking
                    case .speaking: .speaking
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
        if call.expectsResponse {
            try? await conversation.sendToolResult(for: call.toolCallId, result: result, isError: isError)
        } else {
            conversation.markToolCallCompleted(call.toolCallId)
        }
    }
}
