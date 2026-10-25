import SceneKit
import simd

/// The scan as a SceneKit scene, for looking round it after scanning without
/// exporting. Two cameras: an orbit camera circling the room, and a walking
/// camera at the phone's height that starts where the phone was. Faces
/// pointing away are culled, so from outside the room the near walls and the
/// ceiling vanish and it reads as a dollhouse. Walls are found and kept as
/// their own nodes, so they can be textured and furniture can stand against
/// them.
final class PreviewScene: NSObject, SCNSceneRendererDelegate {
    enum Mode {
        case orbit, walk
    }

    /// Where a new piece goes.
    enum Placement {
        /// On the floor where the middle of the view points.
        case inView
        /// Backed up to the wall the view points at, or the one nearest that.
        case againstWall
        /// Beside a piece added earlier, matched by name; the latest if nil.
        case nextTo(String?)
        /// On top of a piece added earlier.
        case onTopOf(String?)
    }

    /// Which way a new piece's front faces.
    enum Facing {
        case viewer, awayFromWall, towardWall, sameAsReference
    }

    /// Why a piece couldn't be placed, in words for the voice agent.
    struct PlacementError: LocalizedError {
        let errorDescription: String?
    }

    let scene = SCNScene()
    /// Height of the floor, in metres.
    let floorY: Float
    let walls: [Wall]
    /// How far the walking camera moves per second at full stick, in metres.
    var walkSpeed: Float = 1.4
    /// Stick position, each axis -1...1: x strafes right, y walks forward.
    /// Set on the main thread, read on SceneKit's render thread.
    var move = SIMD2<Float>.zero

    private let orbitCamera = SCNNode()
    private let orbitTarget: SIMD3<Float>
    /// Carries the walking camera's position and heading; `head` adds the pitch.
    private let walker = SCNNode()
    private let head = SCNNode()
    /// Shows where the walking camera is when orbiting.
    private let marker = SCNNode()
    /// Furniture added with `place`, oldest first.
    private let furniture = SCNNode()
    private let floorPlan: FloorPlan
    /// One per wall: its node and its two looks, scanned colours or a texture.
    private var wallNodes: [(node: SCNNode, colored: SCNGeometry, bare: SCNGeometry)] = []
    /// Category of nodes that placing furniture can land on or against.
    private static let solid = 1
    private var yaw: Float = 0
    private var pitch: Float = 0
    private var mode: Mode?
    private weak var view: SCNView?
    private var lastUpdate: TimeInterval?

    /// `viewer` is the phone's camera-to-world transform when the scan
    /// stopped, in the mesh's frame. Without it the walk starts in the
    /// middle of the room at standing height.
    init(mesh: MeshSnapshot, viewer: simd_float4x4?) {
        let (lo, hi) = Self.coreBounds(mesh)
        orbitTarget = (lo + hi) / 2
        floorY = Self.floorHeight(mesh) ?? lo.y
        floorPlan = FloorPlan(mesh, floorY: floorY)
        walls = WallFinder.walls(in: mesh, floorY: floorY)
        super.init()
        scene.background.contents = PlatformColor(white: 0.08, alpha: 1)
        buildRoom(mesh)
        scene.rootNode.addChildNode(furniture)
        addLights()

        let eye = viewer.map { SIMD3($0.columns.3.x, $0.columns.3.y, $0.columns.3.z) }
            ?? SIMD3(orbitTarget.x, floorY + 1.5, orbitTarget.z)
        // The camera looks down its -z axis.
        let forward = viewer.map { -simd_normalize(SIMD3($0.columns.2.x, $0.columns.2.y, $0.columns.2.z)) }
            ?? SIMD3(0, 0, -1)
        yaw = atan2(-forward.x, -forward.z)
        pitch = min(max(asin(forward.y), -1.2), 1.2)
        walker.simdPosition = eye
        head.camera = Self.camera(fieldOfView: 75, zNear: 0.05)
        walker.addChildNode(head)
        Self.buildMarker(marker)
        walker.addChildNode(marker)
        scene.rootNode.addChildNode(walker)
        applyLook()

        // Behind and above where the phone was looking, far enough to fit the room.
        let radius = max(simd_length(SIMD2(hi.x - lo.x, hi.z - lo.z)) / 2, 1)
        var back = SIMD3(-forward.x, 0, -forward.z)
        back = simd_length(back) > 1e-3 ? simd_normalize(back) : SIMD3(0, 0, 1)
        let elevation: Float = 0.9
        let distance = 1.1 * radius / tan(Float(25).radians)
        orbitCamera.camera = Self.camera(fieldOfView: 50, zNear: 0.1)
        orbitCamera.simdPosition = orbitTarget + distance * (cos(elevation) * back + SIMD3(0, sin(elevation), 0))
        orbitCamera.simdLook(at: orbitTarget, up: SIMD3(0, 1, 0), localFront: SIMD3(0, 0, -1))
        scene.rootNode.addChildNode(orbitCamera)
    }

