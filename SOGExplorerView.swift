//
//  SOGExplorerView.swift
//  RealityKitTest
//
//  SOG Explorer - A tool to validate and inspect SOG files
//

import SwiftUI
import UniformTypeIdentifiers
import simd

struct SOGExplorerView: View {
	@State private var sogData: SOGSplatData?
	@State private var errorMessage: String?
	@State private var isLoading = false
	@State private var dragActive = false
	
	var body: some View {
		VStack(spacing: 0) {
			// Header
			HStack {
				Text("SOG Explorer")
					.font(.title)
					.fontWeight(.bold)
				Spacer()
			}
			.padding()
			.background(.regularMaterial)
			
			// Content
			if let data = sogData {
				SOGDataView(data: data)
			} else if let error = errorMessage {
				// Error View
				VStack(spacing: 16) {
					Image(systemName: "exclamationmark.triangle.fill")
						.font(.system(size: 48))
						.foregroundStyle(.red)
					Text("Error Loading SOG")
						.font(.title2)
						.fontWeight(.semibold)
					Text(error)
						.font(.body)
						.foregroundStyle(.secondary)
						.multilineTextAlignment(.center)
						.padding(.horizontal)
					Button("Try Again") {
						errorMessage = nil
					}
					.buttonStyle(.borderedProminent)
				}
				.frame(maxWidth: .infinity, maxHeight: .infinity)
			} else {
				// Drop Zone
				VStack(spacing: 24) {
					if isLoading {
						ProgressView()
							.scaleEffect(2)
						Text("Loading SOG file...")
							.font(.title3)
							.foregroundStyle(.secondary)
					} else {
						Image(systemName: "doc.viewfinder")
							.font(.system(size: 72))
							.foregroundStyle(.secondary)
						Text("Drop a .sog file here")
							.font(.title2)
							.fontWeight(.semibold)
						Text("or click to select")
							.font(.body)
							.foregroundStyle(.secondary)
					}
				}
				.frame(maxWidth: .infinity, maxHeight: .infinity)
				.background(dragActive ? Color.accentColor.opacity(0.1) : Color.clear)
				.contentShape(Rectangle())
				.onTapGesture {
					selectFile()
				}
			}
		}
		.onDrop(of: [.fileURL], isTargeted: $dragActive) { providers in
			handleDrop(providers: providers)
		}
	}
	
	private func selectFile() {
		let panel = NSOpenPanel()
		panel.allowedContentTypes = [UTType(filenameExtension: "sog")!]
		panel.allowsMultipleSelection = false
		panel.canChooseDirectories = false
		panel.canChooseFiles = true
		
		if panel.runModal() == .OK, let url = panel.url {
			loadSOG(from: url)
		}
	}
	
	private func handleDrop(providers: [NSItemProvider]) -> Bool {
		guard let provider = providers.first else { return false }
		
		provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, error in
			guard let data = item as? Data,
				  let url = URL(dataRepresentation: data, relativeTo: nil) else {
				return
			}
			
			let fileExtension = url.pathExtension.lowercased()
			guard fileExtension == "sog" else {
				return
			}
			
			Task { @MainActor in
				loadSOG(from: url)
			}
		}
		
		return true
	}
	
	private func loadSOG(from url: URL) {
		isLoading = true
		errorMessage = nil
		sogData = nil
		
		Task {
			do {
				let data = try await Task.detached(priority: .userInitiated) {
					try SOGWebPParser.parse(url: url)
				}.value
				
				await MainActor.run {
					sogData = data
					isLoading = false
				}
			} catch {
				await MainActor.run {
					errorMessage = error.localizedDescription
					isLoading = false
				}
			}
		}
	}
}

// MARK: - Data Display View

struct SOGDataView: View {
	let data: SOGSplatData
	
	@State private var selectedTab = 0
	
