//
//  SOGDecoder.swift
//
//  Decoder for the PlayCanvas SOG (Spatially Ordered Gaussians) format, version 2.
//  Spec: https://developer.playcanvas.com/user-manual/gaussian-splatting/formats/sog/
//
//  Supports:
//    - Unbundled datasets (a directory containing meta.json + WebP images)
//    - Bundled datasets (a .sog ZIP archive with the files at the archive root)
//
//  Platforms: iOS 14+ / macOS 11+ / tvOS 14+ / visionOS (uses ImageIO for WebP and the
//  Compression framework for ZIP inflate, so no third-party dependencies).
//
//  Usage:
//      let scene = try SOGDecoder.decode(contentsOf: url)   // directory, meta.json, or .sog
//      print(scene.count, scene.positions[0], scene.colors[0], scene.opacities[0])
//

import Foundation
import CoreGraphics
import ImageIO
import Compression
import simd

// MARK: - Errors

public enum SOGError: Error, LocalizedError {
	case unsupportedVersion(Int)
	case invalidMeta(String)
	case missingFile(String)
	case invalidZip(String)
	case unsupportedZip(String)
	case imageDecodeFailed(String, String)
	case dimensionMismatch(String)
	case invalidQuaternionMode(index: Int, value: UInt8)
	case invalidLabel(index: Int, label: Int, paletteCount: Int)
	case unrecognizedInput(String)
	
	public var errorDescription: String? {
		switch self {
			case .unsupportedVersion(let v): return "Unsupported SOG version \(v) (this decoder handles version 2)."
			case .invalidMeta(let s): return "Invalid meta.json: \(s)"
			case .missingFile(let s): return "Missing file: \(s)"
			case .invalidZip(let s): return "Invalid ZIP archive: \(s)"
			case .unsupportedZip(let s): return "Unsupported ZIP feature: \(s)"
			case .imageDecodeFailed(let n, let s): return "Failed to decode image \(n): \(s)"
			case .dimensionMismatch(let s): return "Image dimension mismatch: \(s)"
			case .invalidQuaternionMode(let i, let v): return "Invalid quaternion mode byte \(v) at gaussian \(i) (expected 252...255)."
			case .invalidLabel(let i, let l, let c): return "SH label \(l) at gaussian \(i) is out of range (palette size \(c))."
			case .unrecognizedInput(let s): return "Unrecognized input: \(s)"
		}
	}
}

// MARK: - meta.json

public struct SOGMeta: Decodable {
	public struct Asset: Decodable { public var generator: String? }
	public struct Means: Decodable {
		public var mins: [Double]
		public var maxs: [Double]
		public var files: [String]
	}
	public struct Codebooked: Decodable {
		public var codebook: [Float]
		public var files: [String]
	}
	public struct Files: Decodable { public var files: [String] }
	public struct SHN: Decodable {
		public var count: Int
		public var bands: Int
		public var codebook: [Float]
		public var files: [String]
	}
	
	public var version: Int
	public var asset: Asset?
	public var count: Int
	public var antialias: Bool?
	public var means: Means
	public var scales: Codebooked
	public var quats: Files
	public var sh0: Codebooked
	public var shN: SHN?
}

// MARK: - Output model

/// Palette-compressed higher-order (AC) spherical harmonics.
public struct SOGSphericalHarmonics {
	/// Number of SH bands stored here (1...3). Band 0 (DC) is in `SOGScene.colors`.
	public let bands: Int
	/// Coefficients per colour channel: 3, 8 or 15.
	public let coefficientsPerChannel: Int
	/// Number of palette entries.
	public let paletteCount: Int
	/// Decoded palette, laid out as `palette[((entry * coefficientsPerChannel) + c) * 3 + channel]`.
	public let palette: [Float]
	/// Palette index for each gaussian.
	public let labels: [UInt16]
	