    /// Switches cameras. In orbit mode SceneKit's own camera control handles
    /// drag, pinch and two-finger pan; in walk mode the caller feeds `move`
    /// and `look(by:)`.
    func show(_ mode: Mode, in view: SCNView) {
        guard mode != self.mode || view !== self.view else { return }
        self.mode = mode
        self.view = view
        marker.isHidden = mode == .walk
        switch mode {
        case .orbit:
            view.pointOfView = orbitCamera
            view.allowsCameraControl = true
            view.defaultCameraController.interactionMode = .orbitTurntable
            view.defaultCameraController.inertiaEnabled = true
            view.defaultCameraController.worldUp = SCNVector3(0, 1, 0)
            view.defaultCameraController.target = SCNVector3(orbitTarget.x, orbitTarget.y, orbitTarget.z)
        case .walk:
            view.allowsCameraControl = false
            view.pointOfView = head
        }
    }

    /// Turns the walking camera by a drag, in points.
    func look(by drag: CGSize) {
        let radiansPerPoint: Float = 0.006
        yaw -= Float(drag.width) * radiansPerPoint
        pitch = min(max(pitch - Float(drag.height) * radiansPerPoint, -1.2), 1.2)
        applyLook()
    }

    private func applyLook() {
        walker.simdOrientation = simd_quatf(angle: yaw, axis: SIMD3(0, 1, 0))
        head.simdOrientation = simd_quatf(angle: pitch, axis: SIMD3(1, 0, 0))
    }

    func renderer(_ renderer: SCNSceneRenderer, updateAtTime time: TimeInterval) {
        defer { lastUpdate = time }
        guard let last = lastUpdate, mode == .walk, move != .zero else { return }
        // Walking stays level whatever the pitch.
        let forward = SIMD3(-sin(yaw), 0, -cos(yaw)), right = SIMD3(cos(yaw), 0, -sin(yaw))
        let step = walkSpeed * Float(min(max(time - last, 0), 0.1))
        walker.simdPosition += (forward * move.y + right * move.x) * step
    }

    // MARK: Furniture