	var body: some View {
		VStack(spacing: 0) {
			// Info Bar
			HStack {
				InfoItem(label: "Count", value: "\(data.count)")
				Divider()
				InfoItem(label: "Version", value: "\(data.metadata.version)")
				Divider()
				InfoItem(label: "Generator", value: data.metadata.asset.generator)
				Spacer()
			}
			.padding()
			.background(.regularMaterial)
			
			// Tabs
			TabView(selection: $selectedTab) {
				MetadataTabView(data: data)
					.tabItem { Label("Metadata", systemImage: "info.circle") }
					.tag(0)
				
				BoundsTabView(data: data)
					.tabItem { Label("Bounds", systemImage: "cube") }
					.tag(1)
				
				SampleDataTabView(data: data)
					.tabItem { Label("Sample Data", systemImage: "eye") }
					.tag(2)
				
				StatisticsTabView(data: data)
					.tabItem { Label("Statistics", systemImage: "chart.bar") }
					.tag(3)
			}
		}
	}
}

struct InfoItem: View {
	let label: String
	let value: String
	
	var body: some View {
		VStack(alignment: .leading, spacing: 4) {
			Text(label)
				.font(.caption)
				.foregroundStyle(.secondary)
			Text(value)
				.font(.body)
				.fontWeight(.medium)
		}
		.padding(.horizontal, 8)
	}
}

// MARK: - Tab Views

struct MetadataTabView: View {
	let data: SOGSplatData
	
	var body: some View {
		Form {
			Section("General") {
				LabeledContent("Splat Count", value: "\(data.count)")
				LabeledContent("Version", value: "\(data.metadata.version)")
				LabeledContent("Generator", value: data.metadata.asset.generator)
			}
			
			Section("Data Files") {
				LabeledContent("Position Files", value: data.metadata.means.files.joined(separator: ", "))
				LabeledContent("Scale Files", value: data.metadata.scales.files.joined(separator: ", "))
				LabeledContent("Quaternion Files", value: data.metadata.quats.files.joined(separator: ", "))
				LabeledContent("SH0 Files", value: data.metadata.sh0.files.joined(separator: ", "))
				if let shN = data.metadata.shN {
					LabeledContent("SHN Files", value: shN.files.joined(separator: ", "))
					LabeledContent("SHN Bands", value: "\(shN.bands)")
				}
			}
			
			Section("Codebooks") {
				LabeledContent("Scale Codebook Size", value: "\(data.metadata.scales.codebook.count)")
				LabeledContent("SH0 Codebook Size", value: "\(data.metadata.sh0.codebook.count)")
				if let shN = data.metadata.shN {
					LabeledContent("SHN Codebook Size", value: "\(shN.codebook.count)")
				}
			}
		}
		.formStyle(.grouped)
	}
}

struct BoundsTabView: View {
	let data: SOGSplatData
	
	var body: some View {
		Form {
			Section("Position Bounds (from metadata)") {
				LabeledContent("Min X", value: String(format: "%.4f", data.metadata.means.mins[0]))
				LabeledContent("Min Y", value: String(format: "%.4f", data.metadata.means.mins[1]))
				LabeledContent("Min Z", value: String(format: "%.4f", data.metadata.means.mins[2]))
				LabeledContent("Max X", value: String(format: "%.4f", data.metadata.means.maxs[0]))
				LabeledContent("Max Y", value: String(format: "%.4f", data.metadata.means.maxs[1]))
				LabeledContent("Max Z", value: String(format: "%.4f", data.metadata.means.maxs[2]))
			}
			
			Section("Calculated Bounds") {
				let bounds = calculateBounds(data.positions)
				LabeledContent("Min", value: String(format: "(%.3f, %.3f, %.3f)", bounds.min.x, bounds.min.y, bounds.min.z))
				LabeledContent("Max", value: String(format: "(%.3f, %.3f, %.3f)", bounds.max.x, bounds.max.y, bounds.max.z))
				LabeledContent("Size", value: String(format: "(%.3f, %.3f, %.3f)", 
					bounds.max.x - bounds.min.x,
					bounds.max.y - bounds.min.y,
					bounds.max.z - bounds.min.z))
			}
		}
		.formStyle(.grouped)
	}
	
	private func calculateBounds(_ positions: [SIMD3<Float>]) -> (min: SIMD3<Float>, max: SIMD3<Float>) {
		var min = SIMD3<Float>(repeating: .greatestFiniteMagnitude)
		var max = SIMD3<Float>(repeating: -.greatestFiniteMagnitude)
		
		for pos in positions {
			min = simd_min(min, pos)
			max = simd_max(max, pos)
		}
		
		return (min, max)
	}
}

