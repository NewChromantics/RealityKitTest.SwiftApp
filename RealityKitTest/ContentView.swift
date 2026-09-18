//
//  ContentView.swift
//  RealityKitTest
//
//  Created by Graham Reeves on 17/09/2026.
//
// ✅✅✅ THIS IS THE CORRECT FILE - KEEP THIS ONE AND DELETE THE OTHERS ✅✅✅

import SwiftUI
import RealityKit

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

	// Scroll-wheel event monitor for zooming
	@State private var scrollMonitor: Any? = nil
	
	// Gaussian splat URL
	@State private var splatURL: URL? = Bundle.main.url(forResource: "lego_60k", withExtension: "ply")
	
	var body: some View {
		RealityView { content in
			// Root anchor (world content, no AR tracking needed)
			let root = AnchorEntity(world: .zero)
			content.add(root)
			
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
			
			// Gaussian Splat from PLY file
			if let plyURL = splatURL {
				print("ContentView: found PLY in bundle at \(plyURL.path)")
				Task {
					if let splatEntity = await loadGaussianSplat(from: plyURL) {
						// Position it in the center, slightly above the cubes
						splatEntity.position = [0, 0.8, 0]
						splatEntity.scale = [0.5, 0.5, 0.5] // Scale down if needed
						root.addChild(splatEntity)
						print("ContentView: splat entity added to scene at \(splatEntity.position), scale \(splatEntity.scale)")
					} else {
						print("ContentView: loadGaussianSplat returned nil")
					}
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
	
	/// Load a Gaussian Splat from a PLY file URL
	private func loadGaussianSplat(from url: URL) async -> Entity?
	{
		do {
			// RealityKit has no PLY importer, so parse the file with PopPly
			// and build a GaussianSplatComponent from its data
			return try await GaussianSplatLoader.loadEntity(from: url)
		} catch {
			print("Failed to load Gaussian Splat: \(error)")
			return nil
		}
	}
}