    /// Stands a piece of furniture in the room, upright on the floor (or on
    /// another piece), and drops it in. `model` must stand on y = 0, centred,
    /// with its front facing +z. Each spot is checked against the scan and
    /// earlier pieces; if something's in the way, it tries the nearest clear
    /// spot the viewer can see. Returns where it went, in words for the
    /// voice agent. Throws `PlacementError` if there's nowhere to put it.
    func place(_ model: SCNNode, _ placement: Placement = .inView, facing: Facing? = nil) throws -> String {
        let (lo, hi) = model.boundingBox
        let half = SIMD2(Float(hi.x - lo.x), Float(hi.z - lo.z)) / 2
        let camera = view?.pointOfView ?? head
        let eye = camera.simdWorldPosition
        let gaze = self.gaze(from: camera)

        let spot: SIMD3<Float>, yaw: Float, words: String
        switch placement {
        case .inView:
            let wall = facing == .awayFromWall || facing == .towardWall ? nearestWall(to: gaze.point) : nil
            let found = try searchAround(gaze.point, eye: eye, ahead: gaze.ahead, half: half) { candidate in
                self.turn(facing ?? .viewer, at: candidate, eye: eye, wall: wall, reference: nil)
            }
            (spot, yaw) = (found.spot, found.yaw)
            words = String(format: "on the floor %.1f metres from the user, ", horizontalDistance(spot, eye))
                + describe(facing ?? .viewer) + (found.visible ? "" : ", but out of sight behind something")
        case .againstWall:
            // The wall in view first, then the others nearest first.
            let candidates = (gaze.wall.map { [$0] } ?? [])
                + walls.filter { $0.faces != gaze.wall?.faces }.sorted { cost($0, gaze.point) < cost($1, gaze.point) }
            guard !candidates.isEmpty else {
                throw PlacementError(errorDescription: "No walls were found in the scan, only furniture and floor.")
            }
            var placed: (spot: SIMD3<Float>, yaw: Float, visible: Bool)?
            for wall in candidates {
                if let found = try? searchAlong(wall, near: gaze.point, eye: eye, half: half, facing: facing ?? .awayFromWall) {
                    placed = found
                    break
                }
            }
            guard let placed else {
                throw PlacementError(errorDescription: "No wall has a clear stretch of floor wide enough in front of it.")
            }
            (spot, yaw) = (placed.spot, placed.yaw)
            words = "against the wall \(direction(of: spot, from: eye)) of the user, " + describe(facing ?? .awayFromWall)
                + (placed.visible ? "" : ", out of sight behind something")
        case .nextTo(let name):
            let reference = try piece(named: name)
            let found = try searchBeside(reference, eye: eye, half: half, facing: facing ?? .sameAsReference)
            (spot, yaw) = (found.spot, found.yaw)
            words = "next to the \(reference.name ?? "piece"), on its \(found.side), " + describe(facing ?? .sameAsReference)
        case .onTopOf(let name):
            let reference = try piece(named: name)
            let top = Self.bounds(reference).hi.y + reference.simdPosition.y
            spot = SIMD3(reference.simdPosition.x, top, reference.simdPosition.z)
            yaw = turn(facing ?? .sameAsReference, at: spot, eye: eye, wall: nil, reference: reference)
            words = "on top of the \(reference.name ?? "piece")"
        }

        // The holder takes its final place at once, so a request straight
        // after this one sees it where it'll be; the model inside drops in.
        let holder = SCNNode()
        holder.name = model.name
        holder.simdOrientation = simd_quatf(angle: yaw, axis: SIMD3(0, 1, 0))
        holder.simdPosition = spot
        holder.addChildNode(model)
        furniture.addChildNode(holder)
        model.simdPosition = SIMD3(0, 0.4, 0)
        model.opacity = 0
        let drop = SCNAction.move(to: SCNVector3Zero, duration: 0.35)
        drop.timingMode = .easeIn
        model.runAction(.group([.fadeIn(duration: 0.2), drop]))
        return words
    }

    /// Takes away a piece: the latest whose name contains `name`, or the
    /// latest of all. Returns its name, or nil if there's no such piece.
    func removeFurniture(named name: String? = nil) -> String? {
        guard let model = try? piece(named: name) else { return nil }
        // Out of the list straight away, so it's neither removed twice nor placed against while it fades.
        model.removeFromParentNode()
        model.enumerateHierarchy { node, _ in node.categoryBitMask = 0 }
        scene.rootNode.addChildNode(model)
        model.removeAllActions()
        model.runAction(.sequence([.fadeOut(duration: 0.2), .removeFromParentNode()]))
        return model.name
    }

    /// What has been added, oldest first.
    var furnitureNames: [String] {
        furniture.childNodes.compactMap(\.name)
    }

    /// Where the middle of the view points: the floor spot there (or just
    /// this side of whatever it hits), the wall it hits if it's a wall, and
    /// the level direction of view.
    private func gaze(from camera: SCNNode) -> (point: SIMD3<Float>, wall: Wall?, ahead: SIMD3<Float>) {
        let eye = camera.simdWorldPosition, front = camera.simdWorldFront
        var ahead = SIMD3(front.x, 0, front.z)
        ahead = simd_length(ahead) > 1e-3 ? simd_normalize(ahead) : SIMD3(0, 0, -1)
        var point = eye + 1.5 * ahead
        var wall: Wall?
        // The middle of the screen is straight along the camera's front.
        if let hit = scene.rootNode.hitTestWithSegment(
            from: SCNVector3(eye), to: SCNVector3(eye + 30 * front),
            options: [SCNHitTestOption.categoryBitMask.rawValue: Self.solid,
                      SCNHitTestOption.searchMode.rawValue: SCNHitTestSearchMode.closest.rawValue]).first {
            point = hit.simdWorldCoordinates
            wall = wallNodes.firstIndex { $0.node === hit.node }.map { walls[$0] }
            if abs(point.y - floorY) > 0.1 {
                // Not floor: start clear of whatever it is.
                point -= 0.35 * ahead
            }
        }
        point.y = floorY
        return (point, wall, ahead)
    }

