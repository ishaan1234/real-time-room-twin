# RoomTwin

Real-time room scanning on an iPhone or iPad with LiDAR. It implements the mesh representation from
Dong et al., *An Efficient Volumetric Mesh Representation for Real-time Scene Reconstruction using
Spatial Hashing* (ICRA 2018), in Metal.

- **Spatial hashing:** space is split into 8×8×8 blocks of cubes, allocated only near surfaces.
- **Mesh stored in the volume:** each cube owns the 3 edges leaving its min corner, so every vertex
  is stored once and found with one hash lookup.
- **Incremental meshing:** only blocks touched by the current frame are remeshed. Cubes whose type
  didn't change keep their triangles, and only their vertices move.
- **GPU memory pools:** vertices and triangles live in pools with free lists and reference counts.
  The pools are drawn directly, with no per-frame mesh extraction.

## Run it on your iPhone

1. Open `RoomTwin.xcodeproj` in Xcode.
2. Select the **RoomTwin** target, open **Signing & Capabilities**, and pick your **Team**. A free
   personal team works. If Xcode says the bundle identifier is taken, change
   `dev.bugatti.RoomTwin` to something unique.
3. Connect the iPhone. On the phone, turn on **Settings › Privacy & Security › Developer Mode**.
4. Pick the phone as the run destination and press **Run**. With a free team, the first launch asks
   you to trust the developer under **Settings › General › VPN & Device Management**.

You need a device with LiDAR: iPhone 12 Pro or a later Pro model, or an iPad Pro.

**In the app:** the camera view opens paused. Tap **Start Scan** and pick the kind of scan:
**Detailed Mesh** (below) or **Room Layout** (RoomPlan, further down).

With Detailed Mesh, move slowly and the mesh builds up over the camera view. Frames are only added
while ARKit is tracking normally; otherwise a hint above the buttons says why (moving too fast, not
enough light or texture, still starting up).

- **Pause/Scan** stops or resumes fusion.
- **Color/Shaded/Camera** switches how the mesh is shown.
- **Reset** clears the scan and goes back to Start Scan, so you can pick either kind again.
- **View** pauses scanning and opens the scan in 3D on the phone, with nothing to export first.
  **Orbit** circles the room like a dollhouse: the near walls and the ceiling drop away. Drag to
  turn, pinch to zoom, and use two fingers to pan. **Walk** puts you where the phone was when you
  tapped View, at the same height. The stick moves you, and dragging anywhere else turns your
  head. The orange marker in Orbit shows where you are. **Close** goes back to the camera, and
  **Scan** carries on adding to the same scan. **Talk** lets you add furniture by voice (see below).
- **Export** writes the scan in two formats and opens the share sheet:
  - `.usdz` previews with Quick Look (spacebar in Finder, or tap it in the Files app).
  - `.ply` is for MeshLab or Blender.

  Saved scans also appear in **Files › On My iPhone › RoomTwin**.

## Accounts

The app opens on a login screen: a username and password, nothing else. **New here? Create an
account** makes one. The session stays in the phone's Keychain, so you only log in once. The
person icon at the top left shows who's logged in and has **Log Out**.

An account holds the objects you scan. After Photo or Walk Around builds a model, **Save to My
Objects** names it and uploads it with its photo. In a room preview, **My Objects** lists them; tap
one and it stands on the floor where you're looking. The voice agent doesn't see these: they're
only added with the button.

Accounts live on Supabase, which the app calls directly, so there's no server of our own. Set it
up once:

1. Make a free Supabase project. Under **Authentication › Sign In / Providers › Email**, turn
   **Confirm email** off. Usernames become placeholder addresses (`name@users.roomtwin.app`)
   that never get mail.
2. Put `SUPABASE_URL`, `SUPABASE_ANON_KEY` and `SUPABASE_DB_URL` (Connect › URI) in `.env.local`.
3. Run `python3 Accounts/setup_supabase.py`. It creates the `objects` table and the private
   `objects` file bucket (`Accounts/schema.sql`), and writes `RoomTwin/supabase.json` for the
   app. Then it checks sign-up, upload, save, list and delete with a throwaway user. Rebuild the
   app afterwards.

