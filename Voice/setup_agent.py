"""Creates or updates RoomTwin's voice agent on ElevenLabs and gives its ID to the phone.

    python3 Voice/setup_agent.py

Reads ELEVENLABS_API_KEY from .env.local. The first run creates the agent and
its client tools (add_object, remove_object, set_wall_texture, reset_walls)
and saves their IDs to .env.local; later runs update them. The tools run in
the app, which fetches models from Poly Haven and Sketchfab: the agent only
decides what to ask for and where it goes.

The agent is public, so the phone needs only its ID, never the key: it starts
conversations with the agent ID alone. A 3-minute cap per conversation and
50 conversations a day bound what a leaked ID could cost. If the phone is
connected, the ID is copied to Library/voice-agent.json in the app's
container, the same way ObjectServer/start.sh hands over the server address.
SKETCHFAB_API_TOKEN, if set, goes over the same way as Library/sketchfab.json,
which the app moves into its Keychain and deletes.
"""

import json
import os
import subprocess
import sys
import tempfile
import urllib.error
import urllib.request

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
ENV = os.path.join(ROOT, ".env.local")
API = "https://api.elevenlabs.io"
DEVICE = os.environ.get("DEVICE", "893484B9-033A-5427-9561-A3DF76E94ACC")
APP = os.environ.get("APP", "dev.bugatti.RoomTwinLol")

PROMPT = """\
You are the voice of RoomTwin, an iPhone app. The user is looking at a 3D scan of their room on \
the phone and can ask you to furnish it or change its walls. The app finds the floor and walls, \
and fetches models from online libraries (Poly Haven, and Sketchfab for what Poly Haven lacks).

Adding: call add_object once per piece.
- query: a short catalogue search, the thing plus the user's style words ("floor lamp", \
"red velvet sofa", "wooden dining table").
- height_m: your estimate of its real height in metres (dining chair 0.9, dining table 0.75, \
coffee table 0.45, sofa 0.85, floor lamp 1.6, desk lamp 0.45, bookshelf 1.8, potted plant 1.0). \
Something going on_top_of a piece is tabletop-sized (plant 0.35, lamp 0.45, vase 0.3).
- placement: in_view (default) puts it on the floor where the user is looking; against_wall \
when they say by, against or along the wall; next_to with reference when they say next to or \
beside something added earlier; on_top_of with reference when they say on something added earlier.
- facing: away_from_wall for "facing out" or "facing the room" (the default against a wall); \
toward_wall for "facing the wall"; user for "facing me"; same_as_reference to match its neighbour.
- Several things together ("a table and a lamp by the wall"): add the biggest first, then put \
the rest next_to or on_top_of it. A desk or table lamp goes on_top_of a table.
- source: leave it as any unless the user names Poly Haven or Sketchfab.
- reference can only name things added in this conversation, not furniture already in the scan.

Removing: remove_object with the name or kind ("the lamp"); with no name it removes the latest.
Walls: set_wall_texture with a short material search ("red brick", "white plaster", \
"wood panels"); walls is all unless they mean the one they're looking at ("this wall"). \
reset_walls puts the scanned look back.

Each tool replies with what was actually added and where. It may be a different model from \
the one asked for, so name what you added. Answer in one short, friendly sentence. If a tool \
fails, say why in a few words and what to try (for example, look at open floor). Before a \
call that may take a moment, say a few words like "Sure, one sec." Never mention tools or how \
the app works inside.
"""


def read_env():
    values = {}
    with open(ENV) as f:
        for line in f:
            if "=" in line and not line.lstrip().startswith("#"):
                name, value = line.strip().split("=", 1)
                values[name] = value
    return values


def save_env(name, value):
    """Sets one line of .env.local, keeping the rest of the file and its permissions."""
    with open(ENV) as f:
        lines = f.read().splitlines()
    lines = [line for line in lines if not line.startswith(f"{name}=")] + [f"{name}={value}"]
    with open(ENV, "w") as f:
        f.write("\n".join(lines) + "\n")


def call(method, path, body, key):
    request = urllib.request.Request(API + path, method=method, data=json.dumps(body).encode(),
                                     headers={"xi-api-key": key, "Content-Type": "application/json"})
    try:
        with urllib.request.urlopen(request) as response:
            return json.load(response)
    except urllib.error.HTTPError as error:
        sys.exit(f"{method} {path} failed with {error.code}: {error.read().decode()[:800]}")


