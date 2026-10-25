import ARKit
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
        case orbit, walk, ar
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
        /// Mounted on a wall with its bottom at a requested height.
        case onWall
        /// Hanging from the ceiling where the middle of the view points.
        case ceiling
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
    /// Best estimate of the ceiling, or the tops of the walls when the ceiling
    /// itself wasn't scanned.
    let ceilingY: Float
    let walls: [Wall]
    /// How far the walking camera moves per second at full stick, in metres.
    var walkSpeed: Float = 1.4
    /// Stick position, each axis -1...1: x strafes right, y walks forward.
    /// Set on the main thread, read on SceneKit's render thread.
    var move = SIMD2<Float>.zero

    private let orbitCamera = SCNNode()
    /// Follows the live ARKit camera while AR Edit is active.
    private let arCamera = SCNNode()
    private let orbitTarget: SIMD3<Float>
    /// Carries the walking camera's position and heading; `head` adds the pitch.
    private let walker = SCNNode()
    private let head = SCNNode()
    /// Shows where the walking camera is when orbiting.
    private let marker = SCNNode()
    /// RoomPlan furniture and furniture added with `place`, oldest first.
    private let furniture = SCNNode()
    /// Static captured surfaces. Hidden in AR Edit so the live Metal camera
    /// view remains visible underneath this transparent SceneKit overlay.
    private let room = SCNNode()
    /// Optional ceiling and missing boundary walls requested by the user.
    private let enclosure = SCNNode()
    private let floorPlan: FloorPlan
    private let roomLow: SIMD3<Float>
    private let roomHigh: SIMD3<Float>
    private struct SurfaceNode {
        let node: SCNNode
        let colored: SCNGeometry
        let bare: SCNGeometry
        let faces: [Int]
        var isTextured = false
    }
    struct ExportContents {
        let scan: MeshSnapshot
        let replacedScanFaces: Set<Int>
        let nodes: [SCNNode]
    }
    /// One per wall: its node and its two looks, scanned colours or a texture.
    private var wallNodes: [SurfaceNode] = []
    /// The floor is separate from the rest of the scan so its material can be
    /// changed without recolouring tables and other horizontal surfaces.
    private var groundNode: SurfaceNode?
    /// The room lights are kept together so the edited lighting is included in
    /// USDZ exports as well as the interactive preview.
    private let lightRig = SCNNode()
    private let sourceMesh: MeshSnapshot
    /// Category of nodes that placing furniture can land on or against.
    private static let solid = 1
    private static let selectionName = "RoomTwin selection"
    /// Names the furniture in exports, so `restoreFurniture` can find it.
    private static let furnitureName = "RoomTwin furniture"
    /// The piece outlined last.
    private weak var selected: SCNNode?
    private var yaw: Float = 0
    private var pitch: Float = 0
    private var mode: Mode?
    private weak var view: SCNView?
    private var lastUpdate: TimeInterval?
    private struct HandGrab {
        let holder: SCNNode
        let initialPose: Pose
        let initialPosition: SIMD3<Float>
        let planePoint: SIMD3<Float>
        let planeNormal: SIMD3<Float>
        let offset: SIMD3<Float>
        let staysOnFloor: Bool
    }
    /// Where a piece is, how it's turned, and how its model is stretched.
    private struct Pose: Equatable {
        var transform: simd_float4x4
        var scale: SIMD3<Float>

        init(_ holder: SCNNode) {
            transform = holder.simdTransform
            scale = holder.childNodes.first?.simdScale ?? .one
        }

        func apply(to holder: SCNNode) {
            holder.simdTransform = transform
            holder.childNodes.first?.simdScale = scale
        }
    }
    private struct TransformEdit {
        let holder: SCNNode
        let before: Pose
        let after: Pose
    }
    /// The looks set for the whole room, so a preview of the same scan made
    /// longer can take them over (see `continueEdits`).
    private struct Look {
        var walls: (image: Any, size: SIMD2<Float>)?
        var ground: (image: Any, size: SIMD2<Float>)?
        /// Brightness and warmth.
        var lighting: SIMD2<Float>?
        var ceiling: Bool?
        var openWalls: Bool?
    }
    private var look = Look()
    private var handGrab: HandGrab?
    private let gizmo = SCNNode()
    private var gizmoDrag: GizmoDrag?
    private var undoEdits: [TransformEdit] = []
    private var redoEdits: [TransformEdit] = []

    /// `viewer` is the phone's camera-to-world transform when the scan
    /// stopped, in the mesh's frame. Without it the walk starts in the
    /// middle of the room at standing height.
    init(mesh: MeshSnapshot, viewer: simd_float4x4?) {
        sourceMesh = mesh
        let (lo, hi) = Self.coreBounds(mesh)
        roomLow = lo
        roomHigh = hi
        orbitTarget = (lo + hi) / 2
        floorY = Self.floorHeight(mesh) ?? lo.y
        ceilingY = max(hi.y, floorY + 2.2)
        let objectFaces = Set(mesh.editableObjects.flatMap { $0.faces })
        floorPlan = FloorPlan(mesh, floorY: floorY, excludingFaces: objectFaces)
        walls = WallFinder.walls(in: mesh, floorY: floorY, excludingFaces: objectFaces)
        super.init()
        scene.background.contents = PlatformColor(white: 0.08, alpha: 1)
        scene.rootNode.addChildNode(room)
        buildRoom(mesh)
        scene.rootNode.addChildNode(furniture)
        scene.rootNode.addChildNode(enclosure)
        scene.rootNode.addChildNode(lightRig)
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
        arCamera.camera = Self.camera(fieldOfView: 60, zNear: 0.02)
        scene.rootNode.addChildNode(arCamera)
        scene.rootNode.addChildNode(gizmo)
        buildGizmo()
    }

    /// Switches cameras. In orbit mode SceneKit's own camera control handles
    /// drag, pinch and two-finger pan; in walk mode the caller feeds `move`
    /// and `look(by:)`.
    func show(_ mode: Mode, in view: SCNView) {
        guard mode != self.mode || view !== self.view else { return }
        self.mode = mode
        self.view = view
        marker.isHidden = mode != .orbit
        room.isHidden = mode == .ar
        scene.background.contents = mode == .ar ? PlatformColor.clear : PlatformColor(white: 0.08, alpha: 1)
        view.isOpaque = mode != .ar
        view.backgroundColor = mode == .ar ? .clear : PlatformColor(white: 0.08, alpha: 1)
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
        case .ar:
            view.allowsCameraControl = false
            view.pointOfView = arCamera
        }
    }

    /// Keeps SceneKit's virtual camera calibrated to the ARKit frame used by
    /// the Metal camera view below it.
    func updateARCamera(_ frame: ARFrame) {
        guard mode == .ar, let view, view.bounds.width > 0, view.bounds.height > 0 else { return }
        arCamera.simdTransform = frame.camera.transform
        let projection = frame.camera.projectionMatrix(for: .portrait, viewportSize: view.bounds.size,
                                                       zNear: 0.02, zFar: 30)
        arCamera.camera?.projectionTransform = SCNMatrix4(projection)
    }

    /// Converts Vision's portrait, lower-left normalized coordinates into the
    /// UIKit coordinates shared by the cursor and hit testing. The hand is
    /// drawn with the camera image filling the screen and cropped at the
    /// sides (HandMatte), so this goes through the same display transform.
    func screenPoint(forVisionPoint point: CGPoint, in frame: ARFrame) -> CGPoint? {
        guard let view, view.bounds.width > 0, view.bounds.height > 0 else { return nil }
        // Vision saw the landscape camera image turned upright (.right);
        // turn the point back into that image, top-left origin.
        let image = CGPoint(x: 1 - point.y, y: 1 - point.x)
        let screen = image.applying(frame.displayTransform(for: .portrait, viewportSize: view.bounds.size))
        return CGPoint(x: screen.x * view.bounds.width, y: screen.y * view.bounds.height)
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
        // The gizmo stays the same size on screen however far away it is.
        if !gizmo.isHidden, let eye = renderer.pointOfView?.simdWorldPosition {
            gizmo.simdScale = SIMD3(repeating: max(simd_distance(eye, gizmo.simdWorldPosition) * 0.2, 0.05))
        }
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
    func place(_ model: SCNNode, _ placement: Placement = .inView, facing: Facing? = nil,
               elevation: Float? = nil) throws -> String {
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
        case .onWall:
            let candidates = (gaze.wall.map { [$0] } ?? [])
                + walls.filter { $0.faces != gaze.wall?.faces }.sorted { cost($0, gaze.point) < cost($1, gaze.point) }
            let height = Float(hi.y - lo.y)
            var mounted: (spot: SIMD3<Float>, yaw: Float)?
            for wall in candidates {
                if let found = searchOnWall(wall, near: gaze.point, half: half, height: height,
                                            bottom: elevation ?? 1.2, eye: eye) {
                    mounted = found
                    break
                }
            }
            guard let mounted else {
                throw PlacementError(errorDescription: "No wall has a clear visible area large enough for that object.")
            }
            (spot, yaw) = mounted
            words = String(format: "mounted on the wall %.1f metres above the floor", spot.y - floorY)
        case .ceiling:
            let found = try searchCeiling(near: gaze.point, half: half)
            spot = SIMD3(found.x, ceilingY - Float(hi.y - lo.y), found.y)
            yaw = turn(facing ?? .viewer, at: spot, eye: eye, wall: nil, reference: nil)
            words = "on the ceiling " + direction(of: spot, from: eye) + " of the user"
        }

        insert(model, at: spot, yaw: yaw, placement: placement)
        return words
    }

    /// Places a model at a library drag's screen position. Dropping over an
    /// editable piece uses that piece's top surface; elsewhere the screen ray
    /// intersects a stable floor plane. It deliberately does not run collision
    /// rejection, matching the app's free-movement editing behavior.
    func place(_ model: SCNNode, at screenPoint: CGPoint) throws -> String {
        guard let view, let camera = view.pointOfView,
              let ray = ScreenToSceneMapper.ray(in: view, at: screenPoint) else {
            return try place(model)
        }
        let eye = camera.simdWorldPosition
        let spot: SIMD3<Float>
        let placement: Placement
        let words: String
        if let reference = furnitureHolder(at: screenPoint) {
            let top = reference.simdPosition.y + Self.bounds(reference).hi.y
            let hitPoint = view.hitTest(screenPoint, options: [
                SCNHitTestOption.categoryBitMask: Self.solid,
                SCNHitTestOption.searchMode: SCNHitTestSearchMode.closest.rawValue,
            ]).first?.simdWorldCoordinates
            spot = SIMD3(hitPoint?.x ?? reference.simdPosition.x,
                         top,
                         hitPoint?.z ?? reference.simdPosition.z)
            placement = .onTopOf(reference.name)
            words = "on top of the \(reference.name ?? "object")"
        } else if let floorSpot = ScreenToSceneMapper.intersection(of: ray,
                                                                    planePoint: SIMD3(0, floorY, 0),
                                                                    planeNormal: SIMD3(0, 1, 0)),
                  simd_dot(floorSpot - eye, ray.direction) > 0 {
            spot = SIMD3(floorSpot.x, floorY, floorSpot.z)
            placement = .inView
            words = "where it was dropped on the floor"
        } else {
            spot = gaze(from: camera).point
            placement = .inView
            words = "on the floor where the view points"
        }
        let yaw = turn(.viewer, at: spot, eye: eye, wall: nearestWall(to: spot), reference: nil)
        insert(model, at: spot, yaw: yaw, placement: placement)
        return words
    }

    /// The holder takes its final place at once, so another command sees the
    /// object where it will land while the model runs its short drop animation.
    private func insert(_ model: SCNNode, at spot: SIMD3<Float>, yaw: Float, placement: Placement) {
        let holder = SCNNode()
        holder.name = model.name
        holder.simdOrientation = simd_quatf(angle: yaw, axis: SIMD3(0, 1, 0))
        holder.simdPosition = spot
        holder.addChildNode(model)
        addFixtureLightIfNeeded(to: holder, model: model, placement: placement)
        furniture.addChildNode(holder)
        model.simdPosition = SIMD3(0, 0.4, 0)
        model.opacity = 0
        let drop = SCNAction.move(to: SCNVector3Zero, duration: 0.35)
        drop.timingMode = .easeIn
        model.runAction(.group([.fadeIn(duration: 0.2), drop]))
    }

    /// Takes away a piece: the latest whose name contains `name`, or the
    /// latest of all. Returns its name, or nil if there's no such piece.
    func removeFurniture(named name: String? = nil) -> String? {
        guard let model = try? piece(named: name) else { return nil }
        model.childNode(withName: Self.selectionName, recursively: false)?.removeFromParentNode()
        // Out of the list straight away, so it's neither removed twice nor placed against while it fades.
        model.removeFromParentNode()
        model.enumerateHierarchy { node, _ in node.categoryBitMask = 0 }
        scene.rootNode.addChildNode(model)
        model.removeAllActions()
        model.runAction(.sequence([.fadeOut(duration: 0.2), .removeFromParentNode()]))
        return model.name
    }

    /// All editable scanned and added objects, oldest first.
    var furnitureNames: [String] {
        furniture.childNodes.compactMap(\.name)
    }

    /// Selects the editable object under a screen point. RoomPlan objects and
    /// downloaded objects use the same holder, so the same UI edits both.
    @discardableResult
    func selectFurniture(at point: CGPoint) -> String? {
        // A tap on the gizmo keeps the piece it's on.
        if let selected, gizmoHandle(at: point) != nil { return selected.name }
        clearSelection()
        guard let holder = furnitureHolder(at: point) else { return nil }
        select(holder)
        return holder.name
    }

    func clearSelection() {
        selected = nil
        for holder in furniture.childNodes {
            holder.childNode(withName: Self.selectionName, recursively: false)?.removeFromParentNode()
        }
        updateGizmo()
    }

    // MARK: Gizmo

    /// Which handles the gizmo shows, as in Blender: arrows to move along an
    /// axis, rings to turn about one (the red and blue rings tilt), and cubes
    /// to stretch along one, or the white middle cube to scale evenly. Red is
    /// x, green y (up) and blue z. Moving and turning use the room's axes;
    /// stretching uses the piece's own, so the gizmo turns with it then.
    enum GizmoMode {
        case move, rotate, scale
    }

    /// Shows the gizmo on the selected piece.
    var showsGizmo = false {
        didSet { updateGizmo() }
    }

    var gizmoMode = GizmoMode.move {
        didSet { if gizmoMode != oldValue { buildGizmo() } }
    }

    private struct GizmoDrag {
        let holder: SCNNode
        /// 0, 1, 2 for the x, y and z handles; 3 for the middle cube.
        let handle: Int
        let before: Pose
        /// Where the gizmo was, in the room: what the piece turns about.
        let centre: SIMD3<Float>
        /// The handle's direction, in the room.
        let axis: SIMD3<Float>
        /// Where along the axis the drag started, or for turning, the angle on screen.
        let start: Float
        let startPoint: CGPoint
    }

    /// The handle under a screen point: 0, 1, 2 for x, y, z, 3 for the middle cube.
    func gizmoHandle(at point: CGPoint) -> Int? {
        guard let view, !gizmo.isHidden else { return nil }
        let hits = view.hitTest(point, options: [SCNHitTestOption.categoryBitMask: Self.gizmoCategory,
                                                 SCNHitTestOption.searchMode: SCNHitTestSearchMode.closest.rawValue])
        for hit in hits {
            var node: SCNNode? = hit.node
            while let current = node, current !== gizmo {
                if let name = current.name, name.hasPrefix(Self.gizmoHandlePrefix),
                   let handle = Int(name.dropFirst(Self.gizmoHandlePrefix.count)) { return handle }
                node = current.parent
            }
        }
        return nil
    }

    /// Starts dragging the handle under `point`. False if there's none there.
    func beginGizmoDrag(at point: CGPoint) -> Bool {
        guard gizmoDrag == nil, let selected, let view, let handle = gizmoHandle(at: point) else { return false }
        let centre = gizmo.simdWorldPosition
        let axis = handle < 3 ? simd_normalize(gizmo.simdWorldOrientation.act(Self.axes[handle])) : .zero
        let start: Float
        switch gizmoMode {
        case .move, .scale:
            start = handle < 3 ? (ScreenToSceneMapper.ray(in: view, at: point)
                .flatMap { Self.parameter(along: axis, through: centre, closestTo: $0) } ?? 0) : 0
        case .rotate:
            start = screenAngle(of: point, around: centre)
        }
        gizmoDrag = GizmoDrag(holder: selected, handle: handle, before: Pose(selected), centre: centre,
                              axis: axis, start: start, startPoint: point)
        return true
    }

    /// Follows the finger. Each update starts from where the piece was when
    /// the drag began, so nothing drifts. Like Blender, the gizmo doesn't stop
    /// at walls or other pieces; undo puts a piece back.
    func updateGizmoDrag(to point: CGPoint) {
        guard let drag = gizmoDrag, let view else { return }
        drag.before.apply(to: drag.holder)
        switch gizmoMode {
        case .move:
            guard let ray = ScreenToSceneMapper.ray(in: view, at: point),
                  let along = Self.parameter(along: drag.axis, through: drag.centre, closestTo: ray) else { return }
            drag.holder.simdPosition += (along - drag.start) * drag.axis
        case .rotate:
            guard let eye = view.pointOfView?.simdWorldPosition else { return }
            // Anticlockwise on screen is a positive turn about an axis pointing at the viewer.
            let facing: Float = simd_dot(drag.axis, eye - drag.centre) >= 0 ? 1 : -1
            let turn = simd_quatf(angle: (screenAngle(of: point, around: drag.centre) - drag.start) * facing,
                                  axis: drag.axis)
            drag.holder.simdOrientation = turn * drag.holder.simdOrientation
            drag.holder.simdPosition = drag.centre + turn.act(drag.holder.simdPosition - drag.centre)
        case .scale:
            guard let model = drag.holder.childNodes.first else { return }
            var factor: Float
            if drag.handle == 3 {
                // The middle cube: up to grow, down to shrink.
                factor = exp(Float(drag.startPoint.y - point.y) / 150)
            } else {
                guard abs(drag.start) > 1e-4, let ray = ScreenToSceneMapper.ray(in: view, at: point),
                      let along = Self.parameter(along: drag.axis, through: drag.centre, closestTo: ray) else { return }
                factor = along / drag.start
            }
            factor = min(max(factor, 0.05), 20)
            var scale = model.simdScale
            if drag.handle == 3 { scale *= factor } else { scale[drag.handle] *= factor }
            model.simdScale = scale
        }
        select(drag.holder)
    }

    func endGizmoDrag() {
        guard let drag = gizmoDrag else { return }
        gizmoDrag = nil
        if Pose(drag.holder) != drag.before { remember(drag.holder, from: drag.before) }
        select(drag.holder)
    }

    private static let gizmoCategory = 4
    private static let gizmoHandlePrefix = "RoomTwin gizmo "
    private static let axes = [SIMD3<Float>(1, 0, 0), SIMD3<Float>(0, 1, 0), SIMD3<Float>(0, 0, 1)]

    /// The handles for the current mode, each built along +y and turned onto
    /// its axis. Drawn over everything, at a size kept steady on screen (see
    /// `renderer(_:updateAtTime:)`), with a fatter invisible shape round each
    /// so a finger finds it.
    private func buildGizmo() {
        for child in gizmo.childNodes { child.removeFromParentNode() }
        let colours: [PlatformColor] = [.systemRed, .systemGreen, .systemBlue]
        let turns = [simd_quatf(angle: -.pi / 2, axis: SIMD3(0, 0, 1)), simd_quatf(angle: 0, axis: SIMD3(0, 1, 0)),
                     simd_quatf(angle: .pi / 2, axis: SIMD3(1, 0, 0))]
        func part(_ geometry: SCNGeometry, _ colour: PlatformColor?, at height: Float = 0) -> SCNNode {
            geometry.materials = [Self.gizmoMaterial(colour)]
            let node = SCNNode(geometry: geometry)
            node.simdPosition = SIMD3(0, height, 0)
            return node
        }
        for axis in 0..<3 {
            let handle = SCNNode()
            handle.name = Self.gizmoHandlePrefix + "\(axis)"
            handle.simdOrientation = turns[axis]
            let colour = colours[axis]
            switch gizmoMode {
            case .move, .scale:
                handle.addChildNode(part(SCNCylinder(radius: 0.012, height: 0.7), colour, at: 0.35))
                handle.addChildNode(gizmoMode == .move
                                    ? part(SCNCone(topRadius: 0, bottomRadius: 0.05, height: 0.16), colour, at: 0.78)
                                    : part(SCNBox(width: 0.1, height: 0.1, length: 0.1, chamferRadius: 0.01), colour, at: 0.75))
                handle.addChildNode(part(SCNCylinder(radius: 0.08, height: 0.75), nil, at: 0.48))
            case .rotate:
                handle.addChildNode(part(SCNTorus(ringRadius: 0.62, pipeRadius: 0.012), colour))
                handle.addChildNode(part(SCNTorus(ringRadius: 0.62, pipeRadius: 0.07), nil))
            }
            gizmo.addChildNode(handle)
        }
        if gizmoMode == .scale {
            let middle = part(SCNBox(width: 0.13, height: 0.13, length: 0.13, chamferRadius: 0.02), .white)
            middle.name = Self.gizmoHandlePrefix + "3"
            gizmo.addChildNode(middle)
        }
        gizmo.enumerateHierarchy { node, _ in
            node.categoryBitMask = Self.gizmoCategory
            node.renderingOrder = 1000
        }
        updateGizmo()
    }

    /// Puts the gizmo in the middle of the selected piece, or hides it.
    private func updateGizmo() {
        guard showsGizmo, let selected, selected.parent === furniture else {
            gizmo.isHidden = true
            return
        }
        let bounds = Self.bounds(selected)
        gizmo.isHidden = false
        gizmo.simdPosition = selected.simdConvertPosition((bounds.lo + bounds.hi) / 2, to: nil)
        gizmo.simdOrientation = gizmoMode == .scale ? selected.simdWorldOrientation
            : simd_quatf(angle: 0, axis: SIMD3(0, 1, 0))
    }

    /// A colour drawn over everything, flat; nil for an invisible grab area.
    private static func gizmoMaterial(_ colour: PlatformColor?) -> SCNMaterial {
        let material = SCNMaterial()
        material.lightingModel = .constant
        material.diffuse.contents = colour ?? PlatformColor.clear
        material.readsFromDepthBuffer = false
        material.writesToDepthBuffer = false
        if colour == nil { material.colorBufferWriteMask = [] }
        return material
    }

    /// How far along the line through `point` in `direction` it comes
    /// closest to `ray`, or nil when they're nearly parallel.
    private static func parameter(along direction: SIMD3<Float>, through point: SIMD3<Float>,
                                  closestTo ray: ScreenToSceneMapper.Ray) -> Float? {
        let b = simd_dot(direction, ray.direction)
        let denominator = simd_dot(direction, direction) * simd_dot(ray.direction, ray.direction) - b * b
        guard abs(denominator) > 1e-5 else { return nil }
        let offset = point - ray.origin
        return (b * simd_dot(ray.direction, offset) - simd_dot(ray.direction, ray.direction) * simd_dot(direction, offset))
            / denominator
    }

    /// The angle of a screen point about where `centre` shows on screen, anticlockwise.
    private func screenAngle(of point: CGPoint, around centre: SIMD3<Float>) -> Float {
        guard let view else { return 0 }
        let middle = view.projectPoint(SCNVector3(centre))
        return atan2(Float(CGFloat(middle.y) - point.y), Float(point.x - CGFloat(middle.x)))
    }

    // MARK: Hand manipulation

    /// Highlights the object under the hand cursor without starting a grab.
    @discardableResult
    func previewHandTarget(at point: CGPoint) -> String? {
        guard handGrab == nil else { return handGrab?.holder.name }
        clearSelection()
        guard let holder = furnitureHolder(at: point) else { return nil }
        select(holder, color: .systemOrange)
        return holder.name
    }

    /// Locks manipulation to a stable virtual plane selected from the object's
    /// existing placement: the floor, its wall, or a plane facing the viewer.
    /// Hands work while walking, where the view is the walker's own.
    @discardableResult
    func beginHandGrab(at point: CGPoint) -> String? {
        guard mode == .walk, handGrab == nil, let view,
              let holder = furnitureHolder(at: point),
              let ray = ScreenToSceneMapper.ray(in: view, at: point) else { return nil }
        let bounds = Self.bounds(holder)
        let bottom = holder.simdPosition.y + bounds.lo.y
        let staysOnFloor = bottom <= floorY + 0.08
        let planePoint: SIMD3<Float>
        let planeNormal: SIMD3<Float>
        if staysOnFloor {
            planePoint = SIMD3(holder.simdPosition.x, floorY, holder.simdPosition.z)
            planeNormal = SIMD3(0, 1, 0)
        } else if let wall = nearestWall(to: holder.simdPosition), abs(wall.distance(to: holder.simdPosition)) < 0.45 {
            planePoint = holder.simdPosition
            planeNormal = wall.normal
        } else {
            // Unsupported/free-floating pieces move in a camera-facing plane,
            // preserving their distance from the viewer.
            planePoint = holder.simdPosition
            planeNormal = simd_normalize(-ray.direction)
        }
        guard let intersection = ScreenToSceneMapper.intersection(of: ray, planePoint: planePoint,
                                                                  planeNormal: planeNormal) else { return nil }
        handGrab = HandGrab(holder: holder, initialPose: Pose(holder),
                            initialPosition: holder.simdPosition, planePoint: planePoint,
                            planeNormal: planeNormal, offset: holder.simdPosition - intersection,
                            staysOnFloor: staysOnFloor)
        select(holder, color: .systemGreen)
        return holder.name
    }

    /// Moves the grabbed holder freely, with smoothing in world space.
    @discardableResult
    func updateHandGrab(at point: CGPoint) -> Bool {
        guard let grab = handGrab, let view,
              let ray = ScreenToSceneMapper.ray(in: view, at: point),
              let intersection = ScreenToSceneMapper.intersection(of: ray, planePoint: grab.planePoint,
                                                                  planeNormal: grab.planeNormal) else { return false }
        var target = intersection + grab.offset
        if grab.staysOnFloor { target.y = grab.initialPosition.y }
        // Clamp a single update so a reacquired hand cannot teleport a piece.
        let delta = target - grab.holder.simdPosition
        if simd_length(delta) > 0.4 { target = grab.holder.simdPosition + simd_normalize(delta) * 0.4 }
        let candidate = simd_mix(grab.holder.simdPosition, target, SIMD3<Float>(repeating: 0.32))
        return setHandPosition(candidate, for: grab.holder)
    }

    /// Commits one undoable transform when the pinch opens or tracking is lost.
    @discardableResult
    func endHandGrab() -> String? {
        guard let grab = handGrab else { return nil }
        handGrab = nil
        let moved = simd_distance(grab.initialPosition, grab.holder.simdPosition) > 0.003
        if moved { remember(grab.holder, from: grab.initialPose) }
        select(grab.holder)
        return moved ? (grab.holder.name ?? "object") : nil
    }

    var canUndo: Bool { !undoEdits.isEmpty }
    var canRedo: Bool { !redoEdits.isEmpty }

    /// Keeps a hand or gizmo edit for undo.
    private func remember(_ holder: SCNNode, from before: Pose) {
        undoEdits.append(TransformEdit(holder: holder, before: before, after: Pose(holder)))
        if undoEdits.count > 30 { undoEdits.removeFirst() }
        redoEdits.removeAll()
    }

    @discardableResult
    func undoLastEdit() -> String? {
        while let edit = undoEdits.popLast() {
            guard edit.holder.parent === furniture else { continue }
            edit.before.apply(to: edit.holder)
            redoEdits.append(edit)
            select(edit.holder)
            return edit.holder.name
        }
        return nil
    }

    @discardableResult
    func redoLastEdit() -> String? {
        while let edit = redoEdits.popLast() {
            guard edit.holder.parent === furniture else { continue }
            edit.after.apply(to: edit.holder)
            undoEdits.append(edit)
            select(edit.holder)
            return edit.holder.name
        }
        return nil
    }

    private func furnitureHolder(at point: CGPoint) -> SCNNode? {
        guard let view else { return nil }
        for hit in view.hitTest(point, options: [SCNHitTestOption.categoryBitMask: Self.solid,
                                                 SCNHitTestOption.searchMode: SCNHitTestSearchMode.all.rawValue]) {
            var node = hit.node
            while let parent = node.parent, parent !== furniture { node = parent }
            if node.parent === furniture { return node }
        }
        // Thin legs and small props are difficult to hit with a hand cursor.
        // Accept the closest projected object centre within 38 screen points.
        return furniture.childNodes.compactMap { holder -> (SCNNode, CGFloat)? in
            let projected = view.projectPoint(SCNVector3(holder.simdWorldPosition))
            guard projected.z >= 0, projected.z <= 1 else { return nil }
            let distance = hypot(CGFloat(projected.x) - point.x, CGFloat(projected.y) - point.y)
            return distance <= 38 ? (holder, distance) : nil
        }.min { $0.1 < $1.1 }?.0
    }

    private func setHandPosition(_ position: SIMD3<Float>, for holder: SCNNode) -> Bool {
        holder.simdPosition = position
        return true
    }

    /// Moves an editable object relative to the current camera. Horizontal
    /// moves remain on the floor; up/down can reposition wall-mounted pieces.
    @discardableResult
    func moveFurniture(named name: String? = nil, direction: String, distance: Float) throws -> String {
        let holder = try piece(named: name)
        let amount = min(max(distance, 0.05), 3)
        let camera = view?.pointOfView ?? head
        var forward = camera.simdWorldFront
        forward.y = 0
        forward = simd_length_squared(forward) > 1e-5 ? simd_normalize(forward) : SIMD3(0, 0, -1)
        let right = SIMD3(-forward.z, 0, forward.x)
        let delta: SIMD3<Float> = switch direction.lowercased() {
        case "left": -amount * right
        case "right": amount * right
        case "back", "backward", "away": -amount * forward
        case "up": SIMD3(0, amount, 0)
        case "down": SIMD3(0, -amount, 0)
        default: amount * forward
        }
        holder.simdPosition += delta
        select(holder)
        return holder.name ?? "object"
    }

    /// Rotates an editable object freely in place.
    @discardableResult
    func rotateFurniture(named name: String? = nil, degrees: Float) throws -> String {
        let holder = try piece(named: name)
        holder.simdOrientation = simd_quatf(angle: degrees.radians, axis: SIMD3(0, 1, 0))
            * holder.simdOrientation
        select(holder)
        return holder.name ?? "object"
    }

    /// Replaces a scanned or added object while preserving its location and
    /// heading. User edits are intentionally free-form, so the replacement
    /// may overlap scanned geometry or other objects.
    @discardableResult
    func replaceFurniture(named name: String?, with model: SCNNode) throws -> String {
        let old = try piece(named: name)
        old.childNode(withName: Self.selectionName, recursively: false)?.removeFromParentNode()
        let holder = SCNNode()
        holder.name = model.name ?? old.name
        holder.simdPosition = old.simdPosition
        holder.simdOrientation = old.simdOrientation
        holder.addChildNode(model)
        addFixtureLightIfNeeded(to: holder, model: model, placement: .inView)
        furniture.addChildNode(holder)
        old.removeFromParentNode()
        select(holder)
        return holder.name ?? "object"
    }

    /// Changes the visible material on the latest matching added object. The
    /// downloaded models already have UV coordinates; cloning every material
    /// prevents one edit from changing another copy of the same cached model.
    @discardableResult
    func setFurnitureTexture(_ image: Any, named name: String? = nil) throws -> String {
        let holder = try piece(named: name)
        var changed = 0
        holder.enumerateHierarchy { node, _ in
            guard node.name != Self.selectionName else { return }
            guard let geometry = node.geometry else { return }
            let originals = geometry.materials.isEmpty ? [SCNMaterial()] : geometry.materials
            geometry.materials = originals.map { original in
                let material = (original.copy() as? SCNMaterial) ?? SCNMaterial()
                material.lightingModel = .physicallyBased
                material.shaderModifiers = [:]
                material.diffuse.contents = image
                material.diffuse.wrapS = .repeat
                material.diffuse.wrapT = .repeat
                material.diffuse.mipFilter = .linear
                material.metalness.contents = 0.0
                if material.roughness.contents == nil { material.roughness.contents = 0.8 }
                changed += 1
                return material
            }
        }
        guard changed > 0 else {
            throw PlacementError(errorDescription: "The \(holder.name ?? "object") has no editable surface.")
        }
        return holder.name ?? "object"
    }

    /// Scales by a UI-friendly factor using the same absolute-height path as
    /// voice resizing.
    @discardableResult
    func scaleFurniture(named name: String? = nil, by factor: Float) throws -> String {
        let holder = try piece(named: name)
        let bounds = Self.bounds(holder)
        return try resizeFurniture(named: holder.name, height: (bounds.hi.y - bounds.lo.y) * factor)
    }

    /// Uniformly resizes an editable object to an absolute real-world height.
    @discardableResult
    func resizeFurniture(named name: String? = nil, height: Float) throws -> String {
        guard height >= 0.05, height <= 5 else {
            throw PlacementError(errorDescription: "Choose a height between 5 centimetres and 5 metres.")
        }
        let holder = try piece(named: name)
        guard let model = holder.childNodes.first else {
            throw PlacementError(errorDescription: "The \(holder.name ?? "object") can't be resized.")
        }
        model.removeAllActions()
        model.simdPosition = .zero
        model.opacity = 1
        // Scale the normalized content inside the placement wrapper so its
        // holder remains a stable selection and manipulation target.
        let scalable = model.childNodes.first ?? model
        let bounds = Self.bounds(holder)
        let current = max(bounds.hi.y - bounds.lo.y, 1e-4)
        scalable.simdScale *= SIMD3<Float>(repeating: height / current)
        select(holder)
        return holder.name ?? "object"
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
            }
        }
        throw PlacementError(errorDescription: "There's no clear visible floor where the user is looking. "
                             + "They should look at an open bit of floor and ask again.")
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
        for step in 0...40 {
            let s = start + Float((step + 1) / 2) * (step % 2 == 0 ? 1 : -1) * 0.15
            guard low > high || (low...high).contains(s) else { continue }
            let candidate = wall.point(along: s, standoff: standoff, floorY: floorY)
            guard hasRoom(Footprint(centre: SIMD2(candidate.x, candidate.z), half: half, yaw: turn)) else { continue }
            if canSee(candidate + SIMD3(0, 0.4, 0), from: eye) {
                return (candidate, turn, true)
            }
        }
        throw PlacementError(errorDescription: "That wall has no clear visible stretch of floor wide enough.")
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

    /// A ceiling fixture only needs to stay inside the room and clear of other
    /// ceiling fixtures; furniture on the floor must not push it away.
    private func searchCeiling(near target: SIMD3<Float>, half: SIMD2<Float>) throws -> SIMD2<Float> {
        for ring in 0...10 {
            let count = max(1, ring * 8)
            for i in 0..<count {
                let angle = 2 * Float.pi * Float(i) / Float(count)
                let candidate = SIMD2(target.x, target.z) + Float(ring) * 0.15 * SIMD2(cos(angle), sin(angle))
                let footprint = Footprint(centre: candidate, half: half, yaw: 0)
                guard floorPlan.isInside(footprint) else { continue }
                let overlapsFixture = furniture.childNodes.contains { piece in
                    guard piece.simdPosition.y > floorY + 1 else { return false }
                    let bounds = Self.bounds(piece)
                    let front = piece.simdOrientation.act(SIMD3(0, 0, 1))
                    let other = Footprint(centre: SIMD2(piece.simdPosition.x, piece.simdPosition.z),
                                          half: SIMD2(bounds.hi.x - bounds.lo.x, bounds.hi.z - bounds.lo.z) / 2,
                                          yaw: atan2(front.x, front.z))
                    return footprint.overlaps(other, tolerance: -0.08)
                }
                if !overlapsFixture { return candidate }
            }
        }
        throw PlacementError(errorDescription: "There's no clear ceiling area near where the user is looking.")
    }

    /// Finds a clear position on a wall for shelves, cabinets and sconces.
    /// `bottom` is measured from the floor, so voice requests can say things
    /// like “hang it 1.4 metres high”.
    private func searchOnWall(_ wall: Wall, near target: SIMD3<Float>, half: SIMD2<Float>, height: Float,
                              bottom: Float, eye: SIMD3<Float>) -> (spot: SIMD3<Float>, yaw: Float)? {
        let bottom = min(max(bottom, 0.2), max(wall.top - floorY - height - 0.05, 0.2))
        guard floorY + bottom + height <= wall.top + 0.02 else { return nil }
        let low = wall.span.lowerBound + half.x, high = wall.span.upperBound - half.x
        guard low <= high else { return nil }
        let start = min(max(simd_dot(target, wall.along), low), high)
        let yaw = atan2(wall.normal.x, wall.normal.z)
        for step in 0...40 {
            let s = start + Float((step + 1) / 2) * (step % 2 == 0 ? 1 : -1) * 0.12
            guard (low...high).contains(s) else { continue }
            var candidate = wall.point(along: s, standoff: half.y + 0.025, floorY: floorY)
            candidate.y = floorY + bottom
            let footprint = Footprint(centre: SIMD2(candidate.x, candidate.z), half: half, yaw: yaw)
            guard !overlapsAdded(footprint, bottom: candidate.y, top: candidate.y + height),
                  canSee(candidate + SIMD3(0, height / 2, 0), from: eye) else { continue }
            return (candidate, yaw)
        }
        return nil
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
        // The tapped piece first, as added models can share a name.
        if let selected, selected.parent === furniture, selected.name?.lowercased() == wanted { return selected }
        let match = wanted.isEmpty ? pieces.first
            : pieces.first { ($0.name ?? "").lowercased() == wanted }
            ?? pieces.first { ($0.name ?? "").lowercased().contains(wanted) }
            ?? pieces.first { node in wanted.split(separator: " ").contains { (node.name ?? "").lowercased().contains($0) } }
        guard let match else {
            throw PlacementError(errorDescription: pieces.isEmpty ? "No editable objects were found."
                                 : "No editable object is called \(wanted). Available: \(furnitureNames.joined(separator: ", ")).")
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
            // Keep a visible five-centimetre gap; a positive tolerance would
            // allow the bounding boxes to interpenetrate.
            return piece.simdPosition.y > floorY + 0.05 || !footprint.overlaps(other, tolerance: -0.05)
        }
    }

    private func overlapsAdded(_ footprint: Footprint, bottom: Float, top: Float) -> Bool {
        furniture.childNodes.contains { piece in
            let bounds = Self.bounds(piece)
            let otherBottom = piece.simdPosition.y + bounds.lo.y
            let otherTop = piece.simdPosition.y + bounds.hi.y
            guard bottom < otherTop + 0.05, top > otherBottom - 0.05 else { return false }
            let front = piece.simdOrientation.act(SIMD3(0, 0, 1))
            let other = Footprint(centre: SIMD2(piece.simdPosition.x, piece.simdPosition.z),
                                  half: SIMD2(bounds.hi.x - bounds.lo.x, bounds.hi.z - bounds.lo.z) / 2,
                                  yaw: atan2(front.x, front.z))
            return footprint.overlaps(other, tolerance: -0.05)
        }
    }

    private func select(_ holder: SCNNode, color: PlatformColor = .systemOrange) {
        clearSelection()
        selected = holder
        let bounds = Self.bounds(holder)
        let size = simd_max(bounds.hi - bounds.lo, SIMD3<Float>(repeating: 0.03))
        let box = SCNBox(width: CGFloat(size.x + 0.04), height: CGFloat(size.y + 0.04),
                         length: CGFloat(size.z + 0.04), chamferRadius: 0)
        let material = SCNMaterial()
        material.lightingModel = .constant
        material.diffuse.contents = color.withAlphaComponent(0.7)
        material.emission.contents = color
        material.fillMode = .lines
        box.materials = [material]
        let outline = SCNNode(geometry: box)
        outline.name = Self.selectionName
        outline.categoryBitMask = 0
        outline.simdPosition = (bounds.lo + bounds.hi) / 2
        holder.addChildNode(outline)
        updateGizmo()
    }

    /// Lamp models now illuminate the room instead of being decorative only.
    /// The small emissive bulb also makes the light source visible in viewers
    /// that don't import SceneKit light nodes from USDZ.
    private func addFixtureLightIfNeeded(to holder: SCNNode, model: SCNNode, placement: Placement) {
        let words = (model.name ?? "").lowercased()
        guard ["light", "lamp", "chandelier", "sconce", "lantern"].contains(where: words.contains) else { return }
        let bounds = model.boundingBox
        let height = max(Float(bounds.max.y - bounds.min.y), 0.1)
        let bulb = SCNNode()
        bulb.name = "RoomTwin fixture light"
        bulb.light = SCNLight()
        bulb.light?.type = .omni
        bulb.light?.intensity = 850
        bulb.light?.temperature = 3200
        bulb.light?.attenuationStartDistance = 0.5
        bulb.light?.attenuationEndDistance = 6
        bulb.simdPosition = SIMD3(0, {
            if case .ceiling = placement { return max(0.05, height * 0.15) }
            return height * 0.82
        }(), 0)

        let glow = SCNSphere(radius: CGFloat(min(max(height * 0.035, 0.025), 0.08)))
        let glowMaterial = SCNMaterial()
        glowMaterial.lightingModel = .constant
        glowMaterial.diffuse.contents = PlatformColor(white: 1, alpha: 1)
        glowMaterial.emission.contents = PlatformColor(white: 1, alpha: 1)
        glow.materials = [glowMaterial]
        bulb.geometry = glow
        holder.addChildNode(bulb)
    }

    /// A placed piece's extent in its holder, as it'll be once it has dropped
    /// in: with its model's own turn and stretch (the gizmo scales the model),
    /// but not its position, which only the drop-in animation moves.
    private static func bounds(_ holder: SCNNode) -> (lo: SIMD3<Float>, hi: SIMD3<Float>) {
        guard let model = holder.childNodes.first else {
            let (lo, hi) = holder.boundingBox
            return (SIMD3(Float(lo.x), Float(lo.y), Float(lo.z)), SIMD3(Float(hi.x), Float(hi.y), Float(hi.z)))
        }
        let (low, high) = model.boundingBox
        let lo = SIMD3(Float(low.x), Float(low.y), Float(low.z)), hi = SIMD3(Float(high.x), Float(high.y), Float(high.z))
        var transform = model.simdTransform
        transform.columns.3 = SIMD4(0, 0, 0, 1)
        var result = (lo: SIMD3<Float>(repeating: .infinity), hi: SIMD3<Float>(repeating: -.infinity))
        for corner in 0..<8 {
            let local = SIMD3(corner & 1 == 0 ? lo.x : hi.x, corner & 2 == 0 ? lo.y : hi.y, corner & 4 == 0 ? lo.z : hi.z)
            let point = transform * SIMD4(local, 1)
            result.lo = simd_min(result.lo, SIMD3(point.x, point.y, point.z))
            result.hi = simd_max(result.hi, SIMD3(point.x, point.y, point.z))
        }
        return result
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
        if !wallsInView { look.walls = image.map { ($0, size) } }
        for i in chosen {
            let wall = wallNodes[i]
            guard let image else {
                wall.node.geometry = wall.colored
                wallNodes[i].isTextured = false
                continue
            }
            let material = Self.surfaceMaterial(image)
            // The wall's texture coordinates are in metres.
            material.diffuse.contentsTransform = SCNMatrix4(simd_float4x4(diagonal: SIMD4(1 / size.x, 1 / size.y, 1, 1)))
            wall.bare.materials = [material]
            wall.node.geometry = wall.bare
            wallNodes[i].isTextured = true
        }
        return chosen.count
    }

    /// Covers only the scanned floor, never tabletops or other horizontal
    /// objects, with a real-scale tiling material.
    @discardableResult
    func setGroundTexture(_ image: Any?, size: SIMD2<Float> = .one) throws -> Int {
        guard var ground = groundNode else {
            throw PlacementError(errorDescription: "No floor surface was found in the scan.")
        }
        look.ground = image.map { ($0, size) }
        guard let image else {
            ground.node.geometry = ground.colored
            ground.isTextured = false
            groundNode = ground
            return ground.faces.count
        }
        let material = Self.surfaceMaterial(image)
        material.diffuse.contentsTransform = SCNMatrix4(simd_float4x4(diagonal: SIMD4(1 / size.x, 1 / size.y, 1, 1)))
        ground.bare.materials = [material]
        ground.node.geometry = ground.bare
        ground.isTextured = true
        groundNode = ground
        return ground.faces.count
    }

    /// Tunes the preview's real lights. Furniture materials remain PBR, while
    /// the captured scan keeps its baked camera colour.
    func setLighting(brightness: Float, warmth: Float) {
        look.lighting = SIMD2(brightness, warmth)
        let level = min(max(brightness, 0), 1)
        let temperature = CGFloat(6500 - min(max(warmth, 0), 1) * 3800)
        lightRig.enumerateHierarchy { node, _ in
            guard let light = node.light else { return }
            light.temperature = temperature
            light.intensity = light.type == .ambient ? CGFloat(150 + 650 * level) : CGFloat(250 + 950 * level)
        }
    }

    /// Adds or removes a simple room shell where the scan is open. This is an
    /// intentional design edit, so it is kept separate from the untouched
    /// scan and included in edited USDZ exports.
    @discardableResult
    func setEnclosure(ceiling includeCeiling: Bool?, openWalls includeWalls: Bool?) -> String {
        let ceilingName = "RoomTwin enclosure ceiling"
        let wallPrefix = "RoomTwin enclosure wall"
        look.ceiling = includeCeiling ?? look.ceiling
        look.openWalls = includeWalls ?? look.openWalls
        if let includeCeiling {
            enclosure.childNode(withName: ceilingName, recursively: false)?.removeFromParentNode()
            if includeCeiling {
                let box = SCNBox(width: CGFloat(max(roomHigh.x - roomLow.x, 0.2)), height: 0.05,
                                 length: CGFloat(max(roomHigh.z - roomLow.z, 0.2)), chamferRadius: 0)
                box.materials = [Self.enclosureMaterial()]
                let node = SCNNode(geometry: box)
                node.name = ceilingName
                node.categoryBitMask = Self.solid
                node.simdPosition = SIMD3((roomLow.x + roomHigh.x) / 2, ceilingY + 0.025,
                                          (roomLow.z + roomHigh.z) / 2)
                enclosure.addChildNode(node)
            }
        }
        if let includeWalls {
            enclosure.childNodes.filter { $0.name?.hasPrefix(wallPrefix) == true }.forEach { $0.removeFromParentNode() }
            if includeWalls {
                let height = max(ceilingY - floorY, 0.2)
                struct Side {
                    let normal: SIMD3<Float>
                    let offset: Float
                    let centre: SIMD3<Float>
                    let width: Float
                    let alongX: Bool
                }
                let midX = (roomLow.x + roomHigh.x) / 2, midZ = (roomLow.z + roomHigh.z) / 2
                let sides = [
                    Side(normal: SIMD3(1, 0, 0), offset: roomLow.x,
                         centre: SIMD3(roomLow.x, floorY + height / 2, midZ), width: roomHigh.z - roomLow.z, alongX: false),
                    Side(normal: SIMD3(-1, 0, 0), offset: -roomHigh.x,
                         centre: SIMD3(roomHigh.x, floorY + height / 2, midZ), width: roomHigh.z - roomLow.z, alongX: false),
                    Side(normal: SIMD3(0, 0, 1), offset: roomLow.z,
                         centre: SIMD3(midX, floorY + height / 2, roomLow.z), width: roomHigh.x - roomLow.x, alongX: true),
                    Side(normal: SIMD3(0, 0, -1), offset: -roomHigh.z,
                         centre: SIMD3(midX, floorY + height / 2, roomHigh.z), width: roomHigh.x - roomLow.x, alongX: true),
                ]
                var added = 0
                for side in sides {
                    let alreadyClosed = walls.contains {
                        simd_dot($0.normal, side.normal) > 0.75 && abs($0.offset - side.offset) < 0.3
                            && $0.span.upperBound - $0.span.lowerBound > side.width * 0.55
                    }
                    guard !alreadyClosed else { continue }
                    let box = SCNBox(width: CGFloat(side.alongX ? side.width : 0.06), height: CGFloat(height),
                                     length: CGFloat(side.alongX ? 0.06 : side.width), chamferRadius: 0)
                    box.materials = [Self.enclosureMaterial()]
                    let node = SCNNode(geometry: box)
                    node.name = "\(wallPrefix) \(added + 1)"
                    node.categoryBitMask = Self.solid
                    node.simdPosition = side.centre
                    enclosure.addChildNode(node)
                    added += 1
                }
            }
        }
        let hasCeiling = enclosure.childNode(withName: ceilingName, recursively: false) != nil
        let wallCount = enclosure.childNodes.filter { $0.name?.hasPrefix(wallPrefix) == true }.count
        if !hasCeiling && wallCount == 0 { return "The added enclosure was removed." }
        return "The room now has " + [hasCeiling ? "a ceiling" : nil,
                                      wallCount > 0 ? "\(wallCount) closed wall opening\(wallCount == 1 ? "" : "s")" : nil]
            .compactMap { $0 }.joined(separator: " and ") + "."
    }

    private static func enclosureMaterial() -> SCNMaterial {
        let material = SCNMaterial()
        material.lightingModel = .physicallyBased
        material.diffuse.contents = PlatformColor(white: 0.88, alpha: 1)
        material.roughness.contents = 0.9
        material.metalness.contents = 0.0
        return material
    }

    /// A stable copy of everything the user added or changed. Controllers can
    /// safely hand this to the background USDZ writer without exporting the
    /// preview cameras, movement marker, or transient drop animations.
    func exportContents() -> ExportContents {
        // RoomPlan's original object faces are always replaced by the editable
        // object nodes below—even if the user removed one.
        var replaced = Set(sourceMesh.editableObjects.flatMap { $0.faces })
        var nodes: [SCNNode] = []
        for wall in wallNodes where wall.isTextured {
            replaced.formUnion(wall.faces)
            nodes.append(wall.node.clone())
        }
        if let groundNode, groundNode.isTextured {
            replaced.formUnion(groundNode.faces)
            nodes.append(groundNode.node.clone())
        }

        if !furniture.childNodes.isEmpty {
            let copy = furniture.clone()
            copy.name = Self.furnitureName
            copy.enumerateHierarchy { node, _ in
                node.removeAllActions()
                node.opacity = 1
                if node.name == Self.selectionName { node.removeFromParentNode() }
            }
            // A model may still be halfway through its 0.35-second drop. Its
            // authored position is always the holder's origin in the export.
            for holder in copy.childNodes {
                holder.childNodes.first?.simdPosition = .zero
            }
            nodes.append(copy)
        }
        if !enclosure.childNodes.isEmpty { nodes.append(enclosure.clone()) }
        nodes.append(lightRig.clone())
        return ExportContents(scan: sourceMesh, replacedScanFaces: replaced, nodes: nodes)
    }

    /// Takes over what was done in a preview of the same scan before it was
    /// scanned further: the furniture where it stood, and the room's wall and
    /// floor materials, lighting and enclosure. A material on just the wall
    /// in view isn't carried over, as the walls are found afresh.
    func continueEdits(from earlier: PreviewScene) {
        earlier.clearSelection()
        for holder in earlier.furniture.childNodes {
            furniture.addChildNode(holder)
        }
        let look = earlier.look
        if let walls = look.walls { _ = try? setWallTexture(walls.image, size: walls.size) }
        if let ground = look.ground { _ = try? setGroundTexture(ground.image, size: ground.size) }
        if let lighting = look.lighting { setLighting(brightness: lighting.x, warmth: lighting.y) }
        if look.ceiling != nil || look.openWalls != nil { setEnclosure(ceiling: look.ceiling, openWalls: look.openWalls) }
    }

    /// Puts back the furniture of a room exported by `exportContents`, for a
    /// room rebuilt from its RoomPlan JSON: RoomPlan's pieces go back where
    /// they were left (or stay removed), keeping their scanned look, and
    /// added models come back from the file. USD turns spaces in names into
    /// underscores, so names are compared with those turned back. Walls,
    /// floor, lighting and the enclosure stay as scanned.
    func restoreFurniture(from saved: SCNScene) {
        func plain(_ name: String?) -> String? { name?.replacingOccurrences(of: "_", with: " ") }
        let scanned = Dictionary(furniture.childNodes.compactMap { holder in holder.name.map { ($0, holder) } },
                                 uniquingKeysWith: { first, _ in first })
        // Rooms saved before the group was named: the node whose children
        // are most like RoomPlan's pieces.
        var group: SCNNode?
        var best = 0
        saved.rootNode.enumerateChildNodes { node, stop in
            if plain(node.name) == Self.furnitureName {
                group = node
                stop.pointee = true
                return
            }
            let matches = node.childNodes.filter { plain($0.name).map { scanned[$0] != nil } ?? false }.count
            if matches > best {
                best = matches
                group = node
            }
        }
        guard let group else { return }
        var kept = Set<ObjectIdentifier>()
        for savedHolder in group.childNodes {
            let name = plain(savedHolder.name) ?? "object"
            if let holder = scanned[name], kept.insert(ObjectIdentifier(holder)).inserted {
                holder.simdTransform = savedHolder.simdTransform
                if let scale = savedHolder.childNodes.first?.simdScale { holder.childNodes.first?.simdScale = scale }
            } else {
                let holder = savedHolder.clone()
                holder.name = name
                furniture.addChildNode(holder)
            }
        }
        for holder in scanned.values where !kept.contains(ObjectIdentifier(holder)) {
            holder.removeFromParentNode()
        }
    }

    // MARK: Building

    /// The scan minus its editable walls and floor as one node, with every
    /// editable surface kept separately.
    private func buildRoom(_ mesh: MeshSnapshot) {
        var isWall = [Bool](repeating: false, count: mesh.faces.count)
        for wall in walls {
            for face in wall.faces { isWall[face] = true }
        }
        let objectFaces = Set(mesh.editableObjects.flatMap { $0.faces })
        let groundFaces = mesh.faces.indices.filter { index in
            guard !isWall[index], !objectFaces.contains(index) else { return false }
            let face = mesh.faces[index]
            let points = [mesh.positions[Int(face.x)], mesh.positions[Int(face.y)], mesh.positions[Int(face.z)]]
            let normal = simd_cross(points[1] - points[0], points[2] - points[0])
            return points.allSatisfy { abs($0.y - floorY) <= 0.08 }
                && abs(normal.y) >= 0.75 * simd_length(normal)
        }
        let isGround = Set(groundFaces)
        var rest = mesh
        rest.faces = mesh.faces.enumerated().compactMap { index, face in
            !isWall[index] && !isGround.contains(index) && !objectFaces.contains(index) ? face : nil
        }
        room.addChildNode(Self.meshNode(rest))

        for wall in walls {
            let surface = makeSurface(mesh, faces: wall.faces) { point in
                SIMD2(simd_dot(point, wall.along) - wall.span.lowerBound, point.y - floorY)
            }
            surface.node.name = "wall"
            room.addChildNode(surface.node)
            wallNodes.append(surface)
        }
        if !groundFaces.isEmpty {
            let surface = makeSurface(mesh, faces: groundFaces) { point in SIMD2(point.x, point.z) }
            surface.node.name = "ground"
            room.addChildNode(surface.node)
            groundNode = surface
        }
        for object in mesh.editableObjects {
            addEditableObject(object, from: mesh)
        }
    }

    /// Keeps a RoomPlan object separate from the room shell. Its mesh remains
    /// in `sourceMesh` for raw PLY export, while this local copy can be tapped,
    /// moved, resized, textured, replaced or removed.
    private func addEditableObject(_ object: MeshSnapshot.EditableObject, from mesh: MeshSnapshot) {
        guard !object.faces.isEmpty else { return }
        var remap: [UInt32: UInt32] = [:]
        var piece = MeshSnapshot()
        for faceIndex in object.faces {
            let source = mesh.faces[faceIndex]
            var face = SIMD3<UInt32>()
            for (corner, index) in [source.x, source.y, source.z].enumerated() {
                if let mapped = remap[index] {
                    face[corner] = mapped
                } else {
                    let mapped = UInt32(piece.positions.count)
                    remap[index] = mapped
                    face[corner] = mapped
                    piece.positions.append(mesh.positions[Int(index)])
                    piece.colors.append(mesh.colors[Int(index)])
                }
            }
            piece.faces.append(face)
        }
        let low = piece.positions.reduce(SIMD3<Float>(repeating: .infinity), simd_min)
        let high = piece.positions.reduce(SIMD3<Float>(repeating: -.infinity), simd_max)
        let origin = SIMD3((low.x + high.x) / 2, low.y, (low.z + high.z) / 2)
        piece.positions = piece.positions.map { $0 - origin }
        let model = Self.editableMeshNode(piece)
        model.name = object.name
        let holder = SCNNode()
        holder.name = object.name
        holder.simdPosition = origin
        holder.addChildNode(model)
        furniture.addChildNode(holder)
    }

    /// Builds both looks for one editable part of the scan. UVs are measured
    /// in metres; the material transform later turns them into texture tiles.
    private func makeSurface(_ mesh: MeshSnapshot, faces: [Int],
                             uv: (SIMD3<Float>) -> SIMD2<Float>) -> SurfaceNode {
        var remap: [UInt32: UInt32] = [:]
        var piece = MeshSnapshot()
        var uvs: [Float] = []
        for faceIndex in faces {
            var face = SIMD3<UInt32>()
            for (corner, index) in [mesh.faces[faceIndex].x, mesh.faces[faceIndex].y,
                                    mesh.faces[faceIndex].z].enumerated() {
                if let mapped = remap[index] {
                    face[corner] = mapped
                    continue
                }
                let point = mesh.positions[Int(index)]
                face[corner] = UInt32(piece.positions.count)
                remap[index] = face[corner]
                piece.positions.append(point)
                piece.colors.append(mesh.colors[Int(index)])
                let coordinate = uv(point)
                uvs += [coordinate.x, coordinate.y]
            }
            piece.faces.append(face)
        }
        let node = Self.meshNode(piece)
        let colored = node.geometry!
        let uvSource = SCNGeometrySource(data: uvs.withUnsafeBytes { Data($0) }, semantic: .texcoord,
                                         vectorCount: uvs.count / 2, usesFloatComponents: true,
                                         componentsPerVector: 2, bytesPerComponent: 4, dataOffset: 0, dataStride: 8)
        let bare = SCNGeometry(sources: colored.sources(for: .vertex) + [uvSource], elements: colored.elements)
        return SurfaceNode(node: node, colored: colored, bare: bare, faces: faces)
    }

    /// Triangle-expanded geometry with UVs on every face. RoomPlan's bundled
    /// meshes start as vertex-coloured PLY, so they need generated UVs before
    /// a Poly Haven material can be applied interactively.
    private static func editableMeshNode(_ mesh: MeshSnapshot) -> SCNNode {
        var points: [Float] = [], normals: [Float] = [], colors: [Float] = [], uvs: [Float] = []
        points.reserveCapacity(mesh.faces.count * 9)
        normals.reserveCapacity(mesh.faces.count * 9)
        colors.reserveCapacity(mesh.faces.count * 9)
        uvs.reserveCapacity(mesh.faces.count * 6)
        for face in mesh.faces {
            let indices = [Int(face.x), Int(face.y), Int(face.z)]
            let p = indices.map { mesh.positions[$0] }
            let normal = simd_normalize(simd_cross(p[1] - p[0], p[2] - p[0]))
            let axis = abs(normal.x) > abs(normal.y) && abs(normal.x) > abs(normal.z) ? 0
                : abs(normal.y) > abs(normal.z) ? 1 : 2
            for (index, point) in zip(indices, p) {
                let color = mesh.colors[index]
                points += [point.x, point.y, point.z]
                normals += [normal.x, normal.y, normal.z]
                colors += [Float(color.x) / 255, Float(color.y) / 255, Float(color.z) / 255]
                let uv: SIMD2<Float> = switch axis {
                case 0: SIMD2(point.z, point.y)
                case 1: SIMD2(point.x, point.z)
                default: SIMD2(point.x, point.y)
                }
                uvs += [uv.x, uv.y]
            }
        }
        func source(_ values: [Float], _ semantic: SCNGeometrySource.Semantic, _ components: Int) -> SCNGeometrySource {
            SCNGeometrySource(data: values.withUnsafeBytes { Data($0) }, semantic: semantic,
                              vectorCount: values.count / components, usesFloatComponents: true,
                              componentsPerVector: components, bytesPerComponent: 4,
                              dataOffset: 0, dataStride: components * 4)
        }
        let indices = Array(0..<UInt32(mesh.faces.count * 3))
        let element = SCNGeometryElement(data: indices.withUnsafeBytes { Data($0) }, primitiveType: .triangles,
                                         primitiveCount: mesh.faces.count, bytesPerIndex: 4)
        let geometry = SCNGeometry(sources: [source(points, .vertex, 3), source(normals, .normal, 3),
                                             source(colors, .color, 3), source(uvs, .texcoord, 2)],
                                   elements: [element])
        geometry.materials = [scanMaterial()]
        let node = SCNNode(geometry: geometry)
        node.categoryBitMask = solid
        return node
    }

    /// Soft light for added furniture; the scan itself is unlit.
    private func addLights() {
        let ambient = SCNNode()
        ambient.light = SCNLight()
        ambient.light?.type = .ambient
        ambient.light?.intensity = 450
        lightRig.addChildNode(ambient)
        let sun = SCNNode()
        sun.light = SCNLight()
        sun.light?.type = .directional
        sun.light?.intensity = 700
        sun.simdOrientation = simd_quatf(angle: -1.0, axis: simd_normalize(SIMD3(1, 0, 0.4)))
        lightRig.addChildNode(sun)
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

    /// Exportable PBR material for walls, floors and object overrides. Unlike
    /// the captured scan shader, it survives SceneKit's USDZ conversion.
    private static func surfaceMaterial(_ image: Any) -> SCNMaterial {
        let material = SCNMaterial()
        material.lightingModel = .physicallyBased
        material.diffuse.contents = image
        material.diffuse.wrapS = .repeat
        material.diffuse.wrapT = .repeat
        material.diffuse.mipFilter = .linear
        material.roughness.contents = 0.85
        material.metalness.contents = 0.0
        material.isDoubleSided = true
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
