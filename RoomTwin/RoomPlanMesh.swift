import RoomPlan
import simd

/// Turns a RoomPlan room into one vertex-coloured mesh, wound
/// counter-clockwise seen from inside the room like the scanner's mesh, so
/// PreviewScene and the PLY/USDZ export treat it the same way. Walls get their
/// doors, windows and openings cut out; doors and windows become panels in
/// the holes. Furniture whose category has a model in `library` gets that
/// model stretched to RoomPlan's box, and every other object is a box.
enum RoomPlanMesh {
    static func build(_ room: CapturedRoom, library: [String: MeshSnapshot]) -> MeshSnapshot {
        var builder = Builder()
        let walls = room.walls
        let wallCentres = walls.map { $0.transform.position }
        let centre = wallCentres.isEmpty ? SIMD3<Float>.zero : wallCentres.reduce(.zero, +) / Float(wallCentres.count)
        let holes = room.doors + room.windows + room.openings

        for wall in walls {
            let inside = holes.filter { belongs($0, to: wall) }
            builder.addWall(wall, holes: inside, facing: centre)
        }
        for door in room.doors {
            builder.addPanel(door, colour: Colour.door, facing: centre)
        }
        for window in room.windows {
            builder.addPanel(window, colour: Colour.window, facing: centre)
        }
        if room.floors.isEmpty {
            builder.addFloor(underWalls: walls)
        } else {
            for floor in room.floors { builder.addFloor(floor) }
        }
        for object in room.objects {
            if let model = library[name(of: object.category)] {
                builder.addModel(model, fitting: object)
            } else {
                builder.addBox(object)
            }
        }
        return builder.mesh
    }

    /// The category as FurnitureLibrary names its kinds, e.g. "chair".
    static func name(of category: CapturedRoom.Object.Category) -> String {
        String(describing: category)
    }

    /// Whether a door, window or opening sits in `wall`.
    private static func belongs(_ hole: CapturedRoom.Surface, to wall: CapturedRoom.Surface) -> Bool {
        if let parent = hole.parentIdentifier { return parent == wall.identifier }
        let local = wall.transform.inverse * SIMD4(hole.transform.position, 1)
        return abs(local.z) < 0.15 && abs(local.x) <= wall.dimensions.x / 2 + 0.05
    }
}

private enum Colour {
    static let wall = SIMD3<UInt8>(226, 222, 214)
    static let floor = SIMD3<UInt8>(176, 160, 138)
    static let door = SIMD3<UInt8>(146, 104, 72)
    static let window = SIMD3<UInt8>(170, 206, 232)

    static func object(_ category: CapturedRoom.Object.Category) -> SIMD3<UInt8> {
        switch category {
        case .bed: SIMD3(150, 170, 200)
        case .sofa, .chair: SIMD3(196, 150, 120)
        case .table: SIMD3(170, 130, 95)
        case .storage: SIMD3(205, 190, 160)
        case .television: SIMD3(60, 60, 66)
        case .refrigerator, .stove, .oven, .dishwasher, .washerDryer: SIMD3(210, 214, 218)
        case .sink, .toilet, .bathtub: SIMD3(235, 238, 240)
        case .fireplace: SIMD3(150, 90, 70)
        case .stairs: SIMD3(160, 150, 140)
        @unknown default: SIMD3(180, 180, 180)
        }
    }
}

private struct Builder {
    var mesh = MeshSnapshot()

    mutating func addWall(_ wall: CapturedRoom.Surface, holes: [CapturedRoom.Surface], facing centre: SIMD3<Float>) {
        let half = SIMD2(wall.dimensions.x, wall.dimensions.y) / 2
        // Each hole as a rectangle in the wall's own plane.
        let inverse = wall.transform.inverse
        let cuts = holes.map { hole -> (low: SIMD2<Float>, high: SIMD2<Float>) in
            let corners = Self.corners(of: hole).map { inverse * SIMD4($0, 1) }
            let xs = corners.map(\.x), ys = corners.map(\.y)
            return (simd_clamp(SIMD2(xs.min()!, ys.min()!), -half, half), simd_clamp(SIMD2(xs.max()!, ys.max()!), -half, half))
        }
        // Split the wall on every hole edge and keep the cells outside all holes.
        let xs = Set([-half.x, half.x] + cuts.flatMap { [$0.low.x, $0.high.x] }).sorted()
        let ys = Set([-half.y, half.y] + cuts.flatMap { [$0.low.y, $0.high.y] }).sorted()
        let flip = simd_dot(wall.transform.normal, centre - wall.transform.position) < 0
        for i in 0..<xs.count - 1 {
            for j in 0..<ys.count - 1 {
                let low = SIMD2(xs[i], ys[j]), high = SIMD2(xs[i + 1], ys[j + 1])
                let middle = (low + high) / 2
                guard high.x - low.x > 1e-4, high.y - low.y > 1e-4,
                      !cuts.contains(where: { all(middle .> $0.low) && all(middle .< $0.high) }) else { continue }
                addQuad(low: low, high: high, depth: 0, transform: wall.transform, colour: Colour.wall, flip: flip)
            }
        }
    }

