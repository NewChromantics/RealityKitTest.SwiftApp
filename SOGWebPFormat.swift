//
//  SOGWebPFormat.swift
//  RealityKitTest
//
//  Parser for SOG (Splat Object Geometry) WebP-based format.
//  This format stores Gaussian splat data as a ZIP archive containing:
//  - meta.json: Metadata describing the splat data structure
//  - WebP images: Compressed splat data (positions, scales, rotations, colors, SH coefficients)
//
//  The format uses codebook compression for scales and colors to reduce file size.
//

import Foundation
import AppKit
import simd
import simd

// MARK: - Metadata Structures

struct SOGMetadata: Codable {
	let version: Int
	let asset: SOGAsset
	let count: Int
	let means: SOGMeans
	let scales: SOGScales
	let quats: SOGQuats
	let sh0: SOGSH0
	let shN: SOGSHN?
	
	struct SOGAsset: Codable {
		let generator: String
	}
	
	struct SOGMeans: Codable {
		let mins: [Double]
		let maxs: [Double]
		let files: [String]
	}
	
	struct SOGScales: Codable {
		let codebook: [Double]
		let files: [String]
	}
	
	struct SOGQuats: Codable {
		let files: [String]
	}
	
	struct SOGSH0: Codable {
		let codebook: [Double]
		let files: [String]
	}
	
	struct SOGSHN: Codable {
		let count: Int
		let bands: Int
		let codebook: [Double]
		let files: [String]
	}
}

// MARK: - Parsed Splat Data

struct SOGSplatData {
	let count: Int
	let positions: [SIMD3<Float>]
	let scales: [SIMD3<Float>]
	let rotations: [simd_quatf]
	let sh0Colors: [SIMD3<Float>]
	let shNCoefficients: [[Float]]? // Optional higher-order SH
	let metadata: SOGMetadata
}

// MARK: - Parser

enum SOGWebPParser {
	enum Error: LocalizedError {
		case notAZipFile
		case missingMetadata
		case invalidMetadata(String)
		case missingWebPFile(String)
		case failedToDecodeWebP(String)
		case invalidDataDimensions
		
		var errorDescription: String? {
			switch self {
			case .notAZipFile:
				return "SOG file is not a valid ZIP archive"
			case .missingMetadata:
				return "SOG file missing meta.json"
			case .invalidMetadata(let reason):
				return "Invalid metadata: \(reason)"
			case .missingWebPFile(let filename):
				return "Missing WebP file: \(filename)"
			case .failedToDecodeWebP(let filename):
				return "Failed to decode WebP image: \(filename)"
			case .invalidDataDimensions:
				return "WebP data dimensions don't match expected splat count"
			}
		}
	}
	
	/// Parse a SOG file from a URL
	static func parse(url: URL) throws -> SOGSplatData {
		print("SOGWebPParser: parsing \(url.lastPathComponent)...")
		
		// Create temporary directory for extraction
		let fileManager = FileManager.default
		let tempDir = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
		try fileManager.createDirectory(at: tempDir, withIntermediateDirectories: true)
		
		defer {
			// Clean up temp directory
			try? fileManager.removeItem(at: tempDir)
		}
		
		// Unzip the SOG file using native unzip tool
		let process = Process()
		process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
		process.arguments = ["-q", "-o", url.path, "-d", tempDir.path]
		
		try process.run()
		process.waitUntilExit()
		
		guard process.terminationStatus == 0 else {
			throw Error.notAZipFile
		}
		
		// Read metadata
		let metaURL = tempDir.appendingPathComponent("meta.json")
		guard fileManager.fileExists(atPath: metaURL.path) else {
			throw Error.missingMetadata
		}
		
		let metadataData = try Data(contentsOf: metaURL)
		let decoder = JSONDecoder()
		let metadata = try decoder.decode(SOGMetadata.self, from: metadataData)
		
		print("SOGWebPParser: version \(metadata.version), \(metadata.count) splats")
		print("SOGWebPParser: generator: \(metadata.asset.generator)")
		
		// Parse positions (means)
		let positions = try parseMeans(tempDir: tempDir, metadata: metadata)
		
		// Parse scales
		let scales = try parseScales(tempDir: tempDir, metadata: metadata)
		
		// Parse rotations (quaternions)
		let rotations = try parseQuaternions(tempDir: tempDir, metadata: metadata)
		
		// Parse SH0 (base colors)
		let sh0Colors = try parseSH0(tempDir: tempDir, metadata: metadata)
		
		// Parse higher-order SH if present
		let shNCoefficients = try? parseSHN(tempDir: tempDir, metadata: metadata)
		
		// Apply standard PLY/SOG file convention: 180° rotation around Z-axis
		// File coordinates = rotate(world, 180° around Z)
		// We need to apply the inverse to get world coordinates
		print("SOGWebPParser: applying standard PLY/SOG coordinate convention (180° Z rotation)...")
		let correctedPositions = applyFileConvention(positions: positions)
		let correctedRotations = applyFileConvention(rotations: rotations)
		
		print("SOGWebPParser: successfully parsed \(correctedPositions.count) splats")
		
		return SOGSplatData(
			count: metadata.count,
			positions: correctedPositions,
			scales: scales,
			rotations: correctedRotations,
			sh0Colors: sh0Colors,
			shNCoefficients: shNCoefficients,
			metadata: metadata
		)
	}
	
