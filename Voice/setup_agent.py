"""Creates or updates RoomTwin's voice agent on ElevenLabs and gives its ID to the phone.

    python3 Voice/setup_agent.py

Reads ELEVENLABS_API_KEY from .env.local. The first run creates the agent and
its client tools (catalogue and saved-object placement, moving, replacing, removing, resizing, materials,
enclosure and lighting)
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
the phone and can ask you to furnish it or change its surfaces and lighting. The app finds the floor and walls, \
and fetches models from online libraries (Poly Haven, and Sketchfab for what Poly Haven lacks).

This is a one-shot command interface. Handle exactly one user instruction per conversation. Do not \
greet, acknowledge, narrate your work, ask a follow-up question, or speak before calling a tool. Make \
the best safe interpretation immediately. After the tool finishes, reply with one brief natural sentence \
of roughly 4 to 12 words that confirms the actual result, for example: "Done — I moved the table to \
the left." On failure, give one short useful sentence such as "I couldn't find a table to move." Then stop.

Each conversation may start with a contextual update listing what the user asked earlier in this session \
and what the app did, plus the editable objects in the room now. Those earlier commands are already done: \
never repeat them. Use them to resolve the new instruction ("make it bigger", "another one", "move that \
lamp left", "put the sofa back"), and use the object names exactly as listed.

Adding: call add_object once per piece.
- query: a short catalogue search, the thing plus the user's style words ("floor lamp", \
"red velvet sofa", "wooden dining table").
- height_m: your estimate of its real height in metres (dining chair 0.9, dining table 0.75, \
coffee table 0.45, sofa 0.85, floor lamp 1.6, desk lamp 0.45, bookshelf 1.8, potted plant 1.0). \
Something going on_top_of a piece is tabletop-sized (plant 0.35, lamp 0.45, vase 0.3).
- placement: in_view (default) puts it on the floor where the user is looking; against_wall \
when they say by, against or along the wall; next_to with reference when they say next to or \
beside something added earlier; on_top_of with reference when they say on something added earlier.
- placement on_wall mounts floating shelves, bookshelves, cabinets and sconces on the wall. Use \
elevation_m for the bottom height (usually 1.1 to 1.5 metres). For a floating bookshelf search \
"floating wall bookshelf" and estimate only the shelf unit's height, usually 0.3 to 0.8 metres.
- placement ceiling hangs ceiling lights, chandeliers and other ceiling fixtures from the ceiling.
- facing: away_from_wall for "facing out" or "facing the room" (the default against a wall); \
toward_wall for "facing the wall"; user for "facing me"; same_as_reference to match its neighbour.
- Several things together ("a table and a lamp by the wall"): add the biggest first, then put \
the rest next_to or on_top_of it. A desk or table lamp goes on_top_of a table.
- source: leave it as any unless the user names Poly Haven or Sketchfab.
- reference can name RoomPlan furniture already in the scan or something added in this conversation.

The user's own scanned or imported models live in My Objects. When they say "my", "saved", "imported", \
or name one of their own things (for example "my Hoka shoes"), call place_saved_object instead of \
add_object. Pass its natural name without "my". Use placement and reference normally: "put my Hoka shoes \
on any table" means name "Hoka shoes", placement on_top_of, reference "table". The app privately \
matches and downloads it; never search Poly Haven or Sketchfab for a user-owned object.

RoomPlan's scanned furniture is editable too. The user can refer to it by category ("table", "chair 2").
Moving: move_object with left, right, forward, backward, up or down relative to the user's current view.
Replacing: replace_object names the existing scanned or added object and searches for its replacement.
Removing: remove_object with the name or kind ("the lamp"); with no name it removes the latest editable object.
Walls: set_wall_texture with a short material search ("red brick", "white plaster", \
"wood panels"); walls is all unless they mean the one they're looking at ("this wall"). \
reset_walls puts the scanned look back.
Floor: set_floor_texture changes the ground material; reset_floor restores the scan.
Objects: set_object_texture changes a scanned or added object's material. resize_object changes its absolute \
height in metres. A name may be omitted to edit the latest editable object.
Enclosure: set_enclosure can add/remove a ceiling and can close/remove added walls across open room boundaries. \
Only pass the parts the user mentioned.
Lighting: lamp and light models illuminate the room automatically. set_lighting changes the whole \
room; brightness and warmth are both 0 to 1 (warmth 1 is warm amber, 0 is cool daylight).

Tool results contain implementation details for your decision only. Never read those details aloud. \
Never mention tools, model sources, dimensions, credits, or how the app works. The final spoken reply \
must remain one concise sentence, normally 4 to 12 words, and say what changed.
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
                    "placement": text("Where it goes.",
                                      ["in_view", "against_wall", "next_to", "on_top_of", "on_wall", "ceiling"]),
                    "facing": text("Which way its front faces.",
                                   ["user", "away_from_wall", "toward_wall", "same_as_reference"]),
                    "reference": text("For next_to and on_top_of: the earlier-added piece, e.g. 'table'."),
                    "elevation_m": {"type": "number",
                                    "description": "For on_wall: bottom height above the floor in metres."},
                    "source": text("Which library to use.", ["any", "polyhaven", "sketchfab"]),
                },
            },
        },
        "ELEVENLABS_SAVED_OBJECT_TOOL_ID": {
            "type": "client",
            "name": "place_saved_object",
            "description": "Places one of the signed-in user's private scanned or imported My Objects models. "
                           "Use this, not catalogue search, when the user says my, saved or imported.",
            "expects_response": True,
            "response_timeout_secs": 30,
            "parameters": {
                "type": "object",
                "required": ["name"],
                "properties": {
                    "name": text("Natural saved-object name, e.g. 'Hoka shoes'; omit words like my/imported."),
                    "placement": text("Where it goes.",
                                      ["in_view", "against_wall", "next_to", "on_top_of", "on_wall", "ceiling"]),
                    "reference": text("For next_to or on_top_of, any matching room object, e.g. 'table'."),
                },
            },
        },
        "ELEVENLABS_REMOVE_OBJECT_TOOL_ID": {
            "type": "client",
            "name": "remove_object",
            "description": "Removes a scanned or added editable object by name or kind; the latest if omitted.",
            "expects_response": True,
            "response_timeout_secs": 10,
            "parameters": {"type": "object", "required": [],
                           "properties": {"name": text("The piece to remove, e.g. 'lamp'. Empty for the latest.")}},
        },
        "ELEVENLABS_MOVE_OBJECT_TOOL_ID": {
            "type": "client",
            "name": "move_object",
            "description": "Moves a scanned or added object freely relative to the user's current view.",
            "expects_response": True,
            "response_timeout_secs": 10,
            "parameters": {"type": "object", "required": ["direction"], "properties": {
                "name": text("The scanned or added object to move; empty means the latest."),
                "direction": text("Direction relative to the user's view.",
                                  ["left", "right", "forward", "backward", "up", "down"]),
                "distance_m": {"type": "number", "description": "Distance in metres; default 0.3."},
            }},
        },
        "ELEVENLABS_REPLACE_OBJECT_TOOL_ID": {
            "type": "client",
            "name": "replace_object",
            "description": "Replaces a scanned or added object with a catalogue model in the same position.",
            "expects_response": True,
            "response_timeout_secs": 30,
            "parameters": {"type": "object", "required": ["query", "height_m"], "properties": {
                "name": text("The existing object to replace, e.g. 'table' or 'chair 2'."),
                "query": text("Catalogue search for the replacement."),
                "height_m": {"type": "number", "description": "Replacement's typical real height in metres."},
                "source": text("Which library to use.", ["any", "polyhaven", "sketchfab"]),
            }},
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
        "ELEVENLABS_FLOOR_TEXTURE_TOOL_ID": {
            "type": "client",
            "name": "set_floor_texture",
            "description": "Covers the scanned floor with a material from Poly Haven at real size.",
            "expects_response": True,
            "response_timeout_secs": 20,
            "parameters": {"type": "object", "required": ["query"], "properties": {
                "query": text("Material search, e.g. 'oak boards', 'white marble', 'dark carpet'."),
            }},
        },
        "ELEVENLABS_RESET_FLOOR_TOOL_ID": {
            "type": "client",
            "name": "reset_floor",
            "description": "Restores the floor's captured appearance.",
            "expects_response": True,
            "response_timeout_secs": 10,
        },
        "ELEVENLABS_OBJECT_TEXTURE_TOOL_ID": {
            "type": "client",
            "name": "set_object_texture",
            "description": "Changes the material of a scanned or added editable object.",
            "expects_response": True,
            "response_timeout_secs": 20,
            "parameters": {"type": "object", "required": ["query"], "properties": {
                "name": text("The scanned or added object to edit; empty means the latest."),
                "query": text("Material search, e.g. 'red velvet', 'walnut wood', 'black leather'."),
            }},
        },
        "ELEVENLABS_RESIZE_OBJECT_TOOL_ID": {
            "type": "client",
            "name": "resize_object",
            "description": "Changes a scanned or added object's real-world size, allowing free overlap.",
            "expects_response": True,
            "response_timeout_secs": 10,
            "parameters": {"type": "object", "required": ["height_m"], "properties": {
                "name": text("The scanned or added object to resize; empty means the latest."),
                "height_m": {"type": "number", "description": "The requested absolute height in metres."},
            }},
        },
        "ELEVENLABS_LIGHTING_TOOL_ID": {
            "type": "client",
            "name": "set_lighting",
            "description": "Changes the preview's room-wide brightness and colour temperature.",
            "expects_response": True,
            "response_timeout_secs": 10,
            "parameters": {"type": "object", "required": [], "properties": {
                "brightness": {"type": "number", "description": "Brightness from 0 (dim) to 1 (bright)."},
                "warmth": {"type": "number", "description": "Colour from 0 (cool daylight) to 1 (warm amber)."},
            }},
        },
        "ELEVENLABS_ENCLOSURE_TOOL_ID": {
            "type": "client",
            "name": "set_enclosure",
            "description": "Adds or removes a ceiling and closes or reopens missing boundary walls.",
            "expects_response": True,
            "response_timeout_secs": 10,
            "parameters": {"type": "object", "required": [], "properties": {
                "ceiling": {"type": "boolean", "description": "True to add a ceiling, false to remove it."},
                "open_walls": {"type": "boolean", "description": "True to close open walls, false to remove added walls."},
            }},
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
            # Voice calls are billed by connection duration. End quiet calls
            # promptly and cap accidental sessions at the API's 60-second minimum.
            "turn": {"turn_timeout": 30, "silence_end_call_timeout": 12},
            "conversation": {"max_duration_seconds": 60},
        },
        "platform_settings": {
            "auth": {"enable_auth": False},
            "call_limits": {"daily_limit": 25, "agent_concurrency_limit": 1},
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