	/// AC coefficients for one gaussian. Element `c` holds the (R, G, B) values of coefficient `c`.
	public func coefficients(forGaussian i: Int) -> [SIMD3<Float>] {
		let entry = Int(labels[i])
		var out = [SIMD3<Float>]()
		out.reserveCapacity(coefficientsPerChannel)
		for c in 0..<coefficientsPerChannel {
			let base = (entry * coefficientsPerChannel + c) * 3
			out.append(SIMD3<Float>(palette[base], palette[base + 1], palette[base + 2]))
		}
		return out
	}
}

/// Fully decoded gaussian splat scene (structure-of-arrays).
public struct SOGScene {
	public var count: Int
	public var generator: String?
	public var antialias: Bool
	
	/// World-space positions (right-handed: +x right, +y up, +z back).
	public var positions: [SIMD3<Float>]
	/// Unit quaternions. NOTE the lane order is **[w, x, y, z]** (lane 0 = w), which differs from
	/// `simd_quatf`'s `vector` layout. Convert with `simd_quatf(ix: q[1], iy: q[2], iz: q[3], r: q[0])`.
	public var rotations: [SIMD4<Float>]
	/// Linear per-axis scales (already exp()'d), in scene units.
	public var scales: [SIMD3<Float>]
	/// Gamma-space base colour: `0.5 + dc * SH_C0`. Not clamped.
	public var colors: [SIMD3<Float>]
	/// Opacity in [0, 1].
	public var opacities: [Float]
	/// Higher-order SH, if the file contains them.
	public var sh: SOGSphericalHarmonics?
	/// Non-fatal issues found while decoding.
	public var warnings: [String]
}

// MARK: - Image decoding

/// 8-bit RGBA, row-major, top-left origin, non-premultiplied.
public struct RGBA8Image {
	public let width: Int
	public let height: Int
	public let pixels: [UInt8]
	/// True if the platform decoder returned premultiplied data and some pixels had alpha < 255,
	/// meaning RGB values may have been altered (lossy). See notes on `ImageIOWebPDecoder`.
	public let hadLossyPremultipliedAlpha: Bool
}

public protocol SOGImageDecoder {
	/// Decode an image to raw 8-bit RGBA with NO colour management and NO alpha premultiplication.
	func decode(_ data: Data, name: String) throws -> RGBA8Image
}

/// Default decoder that uses ImageIO. It reads the CGImage's backing pixels directly (no drawing,
/// so no colour conversion happens) and normalises them to RGBA.
///
/// Caveat: SOG stores *data* in RGBA (e.g. `sh0.a` is opacity while RGB are codebook indices, and
/// `quats.a` is a mode flag). If ImageIO hands back premultiplied pixels, RGB values for pixels
/// with alpha < 255 cannot be recovered exactly. Such cases are flagged via
/// `RGBA8Image.hadLossyPremultipliedAlpha` and surfaced in `SOGScene.warnings`. If you hit this,
/// supply your own `SOGImageDecoder` backed by libwebp (WebPDecodeRGBA), which is always exact.
public struct ImageIOWebPDecoder: SOGImageDecoder {
	public init() {}
	
	private enum Ch { case r, g, b, a, x }
	