    /// The wall closest to a floor point that's in front of it.
    private func nearestWall(to point: SIMD3<Float>) -> Wall? {
        walls.filter { $0.distance(to: point) > -0.15 }.min { cost($0, point) < cost($1, point) }
    }

    private func cost(_ wall: Wall, _ point: SIMD3<Float>) -> Float {
        let s = simd_dot(point, wall.along)
        let beyond = max(wall.span.lowerBound - s, s - wall.span.upperBound, 0)
        return abs(wall.distance(to: point)) + beyond
    }

    /// The nearest clear spot to `target`, in rings 15 cm apart, each tried
    /// from the viewer's side outwards; a spot the viewer can see wins over
    /// a nearer one they can't.
    private func searchAround(_ target: SIMD3<Float>, eye: SIMD3<Float>, ahead: SIMD3<Float>, half: SIMD2<Float>,
                              turn: (SIMD3<Float>) -> Float) throws -> (spot: SIMD3<Float>, yaw: Float, visible: Bool) {
        var hidden: (SIMD3<Float>, Float)?
        let towardsViewer = atan2(-ahead.z, -ahead.x)
        for ring in 0...8 {
            let count = max(1, 6 * ring)
            for i in 0..<count {
                let angle = towardsViewer + Float((i + 1) / 2) * (i % 2 == 0 ? 1 : -1) * 2 * .pi / Float(count)
                let candidate = target + Float(ring) * 0.15 * SIMD3(cos(angle), 0, sin(angle))
                // Not behind the viewer, nor right at their feet when walking.
                if simd_dot(candidate - eye, ahead) < (mode == .walk ? 0.6 + half.y : -.infinity) {
                    continue
                }
                let heading = turn(candidate)
                guard hasRoom(Footprint(centre: SIMD2(candidate.x, candidate.z), half: half, yaw: heading)) else { continue }
                if canSee(candidate + SIMD3(0, 0.4, 0), from: eye) {
                    return (candidate, heading, true)
                }
                hidden = hidden ?? (candidate, heading)
            }
        }
        guard let hidden else {
            throw PlacementError(errorDescription: "There's no clear floor where the user is looking. "
                                 + "They should look at an open bit of floor and ask again.")
        }
        return (hidden.0, hidden.1, false)
    }

    /// The clear spot along a wall nearest to where `target` is beside it.
    private func searchAlong(_ wall: Wall, near target: SIMD3<Float>, eye: SIMD3<Float>, half: SIMD2<Float>,
                             facing: Facing) throws -> (spot: SIMD3<Float>, yaw: Float, visible: Bool) {
        let towardWall = facing == .towardWall
        // Backed up to the wall, or facing it with room to sit.
        let standoff = half.y + (towardWall ? 0.45 : 0.03)
        let outward = atan2(wall.normal.x, wall.normal.z)
        let turn = towardWall ? outward + .pi : outward
        let low = wall.span.lowerBound + half.x, high = wall.span.upperBound - half.x
        let start = low <= high ? min(max(simd_dot(target, wall.along), low), high) : (low + high) / 2
        var hidden: SIMD3<Float>?
        for step in 0...40 {
            let s = start + Float((step + 1) / 2) * (step % 2 == 0 ? 1 : -1) * 0.15
            guard low > high || (low...high).contains(s) else { continue }
            let candidate = wall.point(along: s, standoff: standoff, floorY: floorY)
            guard hasRoom(Footprint(centre: SIMD2(candidate.x, candidate.z), half: half, yaw: turn)) else { continue }
            if canSee(candidate + SIMD3(0, 0.4, 0), from: eye) {
                return (candidate, turn, true)
            }
            hidden = hidden ?? candidate
        }
        guard let hidden else {
            throw PlacementError(errorDescription: "That wall has no clear stretch of floor wide enough.")
        }
        return (hidden, turn, false)
    }