	// MARK: - Coordinate Convention
	
	/// Apply the standard PLY/SOG file convention
	/// File coordinates are rotated 180° around Z from world coordinates
	/// This applies the inverse transform to convert file -> world
	private static func applyFileConvention(positions: [SIMD3<Float>]) -> [SIMD3<Float>] {
		// 180° rotation around Z axis: negate X and Y, keep Z
		let rotationMatrix = simd_float3x3(
			SIMD3<Float>(-1, 0, 0),
			SIMD3<Float>(0, -1, 0),
			SIMD3<Float>(0, 0, 1)
		)
		
		return positions.map { rotationMatrix * $0 }
	}
	
	/// Apply the standard PLY/SOG file convention to rotations
	/// Rotations need to be composed with the coordinate frame rotation
	private static func applyFileConvention(rotations: [simd_quatf]) -> [simd_quatf] {
		// 180° rotation around Z axis as quaternion
		// Rotation by π around Z: (x=0, y=0, z=sin(π/2), w=cos(π/2)) = (0, 0, 1, 0)
		let correctionQuat = simd_quatf(ix: 0, iy: 0, iz: 1, r: 0)
		
		// Apply correction: correctionQuat * originalQuat
		return rotations.map { correctionQuat * $0 }
	}
	
	// MARK: - Position Parsing
	
	private static func parseMeans(tempDir: URL, metadata: SOGMetadata) throws -> [SIMD3<Float>] {
		print("SOGWebPParser: parsing positions from \(metadata.means.files)...")
		
		// Positions are stored as two WebP images (lower and upper components)
		guard metadata.means.files.count == 2 else {
			throw Error.invalidMetadata("Expected 2 means files, got \(metadata.means.files.count)")
		}
		
		let lowerData = try loadWebPAsFloats(tempDir: tempDir, filename: metadata.means.files[0])
		let upperData = try loadWebPAsFloats(tempDir: tempDir, filename: metadata.means.files[1])
		
		// Decode positions using min/max bounds
		let mins = metadata.means.mins.map { Float($0) }
		let maxs = metadata.means.maxs.map { Float($0) }
		let range = SIMD3<Float>(
			maxs[0] - mins[0],
			maxs[1] - mins[1],
			maxs[2] - mins[2]
		)
		let offset = SIMD3<Float>(mins[0], mins[1], mins[2])
		
		var positions: [SIMD3<Float>] = []
		positions.reserveCapacity(metadata.count)
		
		// The WebP images store data in a grid layout
		// We need to read sequentially through the pixels
		let totalPixels = lowerData.width * lowerData.height
		print("SOGWebPParser: lower image: \(lowerData.width)x\(lowerData.height) = \(totalPixels) pixels")
		print("SOGWebPParser: upper image: \(upperData.width)x\(upperData.height) pixels")
		print("SOGWebPParser: position range: \(range), offset: \(offset)")
		
		// Each pixel encodes position using 16-bit precision per axis
		// Per PlayCanvas spec: each axis uses the SAME channel from both images
		// - X axis: channel 0 from lower (low byte) + channel 0 from upper (high byte)
		// - Y axis: channel 1 from lower (low byte) + channel 1 from upper (high byte)  
		// - Z axis: channel 2 from lower (low byte) + channel 2 from upper (high byte)
		for i in 0..<min(metadata.count, totalPixels) {
			let idx = i * lowerData.bytesPerPixel
			
			// Build 16-bit value for each axis: (upper << 8) | lower
			let xValue = (UInt16(upperData.data[idx]) << 8) | UInt16(lowerData.data[idx])
			let yValue = (UInt16(upperData.data[idx + 1]) << 8) | UInt16(lowerData.data[idx + 1])
			let zValue = (UInt16(upperData.data[idx + 2]) << 8) | UInt16(lowerData.data[idx + 2])
			
			// Normalize from [0, 65535] to [0, 1]
			let normX = Float(xValue) / 65535.0
			let normY = Float(yValue) / 65535.0
			let normZ = Float(zValue) / 65535.0
			
			// Apply unlog function as per PlayCanvas spec
			func unlog(_ n: Double) -> Double {
				(n < 0 ? -1.0 : (n > 0 ? 1.0 : 0.0)) * (exp(abs(n)) - 1.0)
			}
			
			// Denormalize using mins/maxs, then apply unlog
			let position = SIMD3<Float>(
				Float(unlog(Double(mins[0]) + Double(range.x) * Double(normX))),
				Float(unlog(Double(mins[1]) + Double(range.y) * Double(normY))),
				Float(unlog(Double(mins[2]) + Double(range.z) * Double(normZ)))
			)
			
			if i < 3 {
				print("SOGWebPParser: splat \(i)")
				print("  16-bit: x=\(xValue), y=\(yValue), z=\(zValue)")
				print("  normalized: (\(normX), \(normY), \(normZ))")
				print("  world: \(position)")
			}
			
			positions.append(position)
		}
		
		print("SOGWebPParser: decoded \(positions.count) positions")
		// Debug: print first few positions
		if positions.count > 0 {
			print("SOGWebPParser: first position: \(positions[0])")
			if positions.count > 1 {
				print("SOGWebPParser: second position: \(positions[1])")
			}
		}
		return positions
	}
	