	public func decode(_ data: Data, name: String) throws -> RGBA8Image {
		let opts: [CFString: Any] = [kCGImageSourceShouldCache: false]
		guard let src = CGImageSourceCreateWithData(data as CFData, opts as CFDictionary),
			  CGImageSourceGetCount(src) > 0,
			  let cg = CGImageSourceCreateImageAtIndex(src, 0, opts as CFDictionary) else {
			throw SOGError.imageDecodeFailed(name, "ImageIO could not decode the image (is WebP supported on this OS?)")
		}
		guard cg.bitsPerComponent == 8, cg.bitsPerPixel == 32 || cg.bitsPerPixel == 24 else {
			throw SOGError.imageDecodeFailed(name, "expected 8-bit RGB(A), got \(cg.bitsPerComponent) bpc / \(cg.bitsPerPixel) bpp")
		}
		if let model = cg.colorSpace?.model, model != .rgb {
			throw SOGError.imageDecodeFailed(name, "expected an RGB image")
		}
		guard let provider = cg.dataProvider, let cfData = provider.data else {
			throw SOGError.imageDecodeFailed(name, "no pixel data")
		}
		
		let bytes = cfData as Data
		let width = cg.width, height = cg.height
		let bytesPerRow = cg.bytesPerRow
		let bytesPerPixel = cg.bitsPerPixel / 8
		guard bytes.count >= bytesPerRow * (height - 1) + width * bytesPerPixel else {
			throw SOGError.imageDecodeFailed(name, "pixel buffer is smaller than expected")
		}
		
		// Work out the in-memory channel order.
		let alphaInfo = CGImageAlphaInfo(rawValue: cg.bitmapInfo.rawValue & CGBitmapInfo.alphaInfoMask.rawValue) ?? .none
		let little = (cg.bitmapInfo.rawValue & CGBitmapInfo.byteOrderMask.rawValue) == CGBitmapInfo.byteOrder32Little.rawValue
		var premultiplied = false
		var order: [Ch]
		if bytesPerPixel == 3 {
			order = [.r, .g, .b]
		} else {
			switch alphaInfo {
				case .last:                order = [.r, .g, .b, .a]
				case .premultipliedLast:   order = [.r, .g, .b, .a]; premultiplied = true
				case .first:               order = [.a, .r, .g, .b]
				case .premultipliedFirst:  order = [.a, .r, .g, .b]; premultiplied = true
				case .noneSkipFirst:       order = [.x, .r, .g, .b]
				case .noneSkipLast, .none: order = [.r, .g, .b, .x]
				default:
					throw SOGError.imageDecodeFailed(name, "unsupported alpha layout")
			}
			if little { order.reverse() }   // 32-bit little-endian words reverse the byte order
		}
		guard let rOff = order.firstIndex(of: .r),
			  let gOff = order.firstIndex(of: .g),
			  let bOff = order.firstIndex(of: .b) else {
			throw SOGError.imageDecodeFailed(name, "could not locate colour channels")
		}
		let aOff = order.firstIndex(of: .a)
		
		var out = [UInt8](repeating: 255, count: width * height * 4)
		var lossy = false
		
		bytes.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
			let src = raw.bindMemory(to: UInt8.self)
			out.withUnsafeMutableBufferPointer { dst in
				for y in 0..<height {
					var s = y * bytesPerRow
					var d = y * width * 4
					for _ in 0..<width {
						var r = Int(src[s + rOff]), g = Int(src[s + gOff]), b = Int(src[s + bOff])
						var a = 255
						if let aOff = aOff { a = Int(src[s + aOff]) }
						if premultiplied && a < 255 {
							lossy = true
							if a == 0 {
								r = 0; g = 0; b = 0
							} else {
								r = min(255, (r * 255 + a / 2) / a)
								g = min(255, (g * 255 + a / 2) / a)
								b = min(255, (b * 255 + a / 2) / a)
							}
						}
						dst[d] = UInt8(r); dst[d + 1] = UInt8(g); dst[d + 2] = UInt8(b); dst[d + 3] = UInt8(a)
						s += bytesPerPixel
						d += 4
					}
				}
			}
		}
		return RGBA8Image(width: width, height: height, pixels: out, hadLossyPremultipliedAlpha: lossy)
	}
}

// MARK: - Resource providers (directory / ZIP)

public protocol SOGResourceProvider {
	func data(named name: String) throws -> Data
}

public struct SOGDirectoryProvider: SOGResourceProvider {
	public let directory: URL
	public init(directory: URL) { self.directory = directory }
	
	public func data(named name: String) throws -> Data {
		let url = directory.appendingPathComponent(name)
		guard let d = try? Data(contentsOf: url, options: .mappedIfSafe) else {
			throw SOGError.missingFile(name)
		}
		return d
	}
}

