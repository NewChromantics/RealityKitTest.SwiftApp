//
//  RealityKitTestApp.swift
//  RealityKitTest
//
//  Created by Graham Reeves on 17/09/2026.
//

import SwiftUI

@main
struct RealityKitTestApp: App {
    var body: some Scene {
        WindowGroup("RealityKit Viewer") {
            ContentView()
        }
		
		WindowGroup("SOG Explorer") {
			SOGExplorerView()
		}
		.defaultSize(width: 900, height: 700)
    }
}