    /// A clear spot beside a piece: on its right, then its left, moving out
    /// in 15 cm steps. Backs line up, so a row along a wall stays against it.
    private func searchBeside(_ reference: SCNNode, eye: SIMD3<Float>, half: SIMD2<Float>,
                              facing: Facing) throws -> (spot: SIMD3<Float>, yaw: Float, side: String) {
        let (lo, hi) = Self.bounds(reference)
        let referenceHalf = SIMD2(hi.x - lo.x, hi.z - lo.z) / 2
        let rotation = reference.simdOrientation
        let right = rotation.act(SIMD3(1, 0, 0)), front = rotation.act(SIMD3(0, 0, 1))
        for gap in [0.1, 0.25, 0.4] as [Float] {
            for (sign, side) in [(Float(1), "right"), (-1, "left")] {
                var candidate = reference.simdPosition + sign * (referenceHalf.x + half.x + gap) * right
                    + (half.y - referenceHalf.y) * front
                candidate.y = floorY
                let turn = self.turn(facing, at: candidate, eye: eye, wall: nearestWall(to: candidate), reference: reference)
                if hasRoom(Footprint(centre: SIMD2(candidate.x, candidate.z), half: half, yaw: turn)) {
                    return (candidate, turn, side)
                }
            }
        }
        throw PlacementError(errorDescription: "There's no room on either side of the \(reference.name ?? "piece").")
    }

    private func turn(_ facing: Facing, at spot: SIMD3<Float>, eye: SIMD3<Float>, wall: Wall?,
                      reference: SCNNode?) -> Float {
        // Models face +z; a turn of a about +y points that at (sin a, cos a).
        switch facing {
        case .awayFromWall where wall != nil:
            return atan2(wall!.normal.x, wall!.normal.z)
        case .towardWall where wall != nil:
            return atan2(-wall!.normal.x, -wall!.normal.z)
        case .sameAsReference where reference != nil:
            let front = reference!.simdOrientation.act(SIMD3(0, 0, 1))
            return atan2(front.x, front.z)
        default:
            return atan2(eye.x - spot.x, eye.z - spot.z)
        }
    }

    private func describe(_ facing: Facing) -> String {
        switch facing {
        case .viewer: "facing the user"
        case .awayFromWall: "facing out into the room"
        case .towardWall: "facing the wall"
        case .sameAsReference: "facing the same way"
        }
    }

    /// Where `point` is from the walking viewer: ahead, on the left, …
    private func direction(of point: SIMD3<Float>, from eye: SIMD3<Float>) -> String {
        let forward = SIMD2(-sin(yaw), -cos(yaw)), right = SIMD2(cos(yaw), -sin(yaw))
        let offset = SIMD2(point.x - eye.x, point.z - eye.z)
        let (f, r) = (simd_dot(offset, forward), simd_dot(offset, right))
        let side = abs(f) >= abs(r) ? (f >= 0 ? "in front" : "behind") : (r >= 0 ? "to the right" : "to the left")
        return String(format: "%@, %.1f metres away,", side, simd_length(offset))
    }

    private func horizontalDistance(_ a: SIMD3<Float>, _ b: SIMD3<Float>) -> Float {
        simd_length(SIMD2(a.x - b.x, a.z - b.z))
    }

    /// The latest piece whose name contains `name`, or the latest of all.
    private func piece(named name: String?) throws -> SCNNode {
        let pieces = furniture.childNodes.reversed()
        let wanted = name?.lowercased().trimmingCharacters(in: .whitespaces) ?? ""
        let match = wanted.isEmpty ? pieces.first
            : pieces.first { ($0.name ?? "").lowercased().contains(wanted) }
            ?? pieces.first { node in wanted.split(separator: " ").contains { (node.name ?? "").lowercased().contains($0) } }
        guard let match else {
            throw PlacementError(errorDescription: pieces.isEmpty ? "Nothing has been added yet."
                                 : "Nothing added is called \(wanted). Added so far: \(furnitureNames.joined(separator: ", ")).")
        }
        return match
    }

