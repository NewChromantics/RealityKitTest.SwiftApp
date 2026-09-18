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
		
		print("SOGWebPParser: successfully parsed \(positions.count) splats")
		
		return SOGSplatData(
			count: metadata.count,
			positions: positions,
			scales: scales,
			rotations: rotations,
			sh0Colors: sh0Colors,
			shNCoefficients: shNCoefficients,
			metadata: metadata
		)
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
		
		// Each pixel contains data for one splat
		// Lower image has X and Y, upper image has Z
		let pixelsPerRow = lowerData.width
		
		for i in 0..<metadata.count {
			let lowerIdx = i * 4 // RGBA
			let upperIdx = i * 4
			
			// Normalize from [0, 255] to [0, 1]
			let normX = Float(lowerData.data[lowerIdx]) / 255.0
			let normY = Float(lowerData.data[lowerIdx + 1]) / 255.0
			let normZ = Float(upperData.data[upperIdx]) / 255.0
			
			// Denormalize to world coordinates
			let position = SIMD3<Float>(
				normX * range.x + offset.x,
				normY * range.y + offset.y,
				normZ * range.z + offset.z
			)
			
			positions.append(position)
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
		
		var scales: [SIMD3<Float>] = []
		scales.reserveCapacity(metadata.count)
		
		for i in 0..<metadata.count {
			let idx = i * 4 // RGBA
			
			// Each color channel is an index into the codebook
			let indexX = Int(scaleData.data[idx])
			let indexY = Int(scaleData.data[idx + 1])
			let indexZ = Int(scaleData.data[idx + 2])
			
			let scale = SIMD3<Float>(
				codebook[indexX],
				codebook[indexY],
				codebook[indexZ]
			)
			
			scales.append(scale)
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
		
		for i in 0..<metadata.count {
			let idx = i * 4 // RGBA
			
			// Quaternions stored as normalized [0, 255] -> [-1, 1]
			let x = (Float(quatData.data[idx]) / 255.0) * 2.0 - 1.0
			let y = (Float(quatData.data[idx + 1]) / 255.0) * 2.0 - 1.0
			let z = (Float(quatData.data[idx + 2]) / 255.0) * 2.0 - 1.0
			let w = (Float(quatData.data[idx + 3]) / 255.0) * 2.0 - 1.0
			
			// Normalize quaternion
			let quat = simd_quatf(ix: x, iy: y, iz: z, r: w)
			let normalized = simd_normalize(quat)
			
			quaternions.append(normalized)
		}
		
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
		
		var colors: [SIMD3<Float>] = []
		colors.reserveCapacity(metadata.count)
		
		for i in 0..<metadata.count {
			let idx = i * 4 // RGBA
			
			// Each color channel is an index into the codebook
			let indexR = Int(sh0Data.data[idx])
			let indexG = Int(sh0Data.data[idx + 1])
			let indexB = Int(sh0Data.data[idx + 2])
			
			let color = SIMD3<Float>(
				codebook[indexR],
				codebook[indexG],
				codebook[indexB]
			)
			
			colors.append(color)
		}
		
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
	}
	
	private static func loadWebPAsFloats(tempDir: URL, filename: String) throws -> WebPImageData {
		let fileURL = tempDir.appendingPathComponent(filename)
		
		guard FileManager.default.fileExists(atPath: fileURL.path) else {
			throw Error.missingWebPFile(filename)
		}
		
		let webpData = try Data(contentsOf: fileURL)
		
		// Decode WebP using NSImage
		guard let image = NSImage(data: webpData),
			  let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
			throw Error.failedToDecodeWebP(filename)
		}
		
		let width = cgImage.width
		let height = cgImage.height
		
		// Extract RGBA bytes
		guard let dataProvider = cgImage.dataProvider,
			  let pixelData = dataProvider.data as Data? else {
			throw Error.failedToDecodeWebP(filename)
		}
		
		let bytes = [UInt8](pixelData)
		
		return WebPImageData(data: bytes, width: width, height: height)
	}
}
