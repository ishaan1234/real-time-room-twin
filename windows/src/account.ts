import { settings } from "./config";

/**
 * The signed-in user, through Supabase, the same way the iPhone app's
 * Account.swift does it: username and password, then the room layouts and objects
 * that user saved. Row-level security (Accounts/schema.sql) shows each user
 * only their own, so to open a friend's scans, log in as the account they
 * scanned with.
 */
export interface Session {
  accessToken: string;
  refreshToken: string;
  expiresAt: number;
  userID: string;
  username: string;
}

/**
 * A room layout saved from the phone's Room Layout scan (Save to Account):
 * the edited USDZ, the raw PLY, RoomPlan's JSON and the edit metadata. Newer
 * phone builds keep the files in the user's Google Drive and only the paths
 * here ("drive:…"); older ones put them in the private room-layouts bucket.
 */
export interface SavedRoomLayout {
  id: string;
  name: string;
  model_path: string;
  ply_path: string;
  json_path: string;
  edits_path: string | null;
  created_at: string;
}

/** Whether the layout's files are in Supabase storage, rather than in the phone user's Google Drive. */
export const inSupabase = (layout: SavedRoomLayout) => !layout.model_path.startsWith("drive:");

export interface SavedObject {
  id: string;
  name: string;
  model_path: string;
  thumb_path: string | null;
  created_at: string;
}

const sessionKey = "roomtwin-session";

export class Account {
  session: Session | null = null;
  onChange?: () => void;

  constructor() {
    try {
      this.session = JSON.parse(localStorage.getItem(sessionKey) ?? "null");
    } catch {
      this.session = null;
    }
  }

  get isConfigured() {
    const { supabaseUrl, supabaseAnonKey } = settings();
    return Boolean(supabaseUrl && supabaseAnonKey);
  }

  // Signing in

  async signIn(username: string, password: string) {
    const reply = await this.call("auth/v1/token?grant_type=password", {
      json: { email: Account.email(username), password },
      signedIn: false,
    });
    this.start(await reply.json(), username);
  }

  async signUp(username: string, password: string) {
    if (password.length < 6) throw new Error("Use a password of at least 6 characters.");
    const reply = await (await this.call("auth/v1/signup", {
      json: { email: Account.email(username), password, data: { username } },
      signedIn: false,
    })).json();
    if (!reply.access_token) {
      throw new Error("The account was made but needs email confirmation. Turn off Confirm email in Supabase, then log in.");
    }
    this.start(reply, username);
  }

  signOut() {
    const token = this.session?.accessToken;
    this.setSession(null);
    if (token) this.call("auth/v1/logout", { method: "POST", bearer: token }).catch(() => {});
  }

  private static email(username: string) {
    const name = username.toLowerCase().trim();
    if (!/^[a-z0-9._-]{3,24}$/.test(name)) {
      throw new Error("Use 3–24 letters, numbers, dots, dashes or underscores for the username.");
    }
    return `${name}@users.roomtwin.app`;
  }

  private start(reply: any, username: string) {
    if (!reply?.access_token || !reply?.refresh_token || !reply?.user?.id) {
      throw new Error("Supabase sent back something unexpected.");
    }
    this.setSession({
      accessToken: reply.access_token,
      refreshToken: reply.refresh_token,
      expiresAt: Date.now() + (reply.expires_in ?? 3600) * 1000,
      userID: reply.user.id,
      username: reply.user.user_metadata?.username ?? username,
    });
  }

  private setSession(session: Session | null) {
    this.session = session;
    try {
      if (session) localStorage.setItem(sessionKey, JSON.stringify(session));
      else localStorage.removeItem(sessionKey);
    } catch {
      // Private window: signed in until the page closes.
    }
    this.onChange?.();
  }

