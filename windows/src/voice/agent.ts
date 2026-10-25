import { Conversation, stripAudioTags, type VoiceConversation } from "@elevenlabs/client";
import { settings } from "../config";

export type Status = "off" | "connecting" | "listening" | "speaking";

/** What a tool call gets: its parameters in, a short account of what happened out. Throw to say why it failed. */
export type Tool = (parameters: Record<string, any>) => Promise<string>;

export interface TranscriptEntry {
  date: string;
  speaker: "user" | "assistant";
  text: string;
}

const transcriptKey = "roomtwin-voice-history";

/**
 * A spoken conversation with RoomTwin's ElevenLabs agent, the one
 * Voice/setup_agent.py made for the phone. ElevenLabs listens, its LLM
 * decides what the user wants, the tools here carry it out, and the agent
 * answers out loud. Only the agent's ID is needed: the agent is public, and
 * the API key stays out of the app.
 *
 * Talk is one-shot, as on the phone: one thing said, one short answer, and
 * the call ends as soon as the answer has been spoken (calls are billed by
 * the second). Each call starts with a contextual update: what was said and
 * done at earlier presses of Talk, and the room as it is now, so "it" and
 * "another one" make sense.
 */
export class VoiceAgent {
  status: Status = "off";
  /** The last thing said, by either side. */
  caption = "";
  onUpdate?: () => void;
  onError?: (message: string) => void;
  /** The room as it is now, in words for the agent: what's in view, and every editable piece's name. */
  describeRoom?: () => string;
  /** Every line said, kept in this browser for the History list and its export. */
  transcript: TranscriptEntry[] = [];
  private conversation?: VoiceConversation;
  private starting = false;
  /** Earlier presses of Talk, oldest first. */
  private history: string[] = [];
  private receivedCommand = false;
  private idleStop?: number;

  constructor(private tools: Record<string, Tool>) {
    try {
      this.transcript = JSON.parse(localStorage.getItem(transcriptKey) ?? "[]");
    } catch {
      this.transcript = [];
    }
  }

  get isOn() {
    return this.status !== "off";
  }

  async toggle() {
    if (this.isOn) await this.stop();
    else await this.start();
  }

  async start() {
    if (this.isOn || this.starting) return;
    const { agentId } = settings();
    if (!agentId) {
      this.onError?.("Voice isn't set up: paste the ElevenLabs agent ID (ELEVENLABS_AGENT_ID) in Settings.");
      return;
    }
    this.starting = true;
    this.receivedCommand = false;
    this.set("connecting", "");
    const clientTools = Object.fromEntries(Object.entries(this.tools).map(([name, tool]) => [name, async (parameters: any) => {
      let result: string;
      try {
        result = await tool(parameters ?? {});
        this.remember(`App did: ${result}`);
      } catch (error) {
        const message = error instanceof Error ? error.message : String(error);
        this.remember(`App couldn't: ${message}`);
        // The agent reads this and tells the user why.
        result = `Failed: ${message}`;
      }
      console.info(`voice tool ${name}:`, result);
      return result;
    }]));
    try {
      await navigator.mediaDevices.getUserMedia({ audio: true }).then((stream) => stream.getTracks().forEach((t) => t.stop()));
      const conversation = await Conversation.startSession({
        agentId,
        connectionType: "websocket",
        textOnly: false,
        clientTools,
        onModeChange: ({ mode }) => this.modeChanged(mode === "speaking" ? "speaking" : "listening"),
        onMessage: ({ message, role }) => this.heard(role === "user" ? "user" : "assistant", message),
        onDisconnect: () => this.finish(),
        onError: (message) => this.onError?.(`The voice agent stopped: ${message}`),
      });
      if (!this.starting) {
        // Hung up while connecting.
        await conversation.endSession().catch(() => {});
        return;
      }
      this.conversation = conversation;
      // Lands while the user is still speaking, before the agent's first turn.
      const memory = this.memory();
      if (memory) conversation.sendContextualUpdate(memory);
      this.modeChanged("listening");
    } catch (error) {
      this.finish();
      const message = error instanceof Error ? error.message : String(error);
      this.onError?.(message.includes("Permission") || message.includes("NotAllowed")
        ? "Allow the microphone for this page to talk." : `Couldn't reach the voice agent: ${message}`);
    } finally {
      this.starting = false;
    }
  }

  async stop() {
    const conversation = this.conversation;
    this.starting = false;
    this.finish();
    await conversation?.endSession().catch(() => {});
  }

  clearTranscript() {
    this.transcript = [];
    this.history = [];
    this.saveTranscript();
  }

  private modeChanged(mode: "listening" | "speaking") {
    if (!this.isOn) return;
    const previous = this.status;
    this.set(mode);
    clearTimeout(this.idleStop);
    if (mode !== "listening") return;
    if (previous === "speaking" && this.receivedCommand) {
      // Listening again after speaking means the answer has finished playing: hang up before a second turn costs time.
      void this.stop();
    } else {
      this.idleStop = window.setTimeout(() => this.status === "listening" && void this.stop(), 15_000);
    }
  }

  private heard(speaker: "user" | "assistant", message: string) {
    // Tags like "[happy]" direct the voice; they aren't words.
    const text = speaker === "user" ? message : stripAudioTags(message);
    if (speaker === "user") {
      this.receivedCommand = true;
      clearTimeout(this.idleStop);
    }
    this.remember(`${speaker === "user" ? "User" : "You"}: ${text}`);
    this.record(speaker, text);
    this.set(this.status, speaker === "user" ? `“${text}”` : text);
  }

  /** Earlier presses of Talk and the room as it is, for a new call to read but not answer. Kept short: every call pays for it. */
  private memory() {
    const parts: string[] = [];
    if (this.history.length) {
      parts.push("Earlier this session, at previous presses of Talk (all already carried out; never redo them). "
        + "Use it to understand words like \"it\", \"that\", \"another one\" or \"put it back\":\n" + this.history.join("\n"));
    }
    const room = this.describeRoom?.();
    if (room) parts.push(room);
    return parts.join("\n\n");
  }

  private remember(line: string) {
    this.history.push(line.slice(0, 240));
    if (this.history.length > 24) this.history.splice(0, this.history.length - 24);
  }

  private record(speaker: TranscriptEntry["speaker"], text: string) {
    const clean = text.trim();
    if (!clean) return;
    const last = this.transcript[this.transcript.length - 1];
    if (last?.speaker === speaker && last.text === clean && Date.now() - Date.parse(last.date) < 2000) return;
    this.transcript.push({ date: new Date().toISOString(), speaker, text: clean });
    if (this.transcript.length > 500) this.transcript.splice(0, this.transcript.length - 500);
    this.saveTranscript();
  }

  private saveTranscript() {
    try {
      localStorage.setItem(transcriptKey, JSON.stringify(this.transcript));
    } catch {
      // Storage blocked: the history lasts until the page closes.
    }
  }

  private finish() {
    clearTimeout(this.idleStop);
    this.conversation = undefined;
    this.receivedCommand = false;
    this.set("off");
  }

  private set(status: Status, caption = this.caption) {
    this.status = status;
    this.caption = caption;
    this.onUpdate?.();
  }
}
