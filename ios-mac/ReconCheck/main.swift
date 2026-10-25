// ReconCheck: runs the reconstruction on a synthetic room on this Mac's GPU and
// checks the mesh.
//
//   ReconCheck [output directory]     run the checks
//   ReconCheck usdz scan.ply...       convert exported PLYs to textured USDZ

import Foundation
import Metal
import simd

if CommandLine.arguments.dropFirst().first == "usdz" {
    for path in CommandLine.arguments.dropFirst(2) {
        let ply = URL(fileURLWithPath: path)
        let usdz = ply.deletingPathExtension().appendingPathExtension("usdz")
        try MeshSnapshot(ply: ply).writeUSDZ(to: usdz)
        print("wrote \(usdz.path)")
    }
    exit(0)
}

let outputDirectory = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? FileManager.default.currentDirectoryPath)
let device = MTLCreateSystemDefaultDevice()!
let library: MTLLibrary = try {
    if let library = device.makeDefaultLibrary() { return library }
    let besideExecutable = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent()
    return try device.makeLibrary(URL: besideExecutable.appendingPathComponent("default.metallib"))
}()
let queue = device.makeCommandQueue()!
let room = SyntheticRoom()
let camera = SyntheticCamera(device: device, room: room, depthNoise: 0.004)
let frameCount = 240
print("GPU: \(device.name)")

struct LapResult {
    var gpuMilliseconds: [Double] = []
    var retriangulated: [Int] = []
}

func runLap(_ reconstructor: Reconstructor) -> LapResult {
    var result = LapResult()
    for i in 0..<frameCount {
        let frame = camera.render(cameraToWorld: SyntheticCamera.pose(i, of: frameCount))
        let commandBuffer = queue.makeCommandBuffer()!
        reconstructor.integrate(frame, commandBuffer: commandBuffer)
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        if let error = commandBuffer.error { fatalError("GPU error: \(error)") }
        result.gpuMilliseconds.append((commandBuffer.gpuEndTime - commandBuffer.gpuStartTime) * 1000)
        result.retriangulated.append(reconstructor.stats().retriangulatedCubes)
    }
    return result
}

func median(_ values: [Double]) -> Double { values.sorted()[values.count / 2] }

var allPassed = true
var retriangulatedSecondLap: [String: Int] = [:]
for (label, refine) in [("Hamming refinement on", Float(0.3)), ("Hamming refinement off", Float(0))] {
    var settings = ReconstructionSettings()
    settings.maxDepth = 4.5
    settings.refineThresholdInVoxels = refine
    let reconstructor = try Reconstructor(device: device, library: library, settings: settings)
    let reset = queue.makeCommandBuffer()!
    reconstructor.reset(commandBuffer: reset)
    reset.commit()
    reset.waitUntilCompleted()

    print("\n== \(label): \(frameCount) frames x 2 laps, \(Int(settings.voxelSize * 1000)) mm voxels, \(reconstructor.allocatedBytes >> 20) MB ==")
    let first = runLap(reconstructor)
    let second = runLap(reconstructor)
    let stats = reconstructor.stats()
    print(String(format: "GPU per frame: median %.2f ms, max %.2f ms",
                 median(first.gpuMilliseconds + second.gpuMilliseconds), (first.gpuMilliseconds + second.gpuMilliseconds).max()!))
    print("Cubes retriangulated per frame: lap 1 avg \(first.retriangulated.reduce(0, +) / frameCount), lap 2 avg \(second.retriangulated.reduce(0, +) / frameCount)")
    retriangulatedSecondLap[label] = second.retriangulated.reduce(0, +) / frameCount

    let (checks, mesh) = checkReconstruction(reconstructor, room: room)
    print("Mesh: \(stats.blocks) blocks, \(mesh.positions.count) vertices, \(mesh.faces.count) triangles "
          + String(format: "(%.2f vertices per triangle; storing 3 per triangle would need %d)",
                   Double(mesh.positions.count) / Double(max(mesh.faces.count, 1)), mesh.faces.count * 3))
    for check in checks {
        print("  [\(check.passed ? "PASS" : "FAIL")] \(check.name): \(check.detail)")
        allPassed = allPassed && check.passed
    }

    if refine == 0 {
        let ply = outputDirectory.appendingPathComponent("synthetic-room.ply")
        let usdz = outputDirectory.appendingPathComponent("synthetic-room.usdz")
        try mesh.writePLY(to: ply)
        try mesh.writeUSDZ(to: usdz)
        for check in checkExports(mesh, ply: ply, usdz: usdz) {
            print("  [\(check.passed ? "PASS" : "FAIL")] \(check.name): \(check.detail)")
            allPassed = allPassed && check.passed
        }
        let renderer = try OffscreenRenderer(device: device, library: library)
        try renderer.render(reconstructor, eye: SIMD3(3.2, 6.0, 4.6), target: SIMD3(0, 0.4, 0), clipHeight: 2.2,
                            mode: RT_MESH_MODE_COLOR, to: outputDirectory.appendingPathComponent("room-color.png"))
        try renderer.render(reconstructor, eye: SIMD3(-1.0, 1.6, -0.4), target: SIMD3(0.9, 0.55, -1.3), clipHeight: 10,
                            mode: RT_MESH_MODE_SHADED, to: outputDirectory.appendingPathComponent("room-shaded.png"))
        print("Wrote synthetic-room.ply/.usdz, room-color.png and room-shaded.png to \(outputDirectory.path)")
    }
}

if let on = retriangulatedSecondLap["Hamming refinement on"], let off = retriangulatedSecondLap["Hamming refinement off"] {
    print("\nRefinement effect: \(off) -> \(on) topology changes per frame on the second lap")
}
print(allPassed ? "\nAll checks passed." : "\nSome checks FAILED.")
exit(allPassed ? 0 : 1)