/// Minimal read-only ZIP reader (stored + deflate entries, no ZIP64, no encryption).
public struct SOGZipProvider: SOGResourceProvider {
	private struct Entry {
		let method: UInt16
		let compressedSize: Int
		let uncompressedSize: Int
		let localHeaderOffset: Int
	}
	
	private let data: Data
	private var entries: [String: Entry] = [:]
	
	public init(archive: Data) throws {
		self.data = archive.startIndex == 0 ? archive : Data(archive)
		try parseCentralDirectory()
	}
	
	private func u16(_ o: Int) throws -> Int {
		guard o >= 0, o + 2 <= data.count else { throw SOGError.invalidZip("truncated") }
		return Int(data[o]) | (Int(data[o + 1]) << 8)
	}
	
	private func u32(_ o: Int) throws -> Int {
		guard o >= 0, o + 4 <= data.count else { throw SOGError.invalidZip("truncated") }
		return Int(data[o]) | (Int(data[o + 1]) << 8) | (Int(data[o + 2]) << 16) | (Int(data[o + 3]) << 24)
	}
	
	private mutating func parseCentralDirectory() throws {
		// Locate End Of Central Directory record (signature 0x06054b50), scanning backwards.
		guard data.count >= 22 else { throw SOGError.invalidZip("file too small") }
		var eocd = -1
		var i = data.count - 22
		let lowest = max(0, data.count - 22 - 65_535)
		while i >= lowest {
			if try u32(i) == 0x0605_4b50 { eocd = i; break }
			i -= 1
		}
		guard eocd >= 0 else { throw SOGError.invalidZip("end of central directory not found") }
		
		let total = try u16(eocd + 10)
		let cdOffset = try u32(eocd + 16)
		if total == 0xFFFF || cdOffset == 0xFFFF_FFFF {
			throw SOGError.unsupportedZip("ZIP64")
		}
		
		var p = cdOffset
		for _ in 0..<total {
			guard try u32(p) == 0x0201_4b50 else { throw SOGError.invalidZip("bad central directory entry") }
			let flags = try u16(p + 8)
			let method = UInt16(try u16(p + 10))
			let csize = try u32(p + 20)
			let usize = try u32(p + 24)
			let nameLen = try u16(p + 28)
			let extraLen = try u16(p + 30)
			let commentLen = try u16(p + 32)
			let localOffset = try u32(p + 42)
			guard p + 46 + nameLen <= data.count else { throw SOGError.invalidZip("truncated name") }
			if flags & 1 != 0 { throw SOGError.unsupportedZip("encrypted entries") }
			if csize == 0xFFFF_FFFF || usize == 0xFFFF_FFFF || localOffset == 0xFFFF_FFFF {
				throw SOGError.unsupportedZip("ZIP64")
			}
			let nameBytes = data.subdata(in: (p + 46)..<(p + 46 + nameLen))
			let name = String(decoding: nameBytes, as: UTF8.self)
			if !name.hasSuffix("/") {
				entries[name] = Entry(method: method, compressedSize: csize,
									  uncompressedSize: usize, localHeaderOffset: localOffset)
			}
			p += 46 + nameLen + extraLen + commentLen
		}
	}
	
	public func data(named name: String) throws -> Data {
		// Spec says files live at the archive root; also tolerate a single wrapping folder.
		let entry = entries[name] ?? entries.first(where: { $0.key.hasSuffix("/" + name) })?.value
		guard let e = entry else { throw SOGError.missingFile(name) }
		
		let lh = e.localHeaderOffset
		guard try u32(lh) == 0x0403_4b50 else { throw SOGError.invalidZip("bad local header for \(name)") }
		let nameLen = try u16(lh + 26)
		let extraLen = try u16(lh + 28)
		let start = lh + 30 + nameLen + extraLen
		let end = start + e.compressedSize
		guard end <= data.count else { throw SOGError.invalidZip("entry \(name) exceeds archive size") }
		let payload = data.subdata(in: start..<end)
		
		switch e.method {
			case 0:
				return payload
			case 8:
				return try SOGZipProvider.inflate(payload, expectedSize: e.uncompressedSize, name: name)
			default:
				throw SOGError.unsupportedZip("compression method \(e.method) in \(name)")
		}
	}
	