struct SampleDataTabView: View {
	let data: SOGSplatData
	
	var body: some View {
		ScrollView {
			VStack(alignment: .leading, spacing: 16) {
				Text("First 10 Splats")
					.font(.headline)
					.padding(.horizontal)
					.padding(.top)
				
				ForEach(0..<min(10, data.count), id: \.self) { i in
					SplatSampleView(index: i, data: data)
				}
			}
		}
	}
}

struct SplatSampleView: View {
	let index: Int
	let data: SOGSplatData
	
	var body: some View {
		GroupBox("Splat \(index)") {
			VStack(alignment: .leading, spacing: 8) {
				HStack {
					Text("Position:")
						.fontWeight(.medium)
					Spacer()
					Text(formatVector(data.positions[index]))
						.font(.system(.body, design: .monospaced))
				}
				
				HStack {
					Text("Scale:")
						.fontWeight(.medium)
					Spacer()
					Text(formatVector(data.scales[index]))
						.font(.system(.body, design: .monospaced))
				}
				
				HStack {
					Text("Rotation:")
						.fontWeight(.medium)
					Spacer()
					Text(formatQuat(data.rotations[index]))
						.font(.system(.body, design: .monospaced))
				}
				
				HStack {
					Text("SH0 Color:")
						.fontWeight(.medium)
					Spacer()
					Text(formatVector(data.sh0Colors[index]))
						.font(.system(.body, design: .monospaced))
				}
			}
			.padding(8)
		}
		.padding(.horizontal)
	}
	
	private func formatVector(_ v: SIMD3<Float>) -> String {
		String(format: "(%.3f, %.3f, %.3f)", v.x, v.y, v.z)
	}
	
	private func formatQuat(_ q: simd_quatf) -> String {
		String(format: "(%.3f, %.3f, %.3f, %.3f)", q.real, q.imag.x, q.imag.y, q.imag.z)
	}
}

struct StatisticsTabView: View {
	let data: SOGSplatData
	
	var body: some View {
		Form {
			Section("Scale Statistics") {
				let scaleStats = calculateStats(data.scales.map { $0.x })
				LabeledContent("Min", value: String(format: "%.4f", scaleStats.min))
				LabeledContent("Max", value: String(format: "%.4f", scaleStats.max))
				LabeledContent("Mean", value: String(format: "%.4f", scaleStats.mean))
			}
			
			Section("Color Statistics (SH0)") {
				let colorStats = calculateStats(data.sh0Colors.map { ($0.x + $0.y + $0.z) / 3.0 })
				LabeledContent("Min", value: String(format: "%.4f", colorStats.min))
				LabeledContent("Max", value: String(format: "%.4f", colorStats.max))
				LabeledContent("Mean", value: String(format: "%.4f", colorStats.mean))
			}
			
			Section("Memory") {
				let positionBytes = data.positions.count * MemoryLayout<SIMD3<Float>>.size
				let scaleBytes = data.scales.count * MemoryLayout<SIMD3<Float>>.size
				let rotationBytes = data.rotations.count * MemoryLayout<simd_quatf>.size
				let colorBytes = data.sh0Colors.count * MemoryLayout<SIMD3<Float>>.size
				let total = positionBytes + scaleBytes + rotationBytes + colorBytes
				
				LabeledContent("Positions", value: formatBytes(positionBytes))
				LabeledContent("Scales", value: formatBytes(scaleBytes))
				LabeledContent("Rotations", value: formatBytes(rotationBytes))
				LabeledContent("Colors", value: formatBytes(colorBytes))
				LabeledContent("Total", value: formatBytes(total))
			}
		}
		.formStyle(.grouped)
	}
	
	private func calculateStats(_ values: [Float]) -> (min: Float, max: Float, mean: Float) {
		guard !values.isEmpty else { return (0, 0, 0) }
		let min = values.min() ?? 0
		let max = values.max() ?? 0
		let mean = values.reduce(0, +) / Float(values.count)
		return (min, max, mean)
	}
	
	private func formatBytes(_ bytes: Int) -> String {
		ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .memory)
	}
}

#Preview {
	SOGExplorerView()
		.frame(width: 800, height: 600)
}