    /// A door or window filling its hole, just inside the wall.
    mutating func addPanel(_ surface: CapturedRoom.Surface, colour: SIMD3<UInt8>, facing centre: SIMD3<Float>) {
        let half = SIMD2(surface.dimensions.x, surface.dimensions.y) / 2
        let inward: Float = simd_dot(surface.transform.normal, centre - surface.transform.position) < 0 ? -1 : 1
        addQuad(low: -half, high: half, depth: 0.01 * inward, transform: surface.transform, colour: colour, flip: inward < 0)
    }

    mutating func addFloor(_ floor: CapturedRoom.Surface) {
        let corners = floor.polygonCorners.count >= 3
            ? floor.polygonCorners.map { (floor.transform * SIMD4($0, 1)).xyz }
            : Self.corners(of: floor)
        addFacingUp(corners, colour: Colour.floor)
    }

    /// Without a floor from RoomPlan, the outline round the bottoms of the walls.
    mutating func addFloor(underWalls walls: [CapturedRoom.Surface]) {
        let bottoms = walls.flatMap { wall -> [SIMD3<Float>] in
            let half = wall.dimensions / 2
            return [SIMD3(-half.x, -half.y, 0), SIMD3(half.x, -half.y, 0)].map { (wall.transform * SIMD4($0, 1)).xyz }
        }
        guard let height = bottoms.map(\.y).min() else { return }
        let hull = convexHull(bottoms.map { SIMD2($0.x, $0.z) })
        addFacingUp(hull.map { SIMD3($0.x, height, $0.y) }, colour: Colour.floor)
    }

    mutating func addBox(_ object: CapturedRoom.Object) {
        let half = object.dimensions / 2
        let colour = Colour.object(object.category)
        let centre = object.transform.position
        // Each face as (axis, sign); its two in-plane axes follow it.
        for axis in 0..<3 {
            for sign: Float in [-1, 1] {
                let u = (axis + 1) % 3, v = (axis + 2) % 3
                var corners: [SIMD3<Float>] = []
                for (a, b): (Float, Float) in [(-1, -1), (1, -1), (1, 1), (-1, 1)] {
                    var p = SIMD3<Float>.zero
                    p[axis] = sign * half[axis]
                    p[u] = a * half[u]
                    p[v] = b * half[v]
                    corners.append((object.transform * SIMD4(p, 1)).xyz)
                }
                let faceCentre = corners.reduce(.zero, +) / 4
                let outward = simd_dot(simd_cross(corners[1] - corners[0], corners[2] - corners[0]), faceCentre - centre) > 0
                addPolygon(outward ? corners : corners.reversed(), colour: colour)
            }
        }
    }

    /// A library model (standing on y = 0, facing +z) stretched to fill the object's box.
    mutating func addModel(_ model: MeshSnapshot, fitting object: CapturedRoom.Object) {
        let low = model.positions.reduce(SIMD3<Float>(repeating: .infinity), simd_min)
        let high = model.positions.reduce(SIMD3<Float>(repeating: -.infinity), simd_max)
        let middle = (low + high) / 2
        let scale = object.dimensions / simd_max(high - low, SIMD3(repeating: 1e-4))
        let base = UInt32(mesh.positions.count)
        for (p, c) in zip(model.positions, model.colors) {
            mesh.positions.append((object.transform * SIMD4((p - middle) * scale, 1)).xyz)
            mesh.colors.append(c)
        }
        mesh.faces += model.faces.map { $0 &+ base }
    }

    // MARK: Primitives

    /// A rectangle in a surface's plane (local x, y), `depth` along its normal.
    /// Wound counter-clockwise seen from +z, or from -z if `flip`.
    private mutating func addQuad(low: SIMD2<Float>, high: SIMD2<Float>, depth: Float, transform: simd_float4x4,
                                  colour: SIMD3<UInt8>, flip: Bool) {
        let corners = [SIMD2(low.x, low.y), SIMD2(high.x, low.y), SIMD2(high.x, high.y), SIMD2(low.x, high.y)]
            .map { (transform * SIMD4($0.x, $0.y, depth, 1)).xyz }
        addPolygon(flip ? corners.reversed() : corners, colour: colour)
    }