  /** A fresh access token, renewing the session if it's about to expire. */
  private async accessToken() {
    const session = this.session;
    if (!session) throw new Error("Log in first.");
    if (session.expiresAt > Date.now() + 60_000) return session.accessToken;
    try {
      const reply = await this.call("auth/v1/token?grant_type=refresh_token", {
        json: { refresh_token: session.refreshToken },
        signedIn: false,
      });
      this.start(await reply.json(), session.username);
      return this.session!.accessToken;
    } catch {
      this.setSession(null);
      throw new Error("You've been logged out. Log in again.");
    }
  }

  // Rooms and objects

  async roomLayouts(): Promise<SavedRoomLayout[]> {
    const reply = await this.call(
      "rest/v1/room_layouts?select=id,name,model_path,ply_path,json_path,edits_path,created_at&order=created_at.desc",
    );
    return reply.json();
  }

  async objects(): Promise<SavedObject[]> {
    const reply = await this.call("rest/v1/objects?select=id,name,model_path,thumb_path,created_at&order=created_at.desc");
    return reply.json();
  }

  /**
   * A file from one of the private buckets. Anything deflated before
   * uploading (".deflate") comes back inflated.
   */
  async file(bucket: "room-layouts" | "objects", path: string): Promise<ArrayBuffer> {
    const reply = await this.call(`storage/v1/object/authenticated/${bucket}/${path}`);
    const data = await reply.arrayBuffer();
    return path.endsWith(".deflate") ? inflate(data) : data;
  }

  /** A thumbnail as an object URL, or null. */
  async thumbnail(object: SavedObject): Promise<string | null> {
    if (!object.thumb_path) return null;
    try {
      return URL.createObjectURL(new Blob([await this.file("objects", object.thumb_path)], { type: "image/jpeg" }));
    } catch {
      return null;
    }
  }

  // Requests

  private async call(
    path: string,
    options: { method?: string; json?: unknown; signedIn?: boolean; bearer?: string } = {},
  ): Promise<Response> {
    const { supabaseUrl, supabaseAnonKey } = settings();
    if (!supabaseUrl || !supabaseAnonKey) {
      throw new Error("Accounts aren't set up: open Settings and paste the Supabase URL and anon key.");
    }
    // Only a user's token goes in Authorization: newer publishable keys aren't JWTs.
    const token = options.bearer ?? (options.signedIn === false ? undefined : await this.accessToken());
    const headers: Record<string, string> = { apikey: supabaseAnonKey };
    if (token) headers.Authorization = `Bearer ${token}`;
    if (options.json !== undefined) headers["Content-Type"] = "application/json";
    const reply = await fetch(new URL(path, supabaseUrl.replace(/\/?$/, "/")), {
      method: options.method ?? (options.json !== undefined ? "POST" : "GET"),
      headers,
      body: options.json !== undefined ? JSON.stringify(options.json) : undefined,
    });
    if (!reply.ok) {
      const body = await reply.json().catch(() => ({}));
      const message = body.msg ?? body.error_description ?? body.message ?? body.error;
      if (reply.status === 404 && path.startsWith("rest/v1/room_layouts")) {
        throw new Error("This Supabase project has no room_layouts table yet: run python3 Accounts/setup_supabase.py on the Mac.");
      }
      throw new Error(plain(message) ?? `Supabase said no (HTTP ${reply.status}).`);
    }
    return reply;
  }
}

/** Supabase's messages in this app's terms. */
function plain(message: string | undefined) {
  if (message === "Invalid login credentials") return "Wrong username or password.";
  if (message === "User already registered") return "That username is taken.";
  return message;
}

/**
 * Apple's zlib compression writes raw DEFLATE, without zlib's header; a
 * header is tried as well in case the file came from elsewhere.
 */
async function inflate(data: ArrayBuffer): Promise<ArrayBuffer> {
  for (const format of ["deflate-raw", "deflate"] as const) {
    try {
      const stream = new Blob([data]).stream().pipeThrough(new DecompressionStream(format));
      return await new Response(stream).arrayBuffer();
    } catch {
      // Try the other format.
    }
  }
  throw new Error("The room's mesh couldn't be unpacked.");
}
