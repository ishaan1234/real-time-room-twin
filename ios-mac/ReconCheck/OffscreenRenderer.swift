import CoreGraphics
import ImageIO
import Metal
import simd
import UniformTypeIdentifiers

/// Renders the reconstructed mesh with the app's mesh shaders and saves a PNG.
struct OffscreenRenderer {
    let device: MTLDevice
    let queue: MTLCommandQueue
    let pipeline: MTLRenderPipelineState
    let depthState: MTLDepthStencilState
    let width = 1200, height = 900

    init(device: MTLDevice, library: MTLLibrary) throws {
        self.device = device
        queue = device.makeCommandQueue()!
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = library.makeFunction(name: "meshVertex")
        descriptor.fragmentFunction = library.makeFunction(name: "meshFragment")
        descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
        descriptor.depthAttachmentPixelFormat = .depth32Float
        pipeline = try device.makeRenderPipelineState(descriptor: descriptor)
        let depth = MTLDepthStencilDescriptor()
        depth.depthCompareFunction = .less
        depth.isDepthWriteEnabled = true
        depthState = device.makeDepthStencilState(descriptor: depth)!
    }

    func render(_ reconstructor: Reconstructor, eye: SIMD3<Float>, target: SIMD3<Float>, clipHeight: Float,
                mode: Int32, to url: URL) throws {
        let colorDescriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: width,
                                                                       height: height, mipmapped: false)
        colorDescriptor.usage = .renderTarget
        colorDescriptor.storageMode = .shared
        let color = device.makeTexture(descriptor: colorDescriptor)!
        let depthDescriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .depth32Float, width: width,
                                                                       height: height, mipmapped: false)
        depthDescriptor.usage = .renderTarget
        depthDescriptor.storageMode = .private
        let depth = device.makeTexture(descriptor: depthDescriptor)!

        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = color
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0.08, green: 0.08, blue: 0.1, alpha: 1)
        pass.colorAttachments[0].storeAction = .store
        pass.depthAttachment.texture = depth
        pass.depthAttachment.loadAction = .clear
        pass.depthAttachment.clearDepth = 1
        pass.depthAttachment.storeAction = .dontCare

        var uniforms = MeshUniforms()
        uniforms.viewProjection = perspective(fovY: 0.9, aspect: Float(width) / Float(height), near: 0.05, far: 50)
            * lookAt(eye: eye, target: target)
        uniforms.cameraPosition = SIMD4(eye, 1)
        uniforms.clipHeight = clipHeight
        uniforms.mode = UInt32(mode)

        let commandBuffer = queue.makeCommandBuffer()!
        let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass)!
        encoder.setRenderPipelineState(pipeline)
        encoder.setDepthStencilState(depthState)
        encoder.setVertexBytes(&uniforms, length: MemoryLayout<MeshUniforms>.stride, index: 1)
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<MeshUniforms>.stride, index: 0)
        reconstructor.drawMesh(encoder)
        encoder.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()

        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        color.getBytes(&pixels, bytesPerRow: width * 4, from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
        let context = CGContext(data: &pixels, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.noneSkipFirst.rawValue)!
        let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, context.makeImage()!, nil)
        CGImageDestinationFinalize(destination)
    }
}

/// Right-handed perspective projection with Metal's [0, 1] depth range.
func perspective(fovY: Float, aspect: Float, near: Float, far: Float) -> simd_float4x4 {
    let y = 1 / tan(fovY / 2)
    let z = far / (near - far)
    return simd_float4x4(columns: (SIMD4(y / aspect, 0, 0, 0), SIMD4(0, y, 0, 0),
                                   SIMD4(0, 0, z, -1), SIMD4(0, 0, z * near, 0)))
}

func lookAt(eye: SIMD3<Float>, target: SIMD3<Float>, up: SIMD3<Float> = SIMD3(0, 1, 0)) -> simd_float4x4 {
    let f = simd_normalize(target - eye)
    let s = simd_normalize(simd_cross(f, up))
    let u = simd_cross(s, f)
    return simd_float4x4(columns: (SIMD4(s.x, u.x, -f.x, 0), SIMD4(s.y, u.y, -f.y, 0), SIMD4(s.z, u.z, -f.z, 0),
                                   SIMD4(-simd_dot(s, eye), -simd_dot(u, eye), simd_dot(f, eye), 1)))
}
