//
//  GaussianSplatLoader.swift
//  RealityKitTest
//
//  Imports 3D Gaussian Splat data from an INRIA-style PLY file (the format
//  written by the original 3DGS training pipeline) and produces an Entity
//  with a GaussianSplatComponent.
//
//  RealityKit doesn't load splat files directly - we parse the PLY with
//  PopPly, pack the per-splat properties into an interleaved LowLevelBuffer,
//  and describe the layout with GaussianSplatResource.BufferDescriptors.
//

import Foundation
import Metal
import RealityKit
import PopPly

nonisolated enum GaussianSplatLoader
{
	enum Error: LocalizedError
	{
		case missingVertexElement
		case missingProperty(String)
		case unsupportedSphericalHarmonicCount(Int)

		var errorDescription: String?
		{
			switch self
			{
				case .missingVertexElement:
					"PLY file has no \"vertex\" element"
				case .missingProperty(let name):
					"PLY vertex element is missing property \"\(name)\""
				case .unsupportedSphericalHarmonicCount(let count):
					"Unsupported number of f_rest_* spherical harmonic properties: \(count)"
			}
		}
	}

	// Parsed splat data, interleaved per splat as:
	// position(3) scale(3) rotation(4) opacity(1) sphericalHarmonics(3...)
	struct SplatData
	{
		var count: Int
		var floatsPerSplat: Int
		var sphericalHarmonicsFloats: Int
		var interleaved: [Float]
	}

	/// Parse the PLY off the main actor, then build the RealityKit entity.
	@MainActor
	static func loadEntity(from url: URL) async throws -> Entity
	{
		print("GaussianSplatLoader: parsing \(url.lastPathComponent)...")
		let startTime = Date()
		let splats = try await Task.detached(priority: .userInitiated)
		{
			try parse(url: url)
		}
		.value
		print("GaussianSplatLoader: parsed \(splats.count) splats (\(splats.floatsPerSplat) floats each) in \(String(format: "%.2f", Date().timeIntervalSince(startTime)))s")

		return try makeEntity(from: splats)
	}

	// MARK: - PLY parsing

	nonisolated private static func parse(url: URL) throws -> SplatData
	{
		let collector = SplatCollector()
		try PLYReader.read(url: url, to: collector)

		guard collector.splatCount > 0, !collector.interleaved.isEmpty else
		{
			throw Error.missingVertexElement
		}

		return SplatData(count: collector.splatCount,
						 floatsPerSplat: collector.floatsPerSplat,
						 sphericalHarmonicsFloats: 3 + collector.restIndices.count,
						 interleaved: collector.interleaved)
	}

	// PLYReader delegate that resolves property indices from the header,
	// then appends each vertex's values in our interleaved layout.
	private final class SplatCollector: PLYReaderDelegate
	{
		var vertexElementIndex: Int? = nil
		var positionIndices: [Int] = []
		var scaleIndices: [Int] = []
		var rotationIndices: [Int] = []
		var opacityIndex = 0
		var dcIndices: [Int] = []
		var restIndices: [Int] = []

		var splatCount = 0
		var floatsPerSplat = 0
		var interleaved: [Float] = []

		func didStartReading(withHeader header: PLYHeader) throws
		{
			guard let elementIndex = header.elements.firstIndex(where: { $0.name == "vertex" }) else
			{
				throw Error.missingVertexElement
			}
			let element = header.elements[elementIndex]
			let names = element.properties.map { $0.name }

			func index(of name: String) throws -> Int
			{
				guard let index = names.firstIndex(of: name) else
				{
					throw Error.missingProperty(name)
				}
				return index
			}

			positionIndices = [try index(of: "x"), try index(of: "y"), try index(of: "z")]
			scaleIndices = [try index(of: "scale_0"), try index(of: "scale_1"), try index(of: "scale_2")]
			// rot_0 is the quaternion's scalar (w) component, matching RealityKit's expected r,x,y,z order
			rotationIndices = [try index(of: "rot_0"), try index(of: "rot_1"), try index(of: "rot_2"), try index(of: "rot_3")]
			opacityIndex = try index(of: "opacity")
			dcIndices = [try index(of: "f_dc_0"), try index(of: "f_dc_1"), try index(of: "f_dc_2")]

			// Optional higher-order spherical harmonics (f_rest_0...)
			var rest: [Int] = []
			while let index = names.firstIndex(of: "f_rest_\(rest.count)")
			{
				rest.append(index)
			}
			guard [0, 9, 24, 45].contains(rest.count) else
			{
				throw Error.unsupportedSphericalHarmonicCount(rest.count)
			}
			restIndices = rest

			vertexElementIndex = elementIndex
			splatCount = Int(element.count)
			// position(3) + scale(3) + rotation(4) + opacity(1) + SH DC(3) + SH rest
			floatsPerSplat = 11 + 3 + rest.count
			interleaved.reserveCapacity(splatCount * floatsPerSplat)
			print("GaussianSplatLoader: header ok - format \(header.format), \(splatCount) vertices, \(names.count) properties, \(rest.count) f_rest coefficients")
		}

		func didRead(element: PLYElement, typeIndex: Int, withHeader elementHeader: PLYHeader.Element) throws
		{
			guard typeIndex == vertexElementIndex else
			{
				return
			}

			for index in positionIndices
			{
				interleaved.append(try element.float32Value(forPropertyIndex: index))
			}
			for index in scaleIndices
			{
				interleaved.append(try element.float32Value(forPropertyIndex: index))
			}
			for index in rotationIndices
			{
				interleaved.append(try element.float32Value(forPropertyIndex: index))
			}
			interleaved.append(try element.float32Value(forPropertyIndex: opacityIndex))
			for index in dcIndices
			{
				interleaved.append(try element.float32Value(forPropertyIndex: index))
			}

			// The PLY stores f_rest planar (all R coefficients, then G, then B);
			// re-interleave to RGB triples per coefficient.
			let coefficientsPerChannel = restIndices.count / 3
			for coefficient in 0..<coefficientsPerChannel
			{
				interleaved.append(try element.float32Value(forPropertyIndex: restIndices[coefficient]))
				interleaved.append(try element.float32Value(forPropertyIndex: restIndices[coefficientsPerChannel + coefficient]))
				interleaved.append(try element.float32Value(forPropertyIndex: restIndices[2 * coefficientsPerChannel + coefficient]))
			}
		}
	}

	// MARK: - RealityKit resource creation

	@MainActor
	private static func makeEntity(from splats: SplatData) throws -> Entity
	{
		let floatSize = MemoryLayout<Float>.size
		let stride = splats.floatsPerSplat * floatSize
		let byteCount = splats.interleaved.count * floatSize

		// Log the position bounds so off-camera/mis-scaled data is easy to spot
		var minPosition = SIMD3<Float>(repeating: .greatestFiniteMagnitude)
		var maxPosition = SIMD3<Float>(repeating: -.greatestFiniteMagnitude)
		for splat in 0..<splats.count
		{
			let base = splat * splats.floatsPerSplat
			let position = SIMD3<Float>(splats.interleaved[base], splats.interleaved[base + 1], splats.interleaved[base + 2])
			minPosition = simd_min(minPosition, position)
			maxPosition = simd_max(maxPosition, position)
		}
		print("GaussianSplatLoader: position bounds min \(minPosition) max \(maxPosition)")

		// Pad capacity to a 16-byte multiple
		let buffer = try LowLevelBuffer(descriptor: .init(capacity: (byteCount + 15) & ~0xF, sizeMultiple: 16))
		buffer.replaceUnsafeMutableBytes
		{
			destination in
			splats.interleaved.withUnsafeBytes
			{
				source in
				destination.copyMemory(from: source)
			}
		}

		// Describe where each per-splat property lives in the interleaved buffer
		let position = GaussianSplatResource.BufferDescriptor(buffer: buffer, format: .float3, stride: stride, offset: 0)
		let scale = GaussianSplatResource.BufferDescriptor(buffer: buffer, format: .float3, stride: stride, offset: 3 * floatSize)
		let rotation = GaussianSplatResource.BufferDescriptor(buffer: buffer, format: .float4, stride: stride, offset: 6 * floatSize)
		let opacity = GaussianSplatResource.BufferDescriptor(buffer: buffer, format: .float, stride: stride, offset: 10 * floatSize)
		let sphericalHarmonics = GaussianSplatResource.BufferDescriptor(buffer: buffer, format: .float3, stride: stride, offset: 11 * floatSize)

		let degree: GaussianSplatResource.SphericalHarmonicDegree = switch splats.sphericalHarmonicsFloats
		{
			case 3: .zero
			case 12: .first
			case 27: .second
			default: .third
		}

		print("GaussianSplatLoader: creating buffer resource - \(byteCount) bytes, stride \(stride), SH degree \(degree)")
		let bufferResource = try GaussianSplatResource.BufferResource(count: splats.count,
																	  position: position,
																	  scale: scale,
																	  rotation: rotation,
																	  opacity: opacity,
																	  sphericalHarmonics: (sphericalHarmonics, degree))
		let resource = GaussianSplatResource(bufferResource)
		print("GaussianSplatLoader: GaussianSplatResource created")
		// 3DGS training stores scale in log space and opacity as an unbounded logit
		resource.scaleActivation = .exponential
		resource.opacityActivation = .sigmoid

		let entity = Entity()
		entity.components.set(GaussianSplatComponent(resource))
		// 3DGS uses a Y-down convention; rotate to RealityKit's Y-up
		entity.orientation = simd_quatf(angle: .pi, axis: [1, 0, 0])
		return entity
	}
}
