//
//  ContentView.swift
//  RealityKitTest
//
//  Created by Graham Reeves on 17/09/2026.
//
// ✅✅✅ THIS IS THE CORRECT FILE - KEEP THIS ONE AND DELETE THE OTHERS ✅✅✅

import SwiftUI
import RealityKit
import UniformTypeIdentifiers

struct ContentView: View {
	var body: some View {
		CubeSceneView()
	}
}

#Preview {
	ContentView()
}

enum CameraMode: String, CaseIterable, Identifiable {
	case perspective = "Perspective"
	case orthographic = "Isometric"
	var id: Self { self }
}

struct CubeSceneView: View {
	// Camera state
	@State private var azimuth: Float = .pi / 4      // horizontal angle
	@State private var elevation: Float = .pi / 6     // vertical angle
	@State private var distance: Float = 6
	@State private var cameraMode: CameraMode = .perspective

	// Entities we need to update each frame
	@State private var cameraEntity = Entity()
	@State private var rootEntity: AnchorEntity? = nil
	@State private var splatEntity: Entity? = nil

	// Scroll-wheel event monitor for zooming
	@State private var scrollMonitor: Any? = nil
	
	// Gaussian splat URL
	@State private var splatURL: URL? = Bundle.main.url(forResource: "lego_60k", withExtension: "ply")
	@State private var isLoadingSplat = false
	@State private var loadingFileName: String = ""
	@State private var dragActive = false
	@State private var errorMessage: String?
	@State private var showError = false
	
	var body: some View {
		RealityView { content in
			// Root anchor (world content, no AR tracking needed)
			let root = AnchorEntity(world: .zero)
			content.add(root)
			rootEntity = root
			
			// Lighting
			let light = DirectionalLight()
			light.light.intensity = 3000
			light.orientation = simd_quatf(angle: -.pi / 3, axis: [1, 0, 0])
			root.addChild(light)
			
			// A few cubes
			let colors: [NSColor] = [.systemRed, .systemBlue, .systemGreen]
			for (i, color) in colors.enumerated() {
				let mesh = MeshResource.generateBox(size: 0.5)
				let material = SimpleMaterial(color: color, isMetallic: false)
				let cube = ModelEntity(mesh: mesh, materials: [material])
				cube.position = [Float(i) * 1.0 - 1.0, 0, 0]
				root.addChild(cube)
			}
			
			// Custom Metal shader example: geometry + per-vertex data
			// supplied from [Float] arrays (see BufferShaderExample.swift)
			do {
				let shaderEntity = try BufferShaderExample.makeEntity()
				shaderEntity.position = [0, 1.2, -1.5]
				root.addChild(shaderEntity)
			} catch {
				print("Failed to create buffer shader example: \(error)")
			}
			
			// Gaussian Splat from PLY file
			if let plyURL = splatURL {
				print("ContentView: found PLY in bundle at \(plyURL.path)")
				Task {
					await loadAndDisplaySplat(from: plyURL)
				}
			} else {
				print("ContentView: lego_60k.ply NOT found in app bundle - check Target Membership / Copy Bundle Resources")
			}
			
			// Camera
			applyCameraMode()
			root.addChild(cameraEntity)
			updateCameraTransform()
		}
		.overlay(alignment: .topTrailing) {
			Picker("Camera", selection: $cameraMode) {
				ForEach(CameraMode.allCases) { mode in
					Text(mode.rawValue).tag(mode)
				}
			}
			.pickerStyle(.segmented)
			.labelsHidden()
			.fixedSize()
			.padding(12)
		}
		.overlay(alignment: .center) {
			if isLoadingSplat {
				VStack(spacing: 12) {
					ProgressView()
						.scaleEffect(1.5)
					Text("Loading...")
						.font(.headline)
					if !loadingFileName.isEmpty {
						Text(loadingFileName)
							.font(.caption)
							.foregroundStyle(.secondary)
					}
				}
				.padding(24)
				.background(.regularMaterial)
				.cornerRadius(12)
			}
		}
		.overlay(alignment: .center) {
			if dragActive {
				VStack(spacing: 16) {
					Image(systemName: "arrow.down.circle.fill")
						.font(.system(size: 64))
						.foregroundStyle(.tint)
					Text("Drop PLY or SOG file")
						.font(.title2)
						.fontWeight(.semibold)
				}
				.frame(maxWidth: .infinity, maxHeight: .infinity)
				.background(.regularMaterial.opacity(0.9))
			}
		}
		.onChange(of: cameraMode) {
			applyCameraMode()
		}
		.gesture(
			DragGesture()
				.onChanged { value in
					azimuth -= Float(value.translation.width) * 0.0005
					elevation += Float(value.translation.height) * 0.0005
					elevation = max(-.pi/2 + 0.01, min(.pi/2 - 0.01, elevation))
					updateCameraTransform()
				}
		)
		.gesture(
			MagnificationGesture()
				.onChanged { value in
					distance = max(1.5, min(20, distance / Float(value)))
					updateCameraTransform()
				}
		)
		.onDrop(of: [.fileURL], isTargeted: $dragActive) { providers in
			handleDrop(providers: providers)
		}
		.alert("Error Loading Splat", isPresented: $showError) {
			Button("OK") {
				showError = false
			}
		} message: {
			if let errorMessage = errorMessage {
				Text(errorMessage)
			}
		}
		.onAppear {
			// SwiftUI has no scroll-wheel gesture, so listen for the AppKit event directly
			scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { event in
				// Line-based mouse wheels report much smaller deltas than precise trackpads
				let sensitivity: Float = event.hasPreciseScrollingDeltas ? 0.01 : 0.1
				// Exponential zoom so the speed feels the same near and far
				let factor = exp(-Float(event.scrollingDeltaY) * sensitivity)
				distance = max(1.5, min(20, distance * factor))
				updateCameraTransform()
				return event
			}
		}
		.onDisappear {
			if let scrollMonitor {
				NSEvent.removeMonitor(scrollMonitor)
			}
			scrollMonitor = nil
		}
	}
	
