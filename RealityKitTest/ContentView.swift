import SwiftUI
import SplatScene
import simd
import PopPly
import PopSog
internal import UniformTypeIdentifiers

let legoSplatUrl = Bundle.main.url(forResource: "lego_60k", withExtension: "ply")!
//let legoSplatUrl = URL(fileURLWithPath: "/Users/graham/Downloads/export.ply")




struct AppToolbarView : View 
{
	var OnClickedImport : ()->Void
	
	var body: some View 
	{
		HStack(alignment: .center, spacing: 0)
		{
			ImportButton()
			Spacer()
		}
		.controlSize(.small)
		.frame(maxWidth: .infinity)
		.fixedSize(horizontal: false, vertical: true)
		.padding(5)
	}
	
	@ViewBuilder func ImportButton() -> some View
	{
		Button(action:OnClickedImport)
		{
			Label("Load Splat",systemImage: "arrow.down.document.fill")
		}
	}
}





struct ContentView: View 
{
	@State var scene : SplatScene.Scene = InitialScene()
	@State var renderStats = RenderStats()
	@State var assetManager = AssetManager()
	@State var cameraState = CameraState()
	
	@State var openSplatFileDialogVisible : Bool = false
	@State var isDroppingFile = false
	
	var body: some View 
	{
		VStack(spacing: 0)
		{
			AppToolbarView()
			{
				openSplatFileDialogVisible = true
			}
			
			SplatSceneView(scene: scene, renderStats: $renderStats, renderer: .both, assetManager: assetManager, cameraState: $cameraState)
				.background(Color("SceneBackgroundColour"))
				.fileImporter(isPresented: $openSplatFileDialogVisible, allowedContentTypes: [.ply,.sog], onCompletion: OnFileOpened)
				.onDrop(of: [.fileURL], isTargeted: $isDroppingFile)
			{
				providers in
				OnFileDrop(providers: providers)
			}
			.overlay(alignment: .topTrailing)
			{
				OverlayView()
			}
		}
	}
	
	static func InitialScene() -> SplatScene.Scene
	{
		// Put cube back at origin for testing
		let actors = [
			SceneActorUid() : SceneActor(position: .zero, assetUrl: legoSplatUrl)
		]
		return Scene(actors:actors)
	}
	
	func OnFileOpened(result:Result<URL,any Error>)
	{
		switch result
		{
			case .success(let url):
				SetActorAsset(assetUrl: url)
				
			default:
				break
		}
	}
	
	func OnFileDrop(providers: [NSItemProvider]) -> Bool
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
			
			SetActorAsset(assetUrl: url)
		}
		
		return true
	}
		
	
	func SetActorAsset(assetUrl:URL,addActor:Bool=false)
	{
		if addActor
		{
			//	drop a new actor
			let x = Float(scene.actors.count) * 2.0
			let pos = simd_float3(x,0,0)
			let newActor = SceneActor(position: pos, assetUrl: assetUrl)
			scene.actors[SceneActorUid()] = newActor
			return
		}
		
		guard var (firstActorUid,firstActor) = scene.actors.first else
		{
			return
		}
		firstActor.assetUrl = assetUrl
		scene.actors.updateValue(firstActor, forKey: firstActorUid)
	}
	
	@ViewBuilder func OverlayView() -> some View
	{
		VStack
		{
			CameraStateView(cameraState: cameraState)
		}
		.background
		{
			//	react (by changing background) when dropping file
			if isDroppingFile
			{
				Color.black
			}
		}
	}
}

/*

struct ContentView: View 
{
	@State var renderStats = RenderStats()
	@State var droppingFile = false
	@State var scene = Self.InitialScene()
	@State var renderMode = SplatSceneRenderer.metal
	
	var body: some View 
	{
		SplatSceneView(scene: scene, renderStats: $renderStats, renderer:renderMode)
			.background(Color("SceneBackgroundColour"))
			.onDrop(of: [.fileURL], isTargeted: $droppingFile)
			{
				providers in
				handleDrop(providers: providers)
			}
			.overlay(alignment: .topLeading)
			{
				OverlayView()
			}
			//.ignoresSafeArea()
	}
	
	static func InitialScene() -> SplatScene.Scene
	{
		// Put cube back at origin for testing
		let actors = [
			SceneActorUid() : SceneActor(position: .zero, assetUrl: legoSplatUrl)
		]
		return Scene(actors:actors)
	}
	
	@ViewBuilder func OverlayView() -> some View
	{
		VStack(alignment: .leading)
		{
			RenderStatsView(renderStats:renderStats)
			
			VStack
			{
				EnumDropDown(value: $renderMode)
				Button(action:ClearScene)
				{
					Label("Clear Scene",systemImage: "xmark.square.fill")
				}
			}
			.darkBackground()

		}
		.opacity(0.6)
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
	
	
	func ClearScene()
	{
		self.scene.actors = [:]
	}
}
*/
#Preview 
{
	VStack(spacing:0)
	{
		AppToolbarView()
		{
		}
		Color.blue
	}
	.frame(width:300,height:300)
	
	//ContentView()
}