	private static func inflate(_ src: Data, expectedSize: Int, name: String) throws -> Data {
		if expectedSize == 0 { return Data() }
		var dst = Data(count: expectedSize)
		let written: Int = dst.withUnsafeMutableBytes { (dstRaw: UnsafeMutableRawBufferPointer) -> Int in
			src.withUnsafeBytes { (srcRaw: UnsafeRawBufferPointer) -> Int in
				guard let d = dstRaw.bindMemory(to: UInt8.self).baseAddress,
					  let s = srcRaw.bindMemory(to: UInt8.self).baseAddress else { return 0 }
				// On Apple platforms COMPRESSION_ZLIB is raw DEFLATE, which is what ZIP uses.
				return compression_decode_buffer(d, expectedSize, s, src.count, nil, COMPRESSION_ZLIB)
			}
		}
		guard written == expectedSize else {
			throw SOGError.invalidZip("inflate of \(name) produced \(written) bytes, expected \(expectedSize)")
		}
		return dst
	}
}

// MARK: - Decoder

public enum SOGDecoder {
	
	/// Decode from a directory containing `meta.json`, a path to `meta.json`, or a bundled `.sog` (ZIP) file.
	public static func decode(contentsOf url: URL,
							  imageDecoder: SOGImageDecoder = ImageIOWebPDecoder()) throws -> SOGScene {
		var isDir: ObjCBool = false
		guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) else {
			throw SOGError.unrecognizedInput("\(url.path) does not exist")
		}
		
		if isDir.boolValue {
			let provider = SOGDirectoryProvider(directory: url)
			return try decode(metaData: provider.data(named: "meta.json"),
							  provider: provider, imageDecoder: imageDecoder)
		}
		
		if url.pathExtension.lowercased() == "json" {
			let provider = SOGDirectoryProvider(directory: url.deletingLastPathComponent())
			let meta = try Data(contentsOf: url)
			return try decode(metaData: meta, provider: provider, imageDecoder: imageDecoder)
		}
		
