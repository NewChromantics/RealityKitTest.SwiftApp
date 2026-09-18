//
//  BufferShaders.metal
//  RealityKitTest
//
//  Custom Metal shader functions for a RealityKit CustomMaterial.
//  Per-vertex data supplied from a Swift [Float] array is delivered
//  through the mesh's UV1 channel:
//    uv1.x = scale factor  (used by the geometry modifier / vertex stage)
//    uv1.y = colour value  (used by the surface shader / pixel stage)
//

#include <metal_stdlib>
#include <RealityKit/RealityKit.h>

using namespace metal;

// Vertex stage: runs once per vertex. Scales the model about its origin
// by the per-vertex factor stored in uv1.x.
[[visible]]
void bufferExampleGeometryModifier(realitykit::geometry_parameters params)
{
	float scale = params.geometry().uv1().x;
	float3 modelPosition = params.geometry().model_position();

	// Offsetting by position * (scale - 1) is equivalent to position * scale
	params.geometry().set_model_position_offset(modelPosition * (scale - 1.0));
}

// Pixel stage: runs once per fragment. Colours the surface from the
// interpolated per-vertex value stored in uv1.y.
[[visible]]
void bufferExampleSurfaceShader(realitykit::surface_parameters params)
{
	float colorValue = params.geometry().uv1().y;

	half3 cold = half3(0.1, 0.35, 1.0);   // blue where the value is 0
	half3 hot  = half3(1.0, 0.45, 0.05);  // orange where the value is 1
	half3 baseColor = mix(cold, hot, half(saturate(colorValue)));

	params.surface().set_base_color(baseColor);
	params.surface().set_roughness(0.6h);
	params.surface().set_metallic(0.0h);
}