The anon key in the app can only do what row-level security allows: each user reads, adds and
deletes their own rows, and files under a folder named after their user ID. The database URL is
only used by the setup script and never goes into the app.

## Furnish by voice

In the room preview, tap **Talk** and say what you want. Tap again to hang up. A conversation also
ends by itself after 3 minutes.

- **"Hey, can you add a chair"** stands one on the floor where the middle of the screen points,
  facing you.
- **"Add a table by the wall"** backs it up to the wall you're looking at, or the nearest one,
  facing into the room. **"…facing the wall"** turns it round with room to sit, like a chair at a
  desk.
- **"Add a lamp and a table by the wall facing out"**: the biggest piece goes first, and the
  others go beside it or on it. **"Put a plant on the table"** sets it on top.
- **"Make the walls red brick"** textures every wall; **"this wall"** only the one in view.
  **"Put the walls back"** undoes it.
- **"Remove the lamp"** takes it away. With no name, the latest piece goes.

Everything stands upright on the floor, and each spot is checked first. If a wall, table or
earlier piece is in the way, it moves to the nearest clear floor you can see. If there's no room,
the agent says so.

**Where the models come from.** Poly Haven first: its models are CC0, true to scale and all
face the same way. The app downloads them at 1k (about a megabyte, a second or two). When Poly
Haven has nothing close in name and size (it has no floor lamp, for one), the model comes from
Sketchfab. It's scaled to the height the agent expects, and its credit (name, author, licence)
shows under the buttons, as CC BY requires. Wall textures are Poly Haven's, tiled at their real
size. The preview says "Powered by Poly Haven", as its API terms ask.

**How it works.** An ElevenLabs agent listens and answers; Claude Haiku 4.5 decides what to do.
Its four tools run in the app: `add_object` (what, an estimated height, placement, facing),
`remove_object`, `set_wall_texture` and `reset_walls`. The app finds the walls itself, as large
vertical planes along the room's two main directions, so it works on mesh scans and RoomPlan rooms
alike. A mesh scan needs its walls actually scanned, though: one that's mostly furniture has few
walls to stand things against.

Set it up once on the Mac:

1. Make an ElevenLabs API key with **ElevenAgents: Write** and **Voices: Read**, and put it in
   `.env.local` as `ELEVENLABS_API_KEY=...`.
2. For Sketchfab, add `SKETCHFAB_API_TOKEN=...` (Sketchfab › Settings › Password & API).
   Downloads count as your account's.
3. With the phone connected and RoomTwin opened once, run `python3 Voice/setup_agent.py`. It
   creates or updates the agent and its tools and saves their IDs in `.env.local`. Then it copies
   the agent ID, and the Sketchfab token if there is one, to the phone. The app moves the token
   into its Keychain and deletes the copy.

The phone never gets the ElevenLabs key. The agent is public, so a leaked ID could start
conversations; the limits of 3 minutes each and 50 a day cap what that could cost.

## Room Layout: RoomPlan

Room Layout uses Apple's RoomPlan instead of our mesh. Apple's view draws white outlines on the
walls, doors, windows and furniture as it finds them, with its own tips ("Move further away"). Walk
round the room, then tap **Done**. RoomPlan tidies the room and shows it, and the bar at the top
counts what it found. **Cancel** drops the scan.

The finished room is built from RoomPlan's boxes: flat walls with doors, windows and openings cut
out, doors and windows as panels, and the floor. Furniture RoomPlan labels as a chair, sofa or table
gets the matching model from `RoomTwin/Library`, stretched to the size RoomPlan measured. Anything
else is a coloured box. Then the same buttons as a mesh scan:

- **View** opens the room in the same 3D preview, with Orbit, Walk and Talk.
- **Export** shares three files from `Documents/RoomPlan-<time>/`: the room as `.usdz` and `.ply`
  (as shown in View), and RoomPlan's `.json`. The JSON lists every wall, door, window and object
  with its category, size and position.
- **New Scan** goes back to Start Scan.

Room Layout scans don't record keyframes, so the Colab furniture pipeline doesn't run on them.