		let archive = try Data(contentsOf: url, options: .mappedIfSafe)
		return try decode(archive: archive, imageDecoder: imageDecoder)
	}
	
	/// Decode from an in-memory bundled SOG (ZIP).
	public static func decode(archive: Data,
							  imageDecoder: SOGImageDecoder = ImageIOWebPDecoder()) throws -> SOGScene {
		guard archive.count >= 4, archive[archive.startIndex] == 0x50, archive[archive.startIndex + 1] == 0x4B else {
			throw SOGError.unrecognizedInput("not a ZIP archive (expected a directory, meta.json or .sog file)")
		}
		let zip = try SOGZipProvider(archive: archive)
		return try decode(metaData: zip.data(named: "meta.json"), provider: zip, imageDecoder: imageDecoder)
	}
	
	/// Core decode path: `meta.json` bytes plus something that can supply the referenced files.
	public static func decode(metaData: Data,
							  provider: SOGResourceProvider,
							  imageDecoder: SOGImageDecoder = ImageIOWebPDecoder()) throws -> SOGScene {
		let meta: SOGMeta
		do {
			meta = try JSONDecoder().decode(SOGMeta.self, from: metaData)
		} catch {
			throw SOGError.invalidMeta("\(error)")
		}
		guard meta.version == 2 else { throw SOGError.unsupportedVersion(meta.version) }
		
		// ---- Validate meta ----
		guard meta.means.files.count == 2 else { throw SOGError.invalidMeta("means.files must have 2 entries") }
		guard meta.means.mins.count == 3, meta.means.maxs.count == 3 else {
			throw SOGError.invalidMeta("means.mins/maxs must have 3 entries")
		}
		guard meta.scales.files.count == 1, meta.quats.files.count == 1, meta.sh0.files.count == 1 else {
			throw SOGError.invalidMeta("scales/quats/sh0 must each list exactly 1 file")
		}
		guard meta.scales.codebook.count >= 256, meta.sh0.codebook.count >= 256 else {
			throw SOGError.invalidMeta("codebooks must have 256 entries")
		}
		let count = meta.count
		guard count >= 0 else { throw SOGError.invalidMeta("negative count") }
		
		// ---- Load images ----
		var warnings: [String] = []
		func load(_ name: String) throws -> RGBA8Image {
			let bytes = try provider.data(named: name)
			let img = try imageDecoder.decode(bytes, name: name)
			if img.hadLossyPremultipliedAlpha {
				warnings.append("\(name): decoder returned premultiplied alpha; RGB values of pixels with alpha < 255 may be inexact.")
			}
			return img
		}
		
		let meansL = try load(meta.means.files[0])
		let meansU = try load(meta.means.files[1])
		let scalesImg = try load(meta.scales.files[0])
		let quatsImg = try load(meta.quats.files[0])
		let sh0Img = try load(meta.sh0.files[0])
		
		let W = meansL.width, H = meansL.height
		for (n, img) in [(meta.means.files[1], meansU), (meta.scales.files[0], scalesImg),
						 (meta.quats.files[0], quatsImg), (meta.sh0.files[0], sh0Img)] {
			guard img.width == W, img.height == H else {
				throw SOGError.dimensionMismatch("\(n) is \(img.width)x\(img.height), expected \(W)x\(H)")
			}
		}
		guard count <= W * H else {
			throw SOGError.invalidMeta("count \(count) exceeds image capacity \(W)x\(H)")
		}
		
		// Pixel index == gaussian index (row-major, same layout for all per-gaussian images).
		var positions = [SIMD3<Float>](); positions.reserveCapacity(count)
		var rotations = [SIMD4<Float>](); rotations.reserveCapacity(count)
		var scales = [SIMD3<Float>](); scales.reserveCapacity(count)
		var colors = [SIMD3<Float>](); colors.reserveCapacity(count)
		var opacities = [Float](); opacities.reserveCapacity(count)
		
		// ---- Positions (§3.1) ----
		let mins = meta.means.mins, maxs = meta.means.maxs
		@inline(__always) func unlog(_ n: Double) -> Double {
			(n < 0 ? -1.0 : (n > 0 ? 1.0 : 0.0)) * (exp(abs(n)) - 1.0)
		}
		for i in 0..<count {
			let o = i * 4
			var p = SIMD3<Float>(repeating: 0)
			for axis in 0..<3 {
				let q = (Int(meansU.pixels[o + axis]) << 8) | Int(meansL.pixels[o + axis])
				let n = mins[axis] + (maxs[axis] - mins[axis]) * (Double(q) / 65535.0)
				p[axis] = Float(unlog(n))
			}
			positions.append(p)
		}
		
		// ---- Orientation (§3.2) ----
		let quatScale = Float(2).squareRoot()      // (c/255 - 0.5) * 2 / sqrt(2) == (c/255 - 0.5) * sqrt(2)
		@inline(__always) func toComp(_ c: UInt8) -> Float { (Float(c) / 255 - 0.5) * quatScale }
		for i in 0..<count {
			let o = i * 4
			let modeByte = quatsImg.pixels[o + 3]
			guard (252...255).contains(modeByte) else {
				throw SOGError.invalidQuaternionMode(index: i, value: modeByte)
			}
			let a = toComp(quatsImg.pixels[o])
			let b = toComp(quatsImg.pixels[o + 1])
			let c = toComp(quatsImg.pixels[o + 2])
			let d = max(0, 1 - (a * a + b * b + c * c)).squareRoot()
			// Lanes are [w, x, y, z].
			let q: SIMD4<Float>
			switch modeByte - 252 {
				case 0:  q = SIMD4<Float>(d, a, b, c)
				case 1:  q = SIMD4<Float>(a, d, b, c)
				case 2:  q = SIMD4<Float>(a, b, d, c)
				default: q = SIMD4<Float>(a, b, c, d)
			}
			rotations.append(q)
		}
		
		// ---- Scales (§3.3) ----
		let expScales: [Float] = meta.scales.codebook.map { Float(exp(Double($0))) }
		for i in 0..<count {
			let o = i * 4
			scales.append(SIMD3<Float>(expScales[Int(scalesImg.pixels[o])],
									   expScales[Int(scalesImg.pixels[o + 1])],
									   expScales[Int(scalesImg.pixels[o + 2])]))
		}
		
		// ---- Colour + opacity (§3.4) ----
		let shC0: Float = 0.28209479177387814
		let dc = meta.sh0.codebook
		for i in 0..<count {
			let o = i * 4
			colors.append(SIMD3<Float>(0.5 + dc[Int(sh0Img.pixels[o])] * shC0,
									   0.5 + dc[Int(sh0Img.pixels[o + 1])] * shC0,
									   0.5 + dc[Int(sh0Img.pixels[o + 2])] * shC0))
			opacities.append(Float(sh0Img.pixels[o + 3]) / 255)
		}
		
		// ---- Higher-order SH (§3.5, optional) ----
		var sh: SOGSphericalHarmonics? = nil
		if let shN = meta.shN {
			guard shN.files.count == 2 else { throw SOGError.invalidMeta("shN.files must have 2 entries") }
			guard (1...3).contains(shN.bands) else { throw SOGError.invalidMeta("shN.bands must be 1...3") }
			guard (1...65_536).contains(shN.count) else { throw SOGError.invalidMeta("shN.count must be 1...65536") }
			guard shN.codebook.count >= 256 else { throw SOGError.invalidMeta("shN.codebook must have 256 entries") }
			
			let centroids = try load(shN.files[0])
			let labelsImg = try load(shN.files[1])
			guard labelsImg.width == W, labelsImg.height == H else {
				throw SOGError.dimensionMismatch("\(shN.files[1]) is \(labelsImg.width)x\(labelsImg.height), expected \(W)x\(H)")
			}
			
			let coeffs = [3, 8, 15][shN.bands - 1]
			let neededRows = (shN.count + 63) / 64
			guard centroids.width >= 64 * coeffs, centroids.height >= neededRows else {
				throw SOGError.dimensionMismatch("\(shN.files[0]) is \(centroids.width)x\(centroids.height), need at least \(64 * coeffs)x\(neededRows)")
			}
			
			var palette = [Float](repeating: 0, count: shN.count * coeffs * 3)
			for n in 0..<shN.count {
				let v = n / 64
				for c in 0..<coeffs {
					let u = (n % 64) * coeffs + c
					let o = (v * centroids.width + u) * 4
					let base = (n * coeffs + c) * 3
					palette[base]     = shN.codebook[Int(centroids.pixels[o])]
					palette[base + 1] = shN.codebook[Int(centroids.pixels[o + 1])]
					palette[base + 2] = shN.codebook[Int(centroids.pixels[o + 2])]
				}
			}
			
			var labels = [UInt16](); labels.reserveCapacity(count)
			for i in 0..<count {
				let o = i * 4
				let label = Int(labelsImg.pixels[o]) | (Int(labelsImg.pixels[o + 1]) << 8)
				guard label < shN.count else {
					throw SOGError.invalidLabel(index: i, label: label, paletteCount: shN.count)
				}
				labels.append(UInt16(label))
			}
			
			sh = SOGSphericalHarmonics(bands: shN.bands, coefficientsPerChannel: coeffs,
									   paletteCount: shN.count, palette: palette, labels: labels)
		}
		
		return SOGScene(count: count,
						generator: meta.asset?.generator,
						antialias: meta.antialias ?? false,
						positions: positions,
						rotations: rotations,
						scales: scales,
						colors: colors,
						opacities: opacities,
						sh: sh,
						warnings: warnings)
	}
}