    /// Whether a footprint is on clear floor and clear of furniture already added.
    private func hasRoom(_ footprint: Footprint) -> Bool {
        guard floorPlan.isClear(footprint) else { return false }
        return furniture.childNodes.allSatisfy { piece in
            let (lo, hi) = Self.bounds(piece)
            let front = piece.simdOrientation.act(SIMD3(0, 0, 1))
            let other = Footprint(centre: SIMD2(piece.simdPosition.x, piece.simdPosition.z),
                                  half: SIMD2(hi.x - lo.x, hi.z - lo.z) / 2, yaw: atan2(front.x, front.z))
            // Something standing on another piece doesn't take floor.
            return piece.simdPosition.y > floorY + 0.05 || !footprint.overlaps(other)
        }
    }

    /// A placed piece's extent in its holder, as it'll be once it has dropped in.
    private static func bounds(_ holder: SCNNode) -> (lo: SIMD3<Float>, hi: SIMD3<Float>) {
        let (lo, hi) = holder.childNodes.first?.boundingBox ?? holder.boundingBox
        return (SIMD3(Float(lo.x), Float(lo.y), Float(lo.z)), SIMD3(Float(hi.x), Float(hi.y), Float(hi.z)))
    }

    private func canSee(_ point: SIMD3<Float>, from eye: SIMD3<Float>) -> Bool {
        scene.rootNode.hitTestWithSegment(from: SCNVector3(eye), to: SCNVector3(point),
                                          options: [SCNHitTestOption.categoryBitMask.rawValue: Self.solid,
                                                    SCNHitTestOption.searchMode.rawValue: SCNHitTestSearchMode.any.rawValue])
            .isEmpty
    }

    // MARK: Walls

    /// Covers walls with a tiling texture whose image spans `size` metres,
    /// or puts the scanned colours back if `image` is nil. `wallsInView`
    /// limits it to the wall the middle of the view points at. Returns how
    /// many walls changed.
    @discardableResult
    func setWallTexture(_ image: Any?, size: SIMD2<Float> = .one, wallsInView: Bool = false) throws -> Int {
        var chosen = Array(wallNodes.indices)
        if wallsInView {
            let camera = view?.pointOfView ?? head
            let gaze = self.gaze(from: camera)
            guard let wall = gaze.wall ?? nearestWall(to: gaze.point),
                  let index = walls.firstIndex(where: { $0.faces == wall.faces }) else {
                throw PlacementError(errorDescription: "The user isn't looking at a wall.")
            }
            chosen = [index]
        }
        guard !chosen.isEmpty else { throw PlacementError(errorDescription: "No wall was found in the scan.") }
        for i in chosen {
            let wall = wallNodes[i]
            guard let image else {
                wall.node.geometry = wall.colored
                continue
            }
            let material = Self.scanMaterial()
            material.diffuse.contents = image
            material.diffuse.wrapS = .repeat
            material.diffuse.wrapT = .repeat
            material.diffuse.mipFilter = .linear
            // The wall's texture coordinates are in metres.
            material.diffuse.contentsTransform = SCNMatrix4(simd_float4x4(diagonal: SIMD4(1 / size.x, 1 / size.y, 1, 1)))
            wall.bare.materials = [material]
            wall.node.geometry = wall.bare
        }
        return chosen.count
    }

    // MARK: Building