	// MARK: - Scale Parsing
	
	private static func parseScales(tempDir: URL, metadata: SOGMetadata) throws -> [SIMD3<Float>] {
		print("SOGWebPParser: parsing scales from \(metadata.scales.files)...")
		
		guard metadata.scales.files.count == 1 else {
			throw Error.invalidMetadata("Expected 1 scales file")
		}
		
		let scaleData = try loadWebPAsFloats(tempDir: tempDir, filename: metadata.scales.files[0])
		let codebook = metadata.scales.codebook.map { Float($0) }
		
		print("SOGWebPParser: scale codebook has \(codebook.count) entries")
		print("SOGWebPParser: scale codebook range: [\(codebook.min() ?? 0), \(codebook.max() ?? 0)]")
		
		var scales: [SIMD3<Float>] = []
		scales.reserveCapacity(metadata.count)
		
		let totalPixels = scaleData.width * scaleData.height
		
		for i in 0..<min(metadata.count, totalPixels) {
			let idx = i * scaleData.bytesPerPixel
			
			// Each color channel is an index into the codebook
			let indexX = min(Int(scaleData.data[idx]), codebook.count - 1)
			let indexY = min(Int(scaleData.data[idx + 1]), codebook.count - 1)
			let indexZ = min(Int(scaleData.data[idx + 2]), codebook.count - 1)
			
			let scale = SIMD3<Float>(
				codebook[indexX],
				codebook[indexY],
				codebook[indexZ]
			)
			
			scales.append(scale)
		}
		
		print("SOGWebPParser: decoded \(scales.count) scales")
		if scales.count > 0 {
			print("SOGWebPParser: first scale: \(scales[0])")
		}
		return scales
	}
	
	// MARK: - Quaternion Parsing
	
	private static func parseQuaternions(tempDir: URL, metadata: SOGMetadata) throws -> [simd_quatf] {
		print("SOGWebPParser: parsing quaternions from \(metadata.quats.files)...")
		
		guard metadata.quats.files.count == 1 else {
			throw Error.invalidMetadata("Expected 1 quats file")
		}
		
		let quatData = try loadWebPAsFloats(tempDir: tempDir, filename: metadata.quats.files[0])
		
		var quaternions: [simd_quatf] = []
		quaternions.reserveCapacity(metadata.count)
		
		let totalPixels = quatData.width * quatData.height
		
		for i in 0..<min(metadata.count, totalPixels) {
			let idx = i * quatData.bytesPerPixel
			
			// Quaternions stored as normalized [0, 255] -> [-1, 1]
			// RGBA = x, y, z, w
			let x = (Float(quatData.data[idx]) / 255.0) * 2.0 - 1.0
			let y = (Float(quatData.data[idx + 1]) / 255.0) * 2.0 - 1.0
			let z = (Float(quatData.data[idx + 2]) / 255.0) * 2.0 - 1.0
			let w = (Float(quatData.data[idx + 3]) / 255.0) * 2.0 - 1.0
			
			// Create quaternion (RealityKit uses r, x, y, z order)
			let quat = simd_quatf(ix: x, iy: y, iz: z, r: w)
			let normalized = simd_normalize(quat)
			
			quaternions.append(normalized)
		}
		
		print("SOGWebPParser: decoded \(quaternions.count) quaternions")
		return quaternions
	}
	
