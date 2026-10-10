import SwiftUI
import SplatScene
import UniformTypeIdentifiers
import simd
internal import PopCommon

let legoSplatUrl = Bundle.main.url(forResource: "lego_60k", withExtension: "ply")!

struct ContentView: View 
{
	@State var renderStats = RenderStats()
	@State var droppingFile = false
	@State var scene = Self.InitialScene()
	
	var body: some View 
	{
		SplatSceneView(scene: scene, renderStats: $renderStats)
			.background(Color("SceneBackgroundColour"))
			.onDrop(of: [.fileURL], isTargeted: $droppingFile)
			{
				providers in
				handleDrop(providers: providers)
			}
			.overlay(alignment: .topLeading)
			{
				RenderStatsView(renderStats:renderStats)
			}
			.overlay(alignment: .center) 
			{
				if droppingFile 
				{
					DroppingOverlay()
				}
			}
	}
	
	static func InitialScene() -> SplatScene.Scene
	{
		let actors = [
			SceneActorUid() : SceneActor(position: .zero, assetUrl: legoSplatUrl)
		]
		return Scene(actors:actors)
	}
	
	@ViewBuilder func DroppingOverlay() -> some View
	{
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
	
	private func handleDrop(providers: [NSItemProvider]) -> Bool
	{
		guard let provider = providers.first else { return false }
		
		//	returns cancellable Progress
		_ = provider.loadObject(ofClass: URL.self) 
		{
			object, error in
			guard let url = object else 
			{
				return
			}
			
			//	drop a new actor
			let x = Float(scene.actors.count) * 2.0
			let pos = simd_float3(x,0,0)
			let newActor = SceneActor(position: pos, assetUrl: url)
			scene.actors[SceneActorUid()] = newActor
		}
		
		return true
	}
	
}

#Preview 
{
	ContentView()
}