## Objects: Photo and Walk Around

The switch at the top has two ways to turn one object into a 3D model. Either way, when the model is
ready the picture greys out and the model pops out of it and spins. **View in AR** places it in the
room at its real size, and **swiping the model up** sends it to your Mac (see RoomTwin Viewer below).
Models are saved in **Files › RoomTwin › Objects**.

**Walk Around** runs entirely on the phone, with Apple's Object Capture. Point at the object, tap
**Continue**, fit the box around it, tap **Start Capture** and walk slowly all the way round while it
takes photos. Then tap **Finish**, or **Another Pass** to go round again higher or lower. The phone
builds a textured model in a few minutes. Shiny, see-through and very thin objects don't work well.
The photos stay in the capture's folder, so a Mac can rebuild them at higher detail.

**Photo** needs only one photo, but runs on the Colab GPU. Take a photo and tap the object: SAM 3
masks it, and **Large / Medium / Small** pick between its three guesses (a whole chair, its seat, …).
Tap **Generate 3D** and SAM 3D Objects builds the full object, back included, in about 30 seconds,
guessing the sides it can't see. The LiDAR depth sets its real size.

For Photo mode, start the object server on your Mac first, with the phone connected and on the
same Wi-Fi as the Mac:

```sh
bash ObjectServer/start.sh
```

It starts `server.py` (SAM 3) and `generator.py` (SAM 3D Objects) on the Colab session `roomtwin`,
set up with `Furniture/colab_setup.sh`, and tunnels them to the Mac's Wi-Fi address over
`colab ssh`. Then it sends the address and a fresh token to the app. Keep it running while you use
Photo mode. Ctrl-C stops both models and frees the GPU for the room pipeline. If the phone isn't
connected, the script prints the address and token, and you type them in after tapping the server
button in Photo mode.

### RoomTwin Viewer on the Mac

A menu-bar app that waits for models sent from the phone. It covers the screen with an invisible
layer that lets clicks through. When a model arrives, the screen greys out and the model flies up
from the bottom edge, lands and spins. Click anywhere or press Esc to put it away. Received models
are saved in `~/Downloads/RoomTwin`, and the menu-bar icon can show the last one again.

```sh
xcodebuild -project RoomTwin.xcodeproj -scheme RoomTwinViewer -configuration Release \
  -derivedDataPath build/DerivedData -destination 'platform=macOS' build
open build/DerivedData/Build/Products/Release/RoomTwinViewer.app
```

The phone and the Mac find each other directly over Wi-Fi or Bluetooth (Multipeer Connectivity),
so there's no address to set up. Both just need to be nearby with Wi-Fi or Bluetooth on.

## Replace scanned furniture with SAM 3D models

While you scan, the app saves keyframes: about two photos a second, each with its LiDAR depth,
confidence, camera pose and intrinsics. They go into the scan's folder in Documents, next to the
exports. After a scan and an Export, with the phone connected, run:

```sh
bash Furniture/run_on_colab.sh            # newest scan; or pass its RoomTwin-<date> folder name
```

The script copies the scan off the phone and runs four steps on the Colab GPU. Then it writes
`scans/<scan>/twin/room_twin.usdz`, which opens in Quick Look.

1. `segment.py`: SAM 3 masks furniture in every keyframe from text prompts (chair, sofa, table, …).
2. `lift.py`: each keyframe votes on which scan vertices belong to which piece. Floor-height
   vertices never count, since masks spill onto the floor. The step also picks each piece's most
   complete, unclipped view.
3. `generate.py`: SAM 3D Objects builds each piece from that view. A metric point map from the
   LiDAR depth sets its size, and the predicted pose moves it into the room.
4. `assemble.py`: fits each model to its scanned surface with ICP, rigid unless the scan covers most
   of the model, and drops it onto the floor. It removes the scanned piece and writes
   `room_twin.ply` along with the fitted objects and `placement.json`.

`debug/` shows the photo each model came from. Rerun single steps on the VM with
`run_pipeline.sh SCAN generate assemble`, and use `assemble.py --keep 3` to leave object 3 as
scanned. `python3 Furniture/synthetic_test.py` checks steps 2 and 4 on a synthetic room, with no GPU.