	// MARK: - SH0 Color Parsing
	
	private static func parseSH0(tempDir: URL, metadata: SOGMetadata) throws -> [SIMD3<Float>] {
		print("SOGWebPParser: parsing SH0 colors from \(metadata.sh0.files)...")
		
		guard metadata.sh0.files.count == 1 else {
			throw Error.invalidMetadata("Expected 1 sh0 file")
		}
		
		let sh0Data = try loadWebPAsFloats(tempDir: tempDir, filename: metadata.sh0.files[0])
		let codebook = metadata.sh0.codebook.map { Float($0) }
		
		print("SOGWebPParser: SH0 codebook has \(codebook.count) entries")
		
		var colors: [SIMD3<Float>] = []
		colors.reserveCapacity(metadata.count)
		
		let totalPixels = sh0Data.width * sh0Data.height
		
		for i in 0..<min(metadata.count, totalPixels) {
			let idx = i * sh0Data.bytesPerPixel
			
			// Each color channel is an index into the codebook
			let indexR = min(Int(sh0Data.data[idx]), codebook.count - 1)
			let indexG = min(Int(sh0Data.data[idx + 1]), codebook.count - 1)
			let indexB = min(Int(sh0Data.data[idx + 2]), codebook.count - 1)
			
			let color = SIMD3<Float>(
				codebook[indexR],
				codebook[indexG],
				codebook[indexB]
			)
			
			colors.append(color)
		}
		
		print("SOGWebPParser: decoded \(colors.count) colors")
		return colors
	}
	
	// MARK: - SHN Parsing (Higher-Order Spherical Harmonics)
	
	private static func parseSHN(tempDir: URL, metadata: SOGMetadata) throws -> [[Float]] {
		guard let shN = metadata.shN else {
			throw Error.invalidMetadata("No SHN data present")
		}
		
		print("SOGWebPParser: parsing SHN coefficients (bands: \(shN.bands))...")
		
		// TODO: Implement SHN parsing if needed
		// This is more complex as it uses a different compression scheme
		
		return []
	}
	
	// MARK: - WebP Loading Helper
	
	private struct WebPImageData {
		let data: [UInt8]
		let width: Int
		let height: Int
		let bytesPerPixel: Int
	}
	
	private static func loadWebPAsFloats(tempDir: URL, filename: String) throws -> WebPImageData {
		let fileURL = tempDir.appendingPathComponent(filename)
		
		guard FileManager.default.fileExists(atPath: fileURL.path) else {
			throw Error.missingWebPFile(filename)
		}
		
		let webpData = try Data(contentsOf: fileURL)
		
		// Decode WebP using NSBitmapImageRep directly
		// This gives us more control over the pixel format
		guard let bitmapRep = NSBitmapImageRep(data: webpData) else {
			throw Error.failedToDecodeWebP(filename)
		}
		
		let width = bitmapRep.pixelsWide
		let height = bitmapRep.pixelsHigh
		let bytesPerPixel = bitmapRep.bitsPerPixel / 8
		
		print("SOGWebPParser: WebP details - \(width)x\(height), \(bitmapRep.bitsPerPixel) bpp, \(bitmapRep.bytesPerRow) bytes/row")
		print("SOGWebPParser: format - samples/pixel: \(bitmapRep.samplesPerPixel), alpha: \(bitmapRep.hasAlpha)")
		
		// Get raw pixel data
		guard let rawBitmapData = bitmapRep.bitmapData else {
			throw Error.failedToDecodeWebP(filename)
		}
		
		// Copy the data
		let dataLength = height * bitmapRep.bytesPerRow
		var pixelData = [UInt8](repeating: 0, count: width * height * 4) // Always use 4 bytes per pixel output
		
		// Convert to RGBA format if needed
		if bitmapRep.samplesPerPixel == 4 && bytesPerPixel == 4 {
			// Already RGBA, just copy
			for y in 0..<height {
				for x in 0..<width {
					let srcIdx = y * bitmapRep.bytesPerRow + x * bytesPerPixel
					let dstIdx = (y * width + x) * 4
					pixelData[dstIdx] = rawBitmapData[srcIdx]
					pixelData[dstIdx + 1] = rawBitmapData[srcIdx + 1]
					pixelData[dstIdx + 2] = rawBitmapData[srcIdx + 2]
					pixelData[dstIdx + 3] = rawBitmapData[srcIdx + 3]
				}
			}
		} else {
			// Unsupported format
			throw Error.failedToDecodeWebP(filename)
		}
		
		return WebPImageData(data: pixelData, width: width, height: height, bytesPerPixel: 4)
	}
}
