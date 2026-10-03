import SwiftUI
import SplatScene
import UniformTypeIdentifiers

struct ContentView: View 
{
	@State private var splatUrl : URL = Bundle.main.url(forResource: "lego_60k", withExtension: "ply")!
	//@State private var splatURL: URL? = Bundle.main.url(forResource: "Jonathan-Dollhouse", withExtension: "sog")

	@State var scene = Scene(actors: [:])
	
	@State var dragActive = false
	var dragBackground : Color		{	dragActive ? Color("SceneBackgroundDroppingColour") : Color("SceneBackgroundColour")	}

	var body: some View 
	{
		SplatSceneView(scene: scene, splatUrl: splatUrl, backgroundColour:dragBackground)
			.onDrop(of: [.fileURL], isTargeted: $dragActive) 
			{
				providers in
				handleDrop(providers: providers)
			}
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
			
			let fileExtension = url.pathExtension.lowercased()
			guard fileExtension == "sog" else {
				return
			}
			
			Task 
			{
				@MainActor in
				//loadSOG(from: url)
				splatUrl = url
			}
		}
		
		return true
	}
}

#Preview 
{
	ContentView()
}
