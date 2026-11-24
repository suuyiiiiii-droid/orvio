import SceneKit.ModelIO
import simd

// Compiled at the end of RemoteScene.swift by export_remote_models.sh.
extension RemoteSceneView {
    fileprivate func asset(for profile: RemoteProfile) -> [String: Any] {
        let meshes = assembly.childNodes.compactMap { node -> [String: Any]? in
            guard let geometry = node.geometry, let material = geometry.firstMaterial else { return nil }
            // This also tessellates the initially lazy geometry of SCNShape.
            _ = MDLMesh(scnGeometry: geometry, bufferAllocator: nil)
            guard let vertices = geometry.sources(for: .vertex).first, vertices.vectorCount > 0 else { return nil }

            func pack(_ source: SCNGeometrySource?) -> String? {
                guard let source, source.vectorCount == vertices.vectorCount, source.usesFloatComponents else { return nil }
                let floats = source.data.withUnsafeBytes { raw in
                    (0..<source.vectorCount).flatMap { index in
                        (0..<source.componentsPerVector).map { component -> Float in
                            let offset = source.dataOffset + index * source.dataStride + component * source.bytesPerComponent
                            return source.bytesPerComponent == 4
                                ? raw.loadUnaligned(fromByteOffset: offset, as: Float.self)
                                : Float(raw.loadUnaligned(fromByteOffset: offset, as: Double.self))
                        }
                    }
                }
                return floats.withUnsafeBytes { Data($0).base64EncodedString() }
            }

            let indices = geometry.elements.flatMap { element -> [Int32] in
                precondition(element.primitiveType == .triangles)
                return element.data.withUnsafeBytes { raw in
                    (0..<element.primitiveCount * 3).map { index in
                        let offset = index * element.bytesPerIndex
                        switch element.bytesPerIndex {
                        case 1: return Int32(raw.loadUnaligned(fromByteOffset: offset, as: UInt8.self))
                        case 2: return Int32(raw.loadUnaligned(fromByteOffset: offset, as: UInt16.self))
                        default: return raw.loadUnaligned(fromByteOffset: offset, as: Int32.self)
                        }
                    }
                }
            }
            let transform = node.simdTransform.columns
            let matrix = [transform.0, transform.1, transform.2, transform.3].flatMap { [$0.x, $0.y, $0.z, $0.w] }
            var part: [String: Any] = [
                "key": node.name ?? "", "matrix": matrix,
                "vertices": pack(vertices)!,
                "triangles": indices.withUnsafeBytes { Data($0).base64EncodedString() }
            ]
            if let normals = pack(geometry.sources(for: .normal).first) { part["normals"] = normals }
            if let legend = exportLegends[ObjectIdentifier(node)] {
                // The receiving platform draws its own glyphs using the exported placement.
                part["legend"] = legend
                part["uv"] = pack(geometry.sources(for: .texcoord).first)
            } else if let color = (material.diffuse.contents as? NSColor)?.usingColorSpace(.sRGB) {
                part["color"] = [color.redComponent, color.greenComponent, color.blueComponent]
            }
            return part
        }
        let faces = (profile == .xiaomi ? [.front, .side] : RemoteFace.allCases).map { face in
            ["name": face.rawValue, "yaw": face.yaw, "keys": face.keys(for: profile).map(\.rawValue)] as [String: Any]
        }
        let descriptions = Dictionary(uniqueKeysWithValues: anchors.map { key, anchor -> (String, [String: Any]) in
            let placement = key.labelPosition(for: profile)
            let p = anchor.position
            return (key.rawValue, [
                "name": key.name, "icon": key.icon, "action": key.nativeAction(for: profile),
                "guide": key.guide(for: profile), "left": placement.left, "level": placement.level,
                "mappable": profile == .xiaomi ? key.isXiaomiMappable : key.candidate != nil,
                "anchor": [p.x, p.y, p.z]
            ])
        })
        return ["name": profile.rawValue, "parts": meshes, "keys": descriptions, "faces": faces]
    }
}

@main
struct ExportRemoteModels {
    @MainActor static func main() throws {
        let models = RemoteProfile.allCases.map { RemoteSceneView(profile: $0).asset(for: $0) }
        let output = try JSONSerialization.data(withJSONObject: models, options: [.sortedKeys])
        FileHandle.standardOutput.write(output)
    }
}
