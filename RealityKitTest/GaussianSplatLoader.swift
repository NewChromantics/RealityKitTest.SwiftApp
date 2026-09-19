//
//  GaussianSplatLoader.swift
//  RealityKitTest
//
//  Imports 3D Gaussian Splat data from an INRIA-style PLY file or SOG (Splat Object Geometry) file
//  and produces an Entity with a GaussianSplatComponent.
//
//  PLY: The format written by the original 3DGS training pipeline, parsed with PopPly.
//  SOG: A more efficient binary format with header and packed splat data.
//
//  RealityKit doesn't load splat files directly - we parse the data,
//  pack the per-splat properties into an interleaved LowLevelBuffer,
//  and describe the layout with GaussianSplatResource.BufferDescriptors.
//

import Foundation
import Metal
import RealityKit
import PopPly
import UniformTypeIdentifiers
import Compression

nonisolated enum GaussianSplatLoader
{
	enum Error: LocalizedError
	{
		case missingVertexElement
		case missingProperty(String)
		case unsupportedSphericalHarmonicCount(Int)
		case unsupportedFileFormat
		case invalidSOGHeader
		case corruptedSOGData

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
				case .unsupportedFileFormat:
					"Unsupported file format (expected .ply or .sog)"
				case .invalidSOGHeader:
					"Invalid SOG file header (not a binary splat format)"
				case .corruptedSOGData:
					"SOG file data is corrupted or incomplete"
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
		
		let splats: SplatData
		let fileExtension = url.pathExtension.lowercased()
		
		switch fileExtension
		{
			case "ply":
				splats = try await Task.detached(priority: .userInitiated)
				{
					try parsePLY(url: url)
				}
				.value
			case "sog":
				splats = try await Task.detached(priority: .userInitiated)
				{
					try parseSOG(url: url)
				}
				.value
			default:
				throw Error.unsupportedFileFormat
		}
		
		print("GaussianSplatLoader: parsed \(splats.count) splats (\(splats.floatsPerSplat) floats each) in \(String(format: "%.2f", Date().timeIntervalSince(startTime)))s")

		return try makeEntity(from: splats)
	}

	// MARK: - PLY parsing

	nonisolated private static func parsePLY(url: URL) throws -> SplatData
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
	
	// MARK: - SOG parsing
	
	/// SOG file format can be either:
	/// 1. Binary format with header (32 bytes):
	///    - Magic number: "SOG\0" (4 bytes)
	///    - Version: UInt32 (4 bytes)
	///    - Splat count: UInt32 (4 bytes)
	///    - SH degree: UInt32 (4 bytes) - 0, 1, 2, or 3
	///    - Reserved: 16 bytes
	///    - Data: Per splat - position(3) + scale(3) + rotation(4) + opacity(1) + SH coefficients
	///
	/// 2. ZIP archive containing WebP images (parsed using SOGWebPParser)
	nonisolated private static func parseSOG(url: URL) throws -> SplatData
	{
		let data = try Data(contentsOf: url)
		
		print("GaussianSplatLoader: SOG file size: \(data.count) bytes")
		
		// Check if this is a ZIP file (starts with PK signature)
		let pkSignature = Data([0x50, 0x4B]) // "PK"
		if data.count >= 2 && data.prefix(2) == pkSignature
		{
			print("GaussianSplatLoader: detected ZIP archive (WebP-based SOG format)")
			return try parseSOGWebP(url: url)
		}
		
		// Parse header for binary format
		guard data.count >= 32 else
		{
			print("GaussianSplatLoader: file too small - need at least 32 bytes for header")
			throw Error.invalidSOGHeader
		}
		
		// Check magic number "SOG\0"
		let magicBytes = data.prefix(4)
		let expectedMagic = Data([0x53, 0x4F, 0x47, 0x00]) // "SOG\0"
		
		// Debug: print actual bytes
		let magicHex = magicBytes.map { String(format: "%02X", $0) }.joined(separator: " ")
		let magicString = String(data: magicBytes, encoding: .utf8) ?? "(non-UTF8)"
		print("GaussianSplatLoader: Magic bytes: \(magicHex) (\(magicString))")
		
		guard magicBytes == expectedMagic else
		{
			print("GaussianSplatLoader: invalid magic number - expected 'SOG\\0' (53 4F 47 00)")
			throw Error.invalidSOGHeader
		}
		
		// Read header fields
		let version = data.withUnsafeBytes { $0.load(fromByteOffset: 4, as: UInt32.self) }
		let splatCount = Int(data.withUnsafeBytes { $0.load(fromByteOffset: 8, as: UInt32.self) })
		let shDegree = Int(data.withUnsafeBytes { $0.load(fromByteOffset: 12, as: UInt32.self) })
		
		print("GaussianSplatLoader: SOG version \(version), \(splatCount) splats, SH degree \(shDegree)")
		
		guard shDegree >= 0 && shDegree <= 3 else
		{
			throw Error.unsupportedSphericalHarmonicCount(shDegree)
		}
		
		// Calculate expected data size
		let shCoefficientsPerChannel = [1, 4, 9, 16][shDegree] // degree 0: 1, degree 1: 4, degree 2: 9, degree 3: 16
		let sphericalHarmonicsFloats = shCoefficientsPerChannel * 3 // RGB channels
		let floatsPerSplat = 11 + sphericalHarmonicsFloats // position(3) + scale(3) + rotation(4) + opacity(1) + SH
		let expectedDataSize = 32 + (splatCount * floatsPerSplat * MemoryLayout<Float>.size)
		
		print("GaussianSplatLoader: expected \(expectedDataSize) bytes, got \(data.count) bytes")
		
		guard data.count >= expectedDataSize else
		{
			throw Error.corruptedSOGData
		}
		
		// Extract interleaved float data
		var interleaved = [Float](repeating: 0, count: splatCount * floatsPerSplat)
		let dataOffset = 32
		data.withUnsafeBytes
		{
			(buffer: UnsafeRawBufferPointer) in
			let floatBuffer = buffer.baseAddress!.advanced(by: dataOffset).assumingMemoryBound(to: Float.self)
			interleaved.withUnsafeMutableBufferPointer
			{
				dest in
				dest.baseAddress!.initialize(from: floatBuffer, count: splatCount * floatsPerSplat)
			}
		}
		
		return SplatData(count: splatCount,
						 floatsPerSplat: floatsPerSplat,
						 sphericalHarmonicsFloats: sphericalHarmonicsFloats,
						 interleaved: interleaved)
	}
	
	// MARK: - SOG WebP Format Parsing
	
	/// Parse SOG files in WebP format (ZIP archive) using the PlayCanvas spec-compliant decoder
	nonisolated private static func parseSOGWebP(url: URL) throws -> SplatData
	{
		// Use the spec-compliant PlayCanvas SOG decoder
		let scene = try SOGDecoder.decode(contentsOf: url)
		
		// Log any warnings from the decoder
		for warning in scene.warnings
		{
			print("GaussianSplatLoader: SOG warning - \(warning)")
		}
		
		// Calculate spherical harmonics size
		// SOG stores SH0 (DC) in colors array, and optional higher-order in sh
		let shFloats: Int
		if let sh = scene.sh
		{
			// Total SH coefficients = DC (3) + AC coefficients
			shFloats = 3 + (sh.coefficientsPerChannel * 3)
		}
		else
		{
			shFloats = 3 // Just DC
		}
		
		// Layout: position(3) + scale(3) + rotation(4) + opacity(1) + SH coefficients
		let floatsPerSplat = 11 + shFloats
		
		var interleaved: [Float] = []
		interleaved.reserveCapacity(scene.count * floatsPerSplat)
		
		for i in 0..<scene.count
		{
			// Position
			let pos = scene.positions[i]
			interleaved.append(pos.x)
			interleaved.append(pos.y)
			interleaved.append(pos.z)
			
			// Scale (already exp()'d by the decoder, need to convert back to log for RealityKit's exponential activation)
			let scale = scene.scales[i]
			interleaved.append(log(scale.x))
			interleaved.append(log(scale.y))
			interleaved.append(log(scale.z))
			
			// Rotation (quaternion)
			// SOG stores as [w, x, y, z] (lane 0 = w)
			// RealityKit expects [r, x, y, z] where r = w
			let rot = scene.rotations[i]
			interleaved.append(rot[0]) // w (real part)
			interleaved.append(rot[1]) // x
			interleaved.append(rot[2]) // y
			interleaved.append(rot[3]) // z
			
			// Opacity (already in [0, 1], need to convert to logit for RealityKit's sigmoid activation)
			let opacity = scene.opacities[i]
			let clampedOpacity = min(max(opacity, 0.001), 0.999) // Avoid infinities
			let logit = log(clampedOpacity / (1.0 - clampedOpacity))
			interleaved.append(logit)
			
			// SH0 colors (DC component)
			// SOG provides these as gamma-space colors: 0.5 + dc * SH_C0
			// We need to convert back to the DC coefficient for RealityKit
			let shC0: Float = 0.28209479177387814
			let color = scene.colors[i]
			interleaved.append((color.x - 0.5) / shC0)
			interleaved.append((color.y - 0.5) / shC0)
			interleaved.append((color.z - 0.5) / shC0)
			
			// Higher-order SH coefficients (if present)
			if let sh = scene.sh
			{
				let coeffs = sh.coefficients(forGaussian: i)
				for coeff in coeffs
				{
					interleaved.append(coeff.x)
					interleaved.append(coeff.y)
					interleaved.append(coeff.z)
				}
			}
		}
		
		return SplatData(count: scene.count,
						 floatsPerSplat: floatsPerSplat,
						 sphericalHarmonicsFloats: shFloats,
						 interleaved: interleaved)
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
