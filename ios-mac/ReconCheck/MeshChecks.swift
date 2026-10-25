import Foundation
import ModelIO
import simd

struct Check {
    let name: String
    let passed: Bool
    let detail: String
}

/// Verifies the data-structure invariants and the geometry of a finished reconstruction.
/// The GPU must be idle.
func checkReconstruction(_ r: Reconstructor, room: SyntheticRoom) -> (checks: [Check], mesh: MeshSnapshot) {
    let s = r.settings
    let mesh = r.snapshot()
    let counters = r.counters.contents().bindMemory(to: Int32.self, capacity: Int(RT_COUNTER_COUNT))
    let refs = r.vertexRef.contents().bindMemory(to: Int32.self, capacity: s.maxVertices)
    let owners = r.vertexOwner.contents().bindMemory(to: Int32.self, capacity: s.maxVertices)
    let edges = r.edgeVertex.contents().bindMemory(to: Int32.self, capacity: s.cubeCount * 3)
    let triangleBlocks = r.triangleBlock.contents().bindMemory(to: Int32.self, capacity: s.cubeCount)
    var checks: [Check] = []

    checks.append(Check(name: "No pool overflowed", passed: counters[Int(RT_COUNTER_OVERFLOW)] == 0,
                        detail: "flags \(counters[Int(RT_COUNTER_OVERFLOW)])"))

    // Every live vertex sits on exactly one edge, and that edge points back at it.
    var live = 0, badOwner = 0
    for v in 0..<s.maxVertices where refs[v] >= 0 {
        live += 1
        if edges[Int(owners[v])] != Int32(v) { badOwner += 1 }
    }
    checks.append(Check(name: "One vertex per edge (edge ownership)", passed: badOwner == 0,
                        detail: "\(live) live vertices, \(badOwner) not owned by their edge"))

    // Reference counts equal the number of triangle corners using each vertex,
    // and the garbage pass left no unreferenced vertex behind.
    var uses = [Int32: Int32]()
    for f in mesh.faces {
        for i in [f.x, f.y, f.z] { uses[mesh.poolIndices[Int(i)], default: 0] += 1 }
    }
    let wrongRefs = uses.filter { refs[Int($0.key)] != $0.value }.count
    let leaked = live - uses.count
    checks.append(Check(name: "Reference counts match triangles", passed: wrongRefs == 0,
                        detail: "\(wrongRefs) vertices with a wrong count"))
    checks.append(Check(name: "No leaked vertices", passed: leaked == 0, detail: "\(leaked) live but unused"))

    let freeVertices = Int(counters[Int(RT_COUNTER_VERTEX_FREE_TOP)])
    let usedBlocks = min(Int(counters[Int(RT_COUNTER_BLOCKS)]), s.maxBlocks) * Int(RT_CUBES_PER_BLOCK)
    let surfaceCubes = (0..<usedBlocks).filter { triangleBlocks[$0] >= 0 }.count
    let freeSurfaceCubes = Int(counters[Int(RT_COUNTER_TRIANGLE_FREE_TOP)])
    let poolsBalance = live + freeVertices == s.maxVertices && surfaceCubes + freeSurfaceCubes == s.maxSurfaceCubes
    checks.append(Check(name: "Free lists balance", passed: poolsBalance,
                        detail: "vertices \(live)+\(freeVertices)/\(s.maxVertices), cubes \(surfaceCubes)+\(freeSurfaceCubes)/\(s.maxSurfaceCubes)"))
    let counted = Int(counters[Int(RT_COUNTER_TRIANGLES)])
    checks.append(Check(name: "Triangle counter matches mesh", passed: counted == mesh.faces.count,
                        detail: "counter \(counted), mesh \(mesh.faces.count)"))

    // Topology: each edge should be shared by two triangles running opposite ways.
    var directed = [UInt64: Int]()
    for f in mesh.faces {
        for (a, b) in [(f.x, f.y), (f.y, f.z), (f.z, f.x)] { directed[UInt64(a) << 32 | UInt64(b), default: 0] += 1 }
    }
    var boundary = 0, nonManifold = 0, flipped = 0, total = 0
    for (key, count) in directed {
        let a = key >> 32, b = key & 0xFFFF_FFFF
        let reverse = directed[b << 32 | a] ?? 0
        if a > b && reverse > 0 { continue }   // counted from the other side
        total += 1
        if count + reverse == 1 { boundary += 1 }
        if count + reverse > 2 { nonManifold += 1 }
        if count > 1 || reverse > 1 { flipped += 1 }
    }
    let manifoldOK = Double(nonManifold + flipped) <= 0.001 * Double(total)
    checks.append(Check(name: "Manifold, consistently wound", passed: manifoldOK,
                        detail: "\(total) edges: \(boundary) open, \(nonManifold) non-manifold, \(flipped) wound the same way twice"))

    // Geometry: vertices should lie on the true surfaces.
    var errors = mesh.positions.map { abs(room.distance($0)) }.sorted()
    if errors.isEmpty { errors = [.infinity] }
    let mean = errors.reduce(0, +) / Float(errors.count)
    let p95 = errors[errors.count * 95 / 100]
    checks.append(Check(name: "Vertices lie on the surface", passed: mean < 0.25 * s.voxelSize && p95 < 0.75 * s.voxelSize,
                        detail: String(format: "mean %.1f mm, p95 %.1f mm, max %.1f mm", mean * 1000, p95 * 1000, errors.last! * 1000)))
    return (checks, mesh)
}

/// Reads the exported files back the way other apps will.
func checkExports(_ mesh: MeshSnapshot, ply: URL, usdz: URL) -> [Check] {
    var checks: [Check] = []
    let data = (try? Data(contentsOf: ply)) ?? Data()
    let headerEnd = data.range(of: Data("end_header\n".utf8))?.upperBound ?? 0
    let expected = headerEnd + mesh.positions.count * 15 + mesh.faces.count * 13
    checks.append(Check(name: "PLY size matches its header", passed: headerEnd > 0 && data.count == expected,
                        detail: "\(data.count) bytes, expected \(expected)"))

    let lo = mesh.positions.reduce(SIMD3<Float>(repeating: .infinity), simd_min)
    let hi = mesh.positions.reduce(SIMD3<Float>(repeating: -.infinity), simd_max)
    // The USDZ unshares vertices so every triangle can have its own texture cell.
    for (url, expectedVertices) in [(ply, mesh.positions.count), (usdz, mesh.faces.count * 3)] {
        let asset = MDLAsset(url: url)
        let vertices = asset.childObjects(of: MDLMesh.self).reduce(0) { $0 + ($1 as! MDLMesh).vertexCount }
        let box = asset.boundingBox
        let boundsMatch = simd_length(box.minBounds - lo) < 1e-4 && simd_length(box.maxBounds - hi) < 1e-4
        checks.append(Check(name: "\(url.pathExtension.uppercased()) loads in ModelIO with the same geometry",
                            passed: vertices == expectedVertices && boundsMatch,
                            detail: "\(vertices) vertices (expected \(expectedVertices)), bounds \(boundsMatch ? "match" : "differ")"))
    }
    // Look for the PNG signature itself; the file name also appears in the USD layer.
    let pngSignature = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
    let packaged = (try? Data(contentsOf: usdz)).map { $0.range(of: pngSignature) != nil } ?? false
    checks.append(Check(name: "USDZ carries its color texture", passed: packaged,
                        detail: packaged ? "PNG packaged" : "no PNG inside"))
    return checks
}