    /// The scan minus its walls as one node, and each wall as its own.
    private func buildRoom(_ mesh: MeshSnapshot) {
        var isWall = [Bool](repeating: false, count: mesh.faces.count)
        for wall in walls {
            for face in wall.faces { isWall[face] = true }
        }
        var rest = mesh
        rest.faces = zip(mesh.faces, isWall).filter { !$0.1 }.map { $0.0 }
        scene.rootNode.addChildNode(Self.meshNode(rest))

        for wall in walls {
            // Its own copy of its vertices, with texture coordinates in metres
            // along the wall and up from the floor.
            var remap: [UInt32: UInt32] = [:]
            var piece = MeshSnapshot()
            var uvs: [Float] = []
            for face in wall.faces {
                var f = SIMD3<UInt32>()
                for (j, index) in [mesh.faces[face].x, mesh.faces[face].y, mesh.faces[face].z].enumerated() {
                    if let mapped = remap[index] {
                        f[j] = mapped
                        continue
                    }
                    let p = mesh.positions[Int(index)]
                    f[j] = UInt32(piece.positions.count)
                    remap[index] = f[j]
                    piece.positions.append(p)
                    piece.colors.append(mesh.colors[Int(index)])
                    uvs += [simd_dot(p, wall.along) - wall.span.lowerBound, floorY + 3 - p.y]
                }
                piece.faces.append(f)
            }
            let node = Self.meshNode(piece)
            let colored = node.geometry!
            let uvSource = SCNGeometrySource(data: uvs.withUnsafeBytes { Data($0) }, semantic: .texcoord,
                                             vectorCount: uvs.count / 2, usesFloatComponents: true,
                                             componentsPerVector: 2, bytesPerComponent: 4, dataOffset: 0, dataStride: 8)
            let bare = SCNGeometry(sources: colored.sources(for: .vertex) + [uvSource], elements: colored.elements)
            node.name = "wall"
            scene.rootNode.addChildNode(node)
            wallNodes.append((node, colored, bare))
        }
    }

    /// Soft light for added furniture; the scan itself is unlit.
    private func addLights() {
        let ambient = SCNNode()
        ambient.light = SCNLight()
        ambient.light?.type = .ambient
        ambient.light?.intensity = 450
        scene.rootNode.addChildNode(ambient)
        let sun = SCNNode()
        sun.light = SCNLight()
        sun.light?.type = .directional
        sun.light?.intensity = 700
        sun.simdOrientation = simd_quatf(angle: -1.0, axis: simd_normalize(SIMD3(1, 0, 0.4)))
        scene.rootNode.addChildNode(sun)
    }

    /// Height of the floor: the low end of the upward-facing surfaces, as in
    /// Furniture/scan_io.py's estimate_floor but weighted by area, so a floor
    /// of a few big triangles (RoomPlan's) outweighs finely meshed furniture.
    /// Nil if nothing faces up or down.
    private static func floorHeight(_ mesh: MeshSnapshot) -> Float? {
        var up: [(height: Float, area: Float)] = [], down: [(height: Float, area: Float)] = []
        for f in mesh.faces {
            let a = mesh.positions[Int(f.x)], b = mesh.positions[Int(f.y)], c = mesh.positions[Int(f.z)]
            let n = simd_cross(b - a, c - a)
            let length = simd_length(n)
            if n.y > 0.9 * length && length > 0 {
                up.append(((a.y + b.y + c.y) / 3, length / 2))
            } else if n.y < -0.9 * length && length > 0 {
                down.append(((a.y + b.y + c.y) / 3, length / 2))
            }
        }
        // Whichever way the triangles wind, the floor faces one consistent way.
        let upArea = up.reduce(0) { $0 + $1.area }, downArea = down.reduce(0) { $0 + $1.area }
        let faces = (upArea >= downArea ? up : down).sorted { $0.height < $1.height }
        var area = 0.05 * max(upArea, downArea)
        for face in faces {
            area -= face.area
            if area <= 0 { return face.height }
        }
        return faces.last?.height
    }

    /// The box holding all but the outermost 2% of the surface on each axis,
    /// so stray bits seen through a doorway don't push the orbit camera away.
    /// By area, not vertices: in a RoomPlan room the furniture models have
    /// nearly all the vertices but the walls have nearly all the surface.
    private static func coreBounds(_ mesh: MeshSnapshot) -> (lo: SIMD3<Float>, hi: SIMD3<Float>) {
        var total: Float = 0
        let running = mesh.faces.map { f -> Float in
            let a = mesh.positions[Int(f.x)], b = mesh.positions[Int(f.y)], c = mesh.positions[Int(f.z)]
            total += simd_length(simd_cross(b - a, c - a)) / 2
            return total
        }
        // Triangle centres, picked evenly by area.
        let count = min(20_000, mesh.faces.count)
        var face = 0
        let sample = (0..<count).map { k -> SIMD3<Float> in
            let target = (Float(k) + 0.5) / Float(count) * total
            while face < running.count - 1 && running[face] < target { face += 1 }
            let f = mesh.faces[face]
            return (mesh.positions[Int(f.x)] + mesh.positions[Int(f.y)] + mesh.positions[Int(f.z)]) / 3
        }
        var lo = SIMD3<Float>.zero, hi = SIMD3<Float>.zero
        for axis in 0..<3 {
            let values = sample.map { $0[axis] }.sorted()
            lo[axis] = values[values.count * 2 / 100]
            hi[axis] = values[values.count * 98 / 100]
        }
        return (lo, hi)
    }