def tools():
    def text(description, choices=None):
        return {"type": "string", "description": description, **({"enum": choices} if choices else {})}

    return {
        "ELEVENLABS_ADD_OBJECT_TOOL_ID": {
            "type": "client",
            "name": "add_object",
            "description": "Finds a model of something and stands it in the user's room scan, upright on "
                           "the floor (or on an earlier piece). Returns what was added and where.",
            "expects_response": True,
            # Downloading a model can take a few seconds on a slow connection.
            "response_timeout_secs": 30,
            "parameters": {
                "type": "object",
                "required": ["query", "height_m"],
                "properties": {
                    "query": text("Catalogue search for the thing, e.g. 'floor lamp', 'red velvet sofa'."),
                    "height_m": {"type": "number", "description": "Its typical real height in metres."},
                    "placement": text("Where it goes.", ["in_view", "against_wall", "next_to", "on_top_of"]),
                    "facing": text("Which way its front faces.",
                                   ["user", "away_from_wall", "toward_wall", "same_as_reference"]),
                    "reference": text("For next_to and on_top_of: the earlier-added piece, e.g. 'table'."),
                    "source": text("Which library to use.", ["any", "polyhaven", "sketchfab"]),
                },
            },
        },
        "ELEVENLABS_REMOVE_OBJECT_TOOL_ID": {
            "type": "client",
            "name": "remove_object",
            "description": "Removes a piece added earlier, by name or kind; the latest if no name is given.",
            "expects_response": True,
            "response_timeout_secs": 10,
            "parameters": {"type": "object", "required": [],
                           "properties": {"name": text("The piece to remove, e.g. 'lamp'. Empty for the latest.")}},
        },
        "ELEVENLABS_WALL_TEXTURE_TOOL_ID": {
            "type": "client",
            "name": "set_wall_texture",
            "description": "Covers the walls with a material from Poly Haven, at its real size.",
            "expects_response": True,
            "response_timeout_secs": 20,
            "parameters": {"type": "object", "required": ["query"], "properties": {
                "query": text("Material search, e.g. 'red brick', 'white plaster', 'wood panels'."),
                "walls": text("All walls, or only the one the user is looking at.", ["all", "in_view"]),
            }},
        },
        "ELEVENLABS_RESET_WALLS_TOOL_ID": {
            "type": "client",
            "name": "reset_walls",
            "description": "Takes textures off the walls, back to the scan's own colours.",
            "expects_response": True,
            "response_timeout_secs": 10,
        },
    }


def push_to_phone(name, contents):
    """Copies a small JSON file into the app's Library folder on the phone."""
    with tempfile.TemporaryDirectory() as folder:
        path = os.path.join(folder, name)
        with open(path, "w") as f:
            json.dump(contents, f)
        result = subprocess.run(["xcrun", "devicectl", "device", "copy", "to", "--device", DEVICE,
                                 "--domain-type", "appDataContainer", "--domain-identifier", APP,
                                 "--source", path, "--destination", f"Library/{name}"],
                                capture_output=True)
    return result.returncode == 0


def main():
    env = read_env()
    key = env.get("ELEVENLABS_API_KEY")
    if not key:
        sys.exit("put ELEVENLABS_API_KEY=... in .env.local first")
    tool_ids = []
    for env_name, config in tools().items():
        if env.get(env_name):
            call("PATCH", f"/v1/convai/tools/{env[env_name]}", {"tool_config": config}, key)
            print(f"== updated tool {config['name']}")
        else:
            env[env_name] = call("POST", "/v1/convai/tools", {"tool_config": config}, key)["id"]
            save_env(env_name, env[env_name])
            print(f"== created tool {config['name']}")
        tool_ids.append(env[env_name])

    agent = {
        "name": "RoomTwin",
        "conversation_config": {
            "agent": {
                "first_message": "",
                "language": "en",
                "prompt": {"prompt": PROMPT, "llm": "claude-haiku-4-5", "temperature": 0, "tool_ids": tool_ids},
            },
            "conversation": {"max_duration_seconds": 180},
        },
        "platform_settings": {
            "auth": {"enable_auth": False},
            "call_limits": {"daily_limit": 50, "agent_concurrency_limit": 1},
        },
    }
    agent_id = env.get("ELEVENLABS_AGENT_ID")
    if agent_id:
        call("PATCH", f"/v1/convai/agents/{agent_id}", agent, key)
        print(f"== updated agent {agent_id}")
    else:
        agent_id = call("POST", "/v1/convai/agents/create", agent, key)["agent_id"]
        save_env("ELEVENLABS_AGENT_ID", agent_id)
        print(f"== created agent {agent_id}")

    if not push_to_phone("voice-agent.json", {"agentId": agent_id}):
        sys.exit("== couldn't reach the phone; connect it, open RoomTwin once, and run this again")
    print("== sent the agent ID to the phone")
    if env.get("SKETCHFAB_API_TOKEN"):
        push_to_phone("sketchfab.json", {"token": env["SKETCHFAB_API_TOKEN"]})
        print("== sent the Sketchfab token to the phone")
    else:
        print("   no SKETCHFAB_API_TOKEN in .env.local, so models come from Poly Haven only")


if __name__ == "__main__":
    main()
