/**
 * The app's settings: where the account lives, which voice agent to talk
 * to, and the Sketchfab token. Defaults come from the repo's .env.local and
 * RoomTwin/supabase.json when vite starts (see vite.config.ts); anything
 * typed into Settings is kept in this browser and wins.
 */
export interface Settings {
  supabaseUrl: string;
  supabaseAnonKey: string;
  agentId: string;
  sketchfabToken: string;
}

declare const __ROOMTWIN_DEFAULTS__: Settings;

const storageKey = "roomtwin-settings";

function stored(): Partial<Settings> {
  try {
    return JSON.parse(localStorage.getItem(storageKey) ?? "{}");
  } catch {
    return {};
  }
}

export function settings(): Settings {
  const overrides = Object.fromEntries(Object.entries(stored()).filter(([, value]) => value));
  return { ...__ROOMTWIN_DEFAULTS__, ...overrides };
}

export function saveSettings(values: Partial<Settings>) {
  try {
    localStorage.setItem(storageKey, JSON.stringify({ ...stored(), ...values }));
  } catch {
    // Private window: the settings last until the page closes.
  }
}

export const defaults = __ROOMTWIN_DEFAULTS__;