    /// A mesh with its captured vertex colors, shaded like the live view.
    static func meshNode(_ mesh: MeshSnapshot) -> SCNNode {
        let positions = mesh.positions.withUnsafeBytes { Data($0) }
        var colors = [Float](), indices = [UInt32]()
        colors.reserveCapacity(mesh.colors.count * 3)
        indices.reserveCapacity(mesh.faces.count * 3)
        for c in mesh.colors {
            colors += [Float(c.x) / 255, Float(c.y) / 255, Float(c.z) / 255]
        }
        for f in mesh.faces {
            indices += [f.x, f.y, f.z]
        }
        let geometry = SCNGeometry(
            sources: [
                // SIMD3<Float> is padded to 16 bytes.
                SCNGeometrySource(data: positions, semantic: .vertex, vectorCount: mesh.positions.count,
                                  usesFloatComponents: true, componentsPerVector: 3, bytesPerComponent: 4,
                                  dataOffset: 0, dataStride: MemoryLayout<SIMD3<Float>>.stride),
                SCNGeometrySource(data: colors.withUnsafeBytes { Data($0) }, semantic: .color,
                                  vectorCount: mesh.colors.count, usesFloatComponents: true, componentsPerVector: 3,
                                  bytesPerComponent: 4, dataOffset: 0, dataStride: 12),
            ],
            elements: [SCNGeometryElement(data: indices.withUnsafeBytes { Data($0) }, primitiveType: .triangles,
                                          primitiveCount: mesh.faces.count, bytesPerIndex: 4)])
        geometry.materials = [scanMaterial()]
        let node = SCNNode(geometry: geometry)
        node.categoryBitMask = solid
        return node
    }

    /// The same shading as the live Color view: the surface's colour, darker
    /// where a face is seen edge-on, with a flat normal from screen-space
    /// derivatives. Unlit, as the scanned colours already hold the room's light.
    private static func scanMaterial() -> SCNMaterial {
        let material = SCNMaterial()
        material.lightingModel = .constant
        material.diffuse.contents = PlatformColor.white
        material.shaderModifiers = [.fragment: """
            float3 n = normalize(cross(dfdx(_surface.position), dfdy(_surface.position)));
            float facing = abs(dot(n, normalize(-_surface.position)));
            _output.color.rgb *= 0.6 + 0.4 * facing;
            """]
        return material
    }

    private static func camera(fieldOfView: CGFloat, zNear: Double) -> SCNCamera {
        let camera = SCNCamera()
        // Portrait screen: fix the narrow side's angle.
        camera.projectionDirection = .horizontal
        camera.fieldOfView = fieldOfView
        camera.zNear = zNear
        camera.zFar = 100
        return camera
    }

    /// A dot with a cone pointing the way the walking camera faces.
    private static func buildMarker(_ marker: SCNNode) {
        let material = SCNMaterial()
        material.lightingModel = .constant
        material.diffuse.contents = PlatformColor.systemOrange
        let dot = SCNSphere(radius: 0.12)
        dot.materials = [material]
        let cone = SCNCone(topRadius: 0, bottomRadius: 0.09, height: 0.3)
        cone.materials = [material]
        let pointer = SCNNode(geometry: cone)
        pointer.simdOrientation = simd_quatf(angle: -.pi / 2, axis: SIMD3(1, 0, 0))
        pointer.simdPosition = SIMD3(0, 0, -0.22)
        marker.addChildNode(SCNNode(geometry: dot))
        marker.addChildNode(pointer)
        // Furniture can't be placed against the marker.
        for node in [marker] + marker.childNodes {
            node.categoryBitMask = 2
        }
    }
}

private extension Float {
    var radians: Float { self * .pi / 180 }
}
