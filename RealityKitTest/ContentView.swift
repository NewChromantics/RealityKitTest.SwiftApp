import SwiftUI
import SplatScene
import UniformTypeIdentifiers
import simd

let legoSplatUrl = Bundle.main.url(forResource: "lego_60k", withExtension: "ply")!

struct ContentView: View 
{
	@State var droppingFile = false
	@State var scene = Scene(actors:
								[SceneActorUid():SceneActor(position: .zero, assetUrl: legoSplatUrl)]
	)
	
	var body: some View 
	{
		SplatSceneView(scene: scene)
			.background(Color("SceneBackgroundColour"))
			.onDrop(of: [.fileURL], isTargeted: $droppingFile)
			{
				providers in
				handleDrop(providers: providers)
			}
			.overlay(alignment: .center) 
			{
				if droppingFile 
				{
					DroppingOverlay()
				}
			}
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
		
		provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil)
		{
			item, error in
			guard let data = item as? Data,
				  let url = URL(dataRepresentation: data, relativeTo: nil) else 
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