SAM 3D Objects needs Linux and an NVIDIA GPU with at least 32 GB, so this runs on a Colab A100.
`Furniture/colab_setup.sh` prepares a fresh VM in about 20 minutes and needs Hugging Face access
to `facebook/sam3` and `facebook/sam-3d-objects`. Object mode shares the same VM, but stop its
server first, because both pipelines together don't fit in 40 GB.

## Check the algorithm on a Mac

`ReconCheck` runs the same reconstruction code on your Mac's GPU against a synthetic room. It
verifies the data-structure invariants (one vertex per edge, exact reference counts, no leaks,
balanced free lists, manifold and consistently wound mesh) and how close the vertices are to the
true surfaces.

```sh
xcodebuild -project RoomTwin.xcodeproj -scheme ReconCheck -configuration Release \
  -derivedDataPath build/DerivedData -destination 'platform=macOS' build
./build/DerivedData/Build/Products/Release/ReconCheck /tmp/roomtwin-check
```

It also writes `synthetic-room.ply`, `synthetic-room.usdz` and two PNG renders to the output folder.

To turn PLY scans into Quick Look–ready USDZ, which writes `scan.usdz` next to each file:

```sh
./build/DerivedData/Build/Products/Release/ReconCheck usdz scans/*.ply
```

Quick Look ignores per-vertex colors, so the USDZ export bakes them into a texture: one 2×2-texel cell
per triangle, laid out in Z-order so mipmapping only blends nearby triangles. That needs 3 vertices per
triangle, which makes the USDZ about 5× larger than the PLY.

## Layout

| Folder | Contents |
|---|---|
| `Reconstruction/` | Shared by both targets. Metal kernels (`Reconstruction.metal`), mesh shaders, the Swift host (`Reconstructor.swift`), PLY and USDZ export, PLY reading. |
| `RoomTwin/` | The iOS app: ARKit session, camera background, SwiftUI controls, login and accounts, the scan preview with its wall finder and furniture placement, the voice agent, Poly Haven and Sketchfab downloads, Photo and Walk Around modes. `Library/` holds the SAM 3D furniture RoomPlan rooms use. |
| `ReconCheck/` | The macOS test tool. |
| `Furniture/` | The furniture-replacement pipeline (SAM 3 + SAM 3D Objects on Colab) and its Mac driver script. |
| `Voice/` | Sets up the ElevenLabs voice agent (`setup_agent.py`) and builds the furniture library from a twin (`make_library.py`). |
| `Accounts/` | The Supabase schema (`schema.sql`) and the script that applies it and points the app at the project (`setup_supabase.py`). |
| `ObjectServer/` | Photo mode's server on the Colab VM (`server.py`, `generator.py`) and the Mac script that starts it. |
| `RoomTwinViewer/` | The Mac menu-bar app that receives models from the phone. |
| `Shared/` | Used by the app and the Viewer: the spinning model view and the transfer's service name. |
| `tools/gen_mc_tables.py` | Generates `Reconstruction/MarchingCubesTables.h`. |

Tunables are in `ReconstructionSettings` (`Reconstruction/Reconstructor.swift`). The defaults are
2 cm voxels, 3.5 m max depth, high-confidence LiDAR pixels only, and about 450 MB of GPU memory.

## Differences from the paper

- **No per-vertex locks.** The paper locks each vertex while it's allocated. Here the first cube to
  claim an edge allocates the vertex with a compare-and-swap, and every other cube reads it in the
  next dispatch. This matters because Metal doesn't guarantee spin locks make progress.
- **Hamming-distance refinement is off by default.** It's implemented
  (`refineThresholdInVoxels`, try 0.3), but neighbouring cubes snap independently. When a surface
  lies within the threshold of a voxel plane, cubes on both sides snap, leaving overlapping sheets
  and cracks. In `ReconCheck` it doubles the open edges and doesn't reduce topology changes. With
  walls aligned exactly to the grid, it cuts changes by 30% but opens 36× more edges.
- **Normals are computed in the fragment shader**, from screen-space derivatives, instead of being
  stored per vertex.
