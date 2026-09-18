//
//  BufferShaderExample.swift
//  RealityKitTest
//
//  Example of custom geometry rendered with Metal vertex & pixel shaders
//  (a RealityKit CustomMaterial), where the vertex positions and some
//  arbitrary per-vertex data all come from plain Swift [Float] arrays.
//
//  The per-vertex data travels to the shaders in the mesh's UV1 channel:
//    uv1.x = scale factor  -> read by the geometry modifier (vertex shader)
//    uv1.y = colour value  -> read by the surface shader (pixel shader)
//

import Foundation
import Metal
import RealityKit

enum BufferShaderExampleError: Error {
	case metalUnavailable
}

enum BufferShaderExample {
	// Interleaved vertex layout, must match the attribute offsets below:
	// position (3 floats) + normal (3 floats) + uv1 (2 floats)
	private static let floatsPerVertex = 8
	private static let vertexStride = MemoryLayout<Float>.stride * floatsPerVertex

	/// Builds a sphere whose vertices are scaled per-vertex by the geometry
	/// modifier and coloured per-pixel by the surface shader, both driven by
	/// values from CPU-side [Float] arrays.
	@MainActor
	static func makeEntity() throws -> ModelEntity {
		let rings = 48
		let segments = 96
		let radius: Float = 0.5

		// --- 1) CPU-side buffers: plain [Float] arrays -------------------

		// xyz triples, one per vertex
		var positions: [Float] = []
		// xyz triples, one per vertex
		var normals: [Float] = []
		// Two arbitrary floats per vertex: (scale for the vertex shader,
		// colour value for the pixel shader)
		var vertexData: [Float] = []

		for ring in 0...rings {
			let polar = Float(ring) / Float(rings) * .pi
			for segment in 0...segments {
				let azimuth = Float(segment) / Float(segments) * 2 * .pi

				let nx = sin(polar) * cos(azimuth)
				let ny = cos(polar)
				let nz = sin(polar) * sin(azimuth)

				positions += [nx * radius, ny * radius, nz * radius]
				normals += [nx, ny, nz]

				// Arbitrary data: a bumpy pattern over the sphere.
				// scale in 0.75...1.25, colour value in 0...1
				let bump = sin(azimuth * 6) * sin(polar * 5)
				vertexData += [1.0 + 0.25 * bump, 0.5 + 0.5 * bump]
			}
		}

		var indices: [UInt32] = []
		for ring in 0..<rings {
			for segment in 0..<segments {
				let i0 = UInt32(ring * (segments + 1) + segment)
				let i1 = i0 + 1
				let i2 = i0 + UInt32(segments + 1)
				let i3 = i2 + 1
				indices += [i0, i1, i2, i1, i3, i2]
			}
		}

		let vertexCount = positions.count / 3

		// --- 2) Upload the arrays into a LowLevelMesh GPU buffer ---------

		var descriptor = LowLevelMesh.Descriptor()
		descriptor.vertexCapacity = vertexCount
		descriptor.vertexAttributes = [
			.init(semantic: .position, format: .float3, offset: 0),
			.init(semantic: .normal, format: .float3, offset: MemoryLayout<Float>.stride * 3),
			// UV1 is a generic per-vertex channel the shaders can read
			.init(semantic: .uv1, format: .float2, offset: MemoryLayout<Float>.stride * 6),
		]
		descriptor.vertexLayouts = [.init(bufferIndex: 0, bufferOffset: 0, bufferStride: vertexStride)]
		descriptor.indexCapacity = indices.count
		descriptor.indexType = .uint32

		let mesh = try LowLevelMesh(descriptor: descriptor)

		mesh.withUnsafeMutableBytes(bufferIndex: 0) { rawBuffer in
			let floats = rawBuffer.bindMemory(to: Float.self)
			for vertex in 0..<vertexCount {
				let base = vertex * floatsPerVertex
				floats[base + 0] = positions[vertex * 3 + 0]
				floats[base + 1] = positions[vertex * 3 + 1]
				floats[base + 2] = positions[vertex * 3 + 2]
				floats[base + 3] = normals[vertex * 3 + 0]
				floats[base + 4] = normals[vertex * 3 + 1]
				floats[base + 5] = normals[vertex * 3 + 2]
				floats[base + 6] = vertexData[vertex * 2 + 0]
				floats[base + 7] = vertexData[vertex * 2 + 1]
			}
		}

		mesh.withUnsafeMutableIndices { rawIndices in
			let buffer = rawIndices.bindMemory(to: UInt32.self)
			for (i, index) in indices.enumerated() {
				buffer[i] = index
			}
		}

		// Bounds must cover the largest per-vertex scale (1.25 * radius)
		let bound = radius * 1.3
		mesh.parts.replaceAll([
			LowLevelMesh.Part(
				indexCount: indices.count,
				topology: .triangle,
				bounds: BoundingBox(min: [-bound, -bound, -bound], max: [bound, bound, bound])
			)
		])

		let meshResource = try MeshResource(from: mesh)

		// --- 3) CustomMaterial wrapping the Metal shader functions -------

		guard let device = MTLCreateSystemDefaultDevice(),
			  let library = device.makeDefaultLibrary() else {
			throw BufferShaderExampleError.metalUnavailable
		}

		let geometryModifier = CustomMaterial.GeometryModifier(
			named: "bufferExampleGeometryModifier", in: library)
		let surfaceShader = CustomMaterial.SurfaceShader(
			named: "bufferExampleSurfaceShader", in: library)

		let material = try CustomMaterial(
			surfaceShader: surfaceShader,
			geometryModifier: geometryModifier,
			lightingModel: .lit)

		let entity = ModelEntity(mesh: meshResource, materials: [material])
		// The geometry modifier moves vertices, so pad the culling bounds
		entity.model?.boundsMargin = radius * 0.5
		return entity
	}
}
