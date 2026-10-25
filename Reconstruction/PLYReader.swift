import Foundation
import simd

enum PLYReadError: Error {
    case unsupported(String)
}

extension MeshSnapshot {
    /// Reads the binary PLY layout that `writePLY` produces.
    init(ply url: URL) throws {
        let data = try Data(contentsOf: url)
        guard let end = data.range(of: Data("end_header\n".utf8))?.upperBound,
              let header = String(data: data[..<end], encoding: .ascii),
              header.contains("format binary_little_endian 1.0") else {
            throw PLYReadError.unsupported("not a binary little-endian PLY: \(url.lastPathComponent)")
        }
        func count(_ element: String) throws -> Int {
            guard let line = header.split(separator: "\n").first(where: { $0.hasPrefix("element \(element) ") }),
                  let n = Int(line.split(separator: " ")[2]) else {
                throw PLYReadError.unsupported("no \(element) count")
            }
            return n
        }
        let vertexCount = try count("vertex"), faceCount = try count("face")
        guard data.count == end + vertexCount * 15 + faceCount * 13 else {
            throw PLYReadError.unsupported("size does not match a RoomTwin PLY")
        }

        self.init()
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            var offset = end
            func float() -> Float {
                defer { offset += 4 }
                return Float(bitPattern: UInt32(littleEndian: raw.loadUnaligned(fromByteOffset: offset, as: UInt32.self)))
            }
            func byte() -> UInt8 {
                defer { offset += 1 }
                return raw[offset]
            }
            func index() -> UInt32 {
                defer { offset += 4 }
                return UInt32(littleEndian: raw.loadUnaligned(fromByteOffset: offset, as: UInt32.self))
            }
            for _ in 0..<vertexCount {
                positions.append(SIMD3(float(), float(), float()))
                colors.append(SIMD3(byte(), byte(), byte()))
            }
            for _ in 0..<faceCount {
                offset += 1   // vertex count, always 3
                faces.append(SIMD3(index(), index(), index()))
            }
        }
    }
}