    /// A horizontal polygon, wound to face up.
    private mutating func addFacingUp(_ corners: [SIMD3<Float>], colour: SIMD3<UInt8>) {
        let flat = corners.map { SIMD2($0.x, $0.z) }
        // Counter-clockwise seen from above is clockwise in (x, z), whose area is negative.
        let area = zip(flat, flat.dropFirst() + flat.prefix(1)).reduce(Float(0)) { $0 + $1.0.x * $1.1.y - $1.1.x * $1.0.y }
        let ordered = area > 0 ? corners.reversed() : corners
        let base = UInt32(mesh.positions.count)
        mesh.positions += ordered
        mesh.colors += Array(repeating: colour, count: ordered.count)
        for triangle in earClip(ordered.map { SIMD2($0.x, -$0.z) }) {
            mesh.faces.append(SIMD3(base + UInt32(triangle.x), base + UInt32(triangle.y), base + UInt32(triangle.z)))
        }
    }

    /// A convex polygon, as a fan, keeping its winding.
    private mutating func addPolygon(_ corners: [SIMD3<Float>], colour: SIMD3<UInt8>) {
        let base = UInt32(mesh.positions.count)
        mesh.positions += corners
        mesh.colors += Array(repeating: colour, count: corners.count)
        for i in 1..<UInt32(corners.count - 1) {
            mesh.faces.append(SIMD3(base, base + i, base + i + 1))
        }
    }

    private static func corners(of surface: CapturedRoom.Surface) -> [SIMD3<Float>] {
        let half = SIMD2(surface.dimensions.x, surface.dimensions.y) / 2
        return [SIMD2(-half.x, -half.y), SIMD2(half.x, -half.y), SIMD2(half.x, half.y), SIMD2(-half.x, half.y)]
            .map { (surface.transform * SIMD4($0.x, $0.y, 0, 1)).xyz }
    }
}

/// Triangles of a simple polygon given counter-clockwise, as index triples.
private func earClip(_ points: [SIMD2<Float>]) -> [SIMD3<Int>] {
    var remaining = Array(points.indices)
    var triangles: [SIMD3<Int>] = []
    func cross(_ o: SIMD2<Float>, _ a: SIMD2<Float>, _ b: SIMD2<Float>) -> Float {
        (a.x - o.x) * (b.y - o.y) - (a.y - o.y) * (b.x - o.x)
    }
    while remaining.count > 3 {
        var clipped = false
        for k in remaining.indices {
            let i = remaining[(k + remaining.count - 1) % remaining.count], j = remaining[k]
            let l = remaining[(k + 1) % remaining.count]
            let a = points[i], b = points[j], c = points[l]
            guard cross(a, b, c) > 0 else { continue }   // reflex corner
            let inside = remaining.contains { m in
                guard m != i && m != j && m != l else { return false }
                let p = points[m]
                return cross(a, b, p) >= 0 && cross(b, c, p) >= 0 && cross(c, a, p) >= 0
            }
            guard !inside else { continue }
            triangles.append(SIMD3(i, j, l))
            remaining.remove(at: k)
            clipped = true
            break
        }
        if !clipped { break }   // degenerate outline: give up on the rest
    }
    if remaining.count == 3 { triangles.append(SIMD3(remaining[0], remaining[1], remaining[2])) }
    return triangles
}

/// Counter-clockwise convex hull (Andrew's monotone chain).
private func convexHull(_ points: [SIMD2<Float>]) -> [SIMD2<Float>] {
    let sorted = points.sorted { $0.x != $1.x ? $0.x < $1.x : $0.y < $1.y }
    guard sorted.count > 2 else { return sorted }
    func cross(_ o: SIMD2<Float>, _ a: SIMD2<Float>, _ b: SIMD2<Float>) -> Float {
        (a.x - o.x) * (b.y - o.y) - (a.y - o.y) * (b.x - o.x)
    }
    var lower: [SIMD2<Float>] = [], upper: [SIMD2<Float>] = []
    for p in sorted {
        while lower.count >= 2 && cross(lower[lower.count - 2], lower[lower.count - 1], p) <= 0 { lower.removeLast() }
        lower.append(p)
    }
    for p in sorted.reversed() {
        while upper.count >= 2 && cross(upper[upper.count - 2], upper[upper.count - 1], p) <= 0 { upper.removeLast() }
        upper.append(p)
    }
    return Array(lower.dropLast() + upper.dropLast())
}

private extension simd_float4x4 {
    var position: SIMD3<Float> { columns.3.xyz }
    /// The surface normal: local +z.
    var normal: SIMD3<Float> { simd_normalize(columns.2.xyz) }
}

private extension SIMD4 where Scalar == Float {
    var xyz: SIMD3<Float> { SIMD3(x, y, z) }
}
