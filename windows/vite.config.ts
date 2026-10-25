import fs from "node:fs";
import path from "node:path";
import type { IncomingMessage, ServerResponse } from "node:http";
import tailwindcss from "@tailwindcss/vite";
import { defineConfig, type Plugin } from "vite";

const root = path.resolve(__dirname, "..");
/** The iPhone and Mac apps, whose furniture library and Supabase settings are shared. */
const apple = path.join(root, "ios-mac");

/** KEY=value lines, as the repo's Python scripts read .env.local. */
function readEnv(file: string): Record<string, string> {
  if (!fs.existsSync(file)) return {};
  const values: Record<string, string> = {};
  for (const line of fs.readFileSync(file, "utf8").split(/\r?\n/)) {
    const at = line.indexOf("=");
    if (at > 0 && !line.trimStart().startsWith("#")) values[line.slice(0, at).trim()] = line.slice(at + 1).trim();
  }
  return values;
}

/**
 * Defaults for the app's settings, from the repo's .env.local (and
 * windows/.env.local, which wins), and ios-mac/RoomTwin/supabase.json if the setup
 * script has written it. Only these names reach the browser: .env.local
 * also holds the ElevenLabs API key and the database password, which must not.
 */
function defaults() {
  const env = { ...readEnv(path.join(root, ".env.local")), ...readEnv(path.join(__dirname, ".env.local")) };
  let supabase: { url?: string; anonKey?: string } = {};
  try {
    supabase = JSON.parse(fs.readFileSync(path.join(apple, "RoomTwin", "supabase.json"), "utf8"));
  } catch {
    // Not set up on this machine; the app's Settings take the values instead.
  }
  return {
    supabaseUrl: env.SUPABASE_URL ?? supabase.url ?? "",
    supabaseAnonKey: env.SUPABASE_ANON_KEY ?? supabase.anonKey ?? "",
    agentId: env.ELEVENLABS_DESKTOP_AGENT_ID ?? env.ELEVENLABS_AGENT_ID ?? "",
    sketchfabToken: env.SKETCHFAB_API_TOKEN ?? "",
  };
}

/**
 * /__fetch?url=… fetches a Sketchfab download on the browser's behalf: its
 * short-lived file links don't always allow cross-origin reads. Only
 * Sketchfab's own hosts and the storage it links to are passed through, and
 * fal.ai's file host.
 */
function downloadProxy(): Plugin {
  const allowed = [/\.sketchfab\.com$/, /^sketchfab\.com$/, /\.amazonaws\.com$/, /\.cloudfront\.net$/, /(^|\.)fal\.media$/];
  const handle = async (req: IncomingMessage, res: ServerResponse, next: () => void) => {
    if (!req.url?.startsWith("/__fetch?")) return next();
    const target = new URL(req.url, "http://localhost").searchParams.get("url") ?? "";
    let url: URL;
    try {
      url = new URL(target);
    } catch {
      res.statusCode = 400;
      return res.end("bad url");
    }
    if (url.protocol !== "https:" || !allowed.some((host) => host.test(url.hostname))) {
      res.statusCode = 403;
      return res.end("host not allowed");
    }
    try {
      const reply = await fetch(url);
      res.statusCode = reply.status;
      res.setHeader("Content-Type", reply.headers.get("content-type") ?? "application/octet-stream");
      res.end(Buffer.from(await reply.arrayBuffer()));
    } catch (error) {
      res.statusCode = 502;
      res.end(String(error));
    }
  };
  return {
    name: "roomtwin-download-proxy",
    configureServer: (server) => void server.middlewares.use(handle),
    configurePreviewServer: (server) => void server.middlewares.use(handle),
  };
}

/**
 * POST /__fal with {endpoint, input} runs one of fal.ai's SAM 3 models on
 * the browser's behalf, as ObjectServer/fal_server.py does for the phone:
 * FALKEY stays in .env.local (read on each request) and never reaches the
 * page. The request waits in fal's queue until the result is ready (up to 6
 * minutes) and returns it. GET /__fal says whether a key is set.
 */
function falProxy(): Plugin {
  const endpoints = new Set(["sam-3/image", "sam-3/3d-objects"]);
  const key = () => {
    const env = { ...readEnv(path.join(root, ".env.local")), ...readEnv(path.join(__dirname, ".env.local")) };
    return env.FALKEY || env.FAL_KEY || "";
  };
  const reply = (res: ServerResponse, status: number, body: unknown) => {
    res.statusCode = status;
    res.setHeader("Content-Type", "application/json");
    res.end(JSON.stringify(body));
  };
  const fal = async (url: string, falKey: string, body?: unknown) => {
    const response = await fetch(url, {
      method: body === undefined ? "GET" : "POST",
      headers: { Authorization: `Key ${falKey}`, "Content-Type": "application/json" },
      body: body === undefined ? undefined : JSON.stringify(body),
    });
    const text = await response.text();
    if (response.status === 401) throw new Error("fal.ai rejected FALKEY. Make a new key in the fal.ai dashboard and put it in .env.local.");
    if (response.status === 403) throw new Error("FALKEY works but has no access to fal-ai/sam-3. Check the fal.ai account's billing.");
    if (!response.ok) throw new Error(`fal.ai HTTP ${response.status}: ${text.slice(0, 400)}`);
    return JSON.parse(text);
  };
  const handle = async (req: IncomingMessage, res: ServerResponse, next: () => void) => {
    if (!req.url?.startsWith("/__fal")) return next();
    const falKey = key();
    if (req.method === "GET") return reply(res, 200, { configured: Boolean(falKey) });
    if (!falKey) return reply(res, 400, { error: "Add FALKEY=… (your fal.ai API key) to .env.local in the repo, then try again." });
    try {
      const chunks: Buffer[] = [];
      for await (const chunk of req) chunks.push(chunk as Buffer);
      const { endpoint, input } = JSON.parse(Buffer.concat(chunks).toString("utf8"));
      if (!endpoints.has(endpoint)) return reply(res, 400, { error: "unknown fal.ai model" });
      const queued = await fal(`https://queue.fal.run/fal-ai/${endpoint}`, falKey, input);
      const immediate = queued.data ?? queued;
      if (["model_glb", "individual_glbs", "masks"].some((k) => k in immediate)) return reply(res, 200, immediate);
      const started = Date.now();
      while (Date.now() - started < 360_000) {
        const status = await fal(queued.status_url, falKey);
        if (status.status === "COMPLETED") {
          const result = await fal(queued.response_url, falKey);
          return reply(res, 200, result.data ?? result);
        }
        if (status.status === "FAILED" || status.status === "CANCELLED") {
          throw new Error(status.error ?? `fal.ai job ${String(status.status).toLowerCase()}`);
        }
        await new Promise((resolve) => setTimeout(resolve, 1000));
      }
      throw new Error("fal.ai didn't finish within 6 minutes.");
    } catch (error) {
      reply(res, 502, { error: error instanceof Error ? error.message : String(error) });
    }
  };
  return {
    name: "roomtwin-fal-proxy",
    configureServer: (server) => void server.middlewares.use(handle),
    configurePreviewServer: (server) => void server.middlewares.use(handle),
  };
}

export default defineConfig({
  plugins: [tailwindcss(), downloadProxy(), falProxy()],
  define: { __ROOMTWIN_DEFAULTS__: JSON.stringify(defaults()) },
  resolve: { alias: { "@library": path.join(apple, "RoomTwin", "Library") } },
  server: { port: 5173, fs: { allow: [__dirname, path.join(apple, "RoomTwin", "Library")] } },
});