	/// Swap the camera component to match the selected mode
	private func applyCameraMode() {
		switch cameraMode {
		case .perspective:
			cameraEntity.components.remove(OrthographicCameraComponent.self)
			var camera = PerspectiveCameraComponent()
			camera.fieldOfViewInDegrees = 50
			cameraEntity.components.set(camera)
		case .orthographic:
			cameraEntity.components.remove(PerspectiveCameraComponent.self)
			var camera = OrthographicCameraComponent()
			camera.scale = orthographicScale
			cameraEntity.components.set(camera)
		}
		updateCameraTransform()
	}

	/// View-volume height that matches what the 50-degree perspective camera
	/// sees at the orbit target, so switching modes keeps a similar framing
	private var orthographicScale: Float {
		2 * distance * tan(50 / 2 * .pi / 180)
	}

	private func updateCameraTransform() {
		let x = distance * cos(elevation) * sin(azimuth)
		let y = distance * sin(elevation)
		let z = distance * cos(elevation) * cos(azimuth)
		let position = SIMD3<Float>(x, y, z)

		cameraEntity.position = position
		cameraEntity.look(at: .zero, from: position, relativeTo: nil)

		// An orthographic camera zooms via its view-volume scale, not distance
		if var orthographic = cameraEntity.components[OrthographicCameraComponent.self] {
			orthographic.scale = orthographicScale
			cameraEntity.components.set(orthographic)
		}
	}
	
	/// Load a Gaussian Splat from a PLY or SOG file URL
	private func loadGaussianSplat(from url: URL) async throws -> Entity
	{
		// RealityKit has no PLY/SOG importer, so parse the file
		// and build a GaussianSplatComponent from its data
		return try await GaussianSplatLoader.loadEntity(from: url)
	}
	
	/// Load and display a splat, replacing any existing one
	@MainActor
	private func loadAndDisplaySplat(from url: URL) async {
		isLoadingSplat = true
		loadingFileName = url.lastPathComponent
		defer { 
			isLoadingSplat = false
			loadingFileName = ""
		}
		
		// Remove existing splat if any
		if let existingSplat = splatEntity {
			existingSplat.removeFromParent()
			splatEntity = nil
		}
		
		do {
			let newSplat = try await loadGaussianSplat(from: url)
			// Position it in the center, slightly above the cubes
			newSplat.position = [0, 0.8, 0]
			newSplat.scale = [0.5, 0.5, 0.5] // Scale down if needed
			
			if let root = rootEntity {
				root.addChild(newSplat)
				splatEntity = newSplat
				print("ContentView: splat entity added to scene at \(newSplat.position), scale \(newSplat.scale)")
			}
		} catch {
			print("Failed to load Gaussian Splat: \(error)")
			errorMessage = error.localizedDescription
			showError = true
		}
	}
	
	/// Handle dropped files
	private func handleDrop(providers: [NSItemProvider]) -> Bool {
		guard let provider = providers.first else { return false }
		
		provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, error in
			guard let data = item as? Data,
				  let url = URL(dataRepresentation: data, relativeTo: nil) else {
				if let error = error {
					print("ContentView: drop error: \(error)")
				}
				return
			}
			
			let fileExtension = url.pathExtension.lowercased()
			guard fileExtension == "ply" || fileExtension == "sog" else {
				print("ContentView: dropped file is not a .ply or .sog file")
				return
			}
			
			print("ContentView: dropped file: \(url.lastPathComponent)")
			
			Task { @MainActor in
				await loadAndDisplaySplat(from: url)
			}
		}
		
		return true
	}
}
