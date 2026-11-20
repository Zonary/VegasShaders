// CombineDepth's merged pass as a Vulkan pass (needs NVR DXVK): Effects/CombineDepth.fx.hlsl technique DepthNormals, line for line.
// Two targets: 0 the combined depth (R32F or G32R32F, as CombineDepth), 1 the normals (A16B16G16R16F, as Normals). Normals.glsl has
// the normal maths. effects/CombineDepth.cpp ExtDepthNormals (MergedDepthNormals, off by default).
#version 450
#extension GL_GOOGLE_include_directive : enable
#include "Common.glsl"
#include "Normals.glsl"

layout(set = 1, binding = 0) uniform texture2D t_worldDepth;      // TESR_DepthBufferWorld (POINT, CLAMP)
layout(set = 1, binding = 1) uniform texture2D t_viewModelDepth;  // TESR_DepthBufferViewModel (POINT, CLAMP)

layout(push_constant) uniform Push {
    vec4 reciprocalResolution;  // 0: TESR_ReciprocalResolution
    vec4 cameraData;            // 16: TESR_CameraData (x near Z, y far Z)
    vec4 depthConstants;        // 32: TESR_DepthConstants (x view model near Z)
    mat4 invProjection;         // 48: TESR_InvProjectionTransform
    uint samplerIndex;          // 112: POINT, CLAMP
    uint pad[3];                // 116
    vec4 renderScale;           // 128: (scaleX, scaleY, 1/scaleX, 1/scaleY) (UNOFFICIAL 2026-11-19 RenderRect)
} pc;

layout(location = 0) in vec2 uv;
layout(location = 0) out vec4 o_depth;
layout(location = 1) out vec4 o_normal;

// Convert depth to view space Z.
float toVS(float depth, float nearZ, float farZ) {
    return nearZ * farZ / (nearZ + depth * (farZ - nearZ));
}

// Convert view space Z to depth.
float toPS(float viewZ, float nearZ, float farZ) {
    return nearZ * (farZ - viewZ) / (viewZ * (farZ - nearZ));
}

// CombineDepth.fx.hlsl's CombinedDepthAt: (linear01, post-projection depth) of the combined depth at a point.
vec2 combinedDepthAt(vec2 p) {
    float nearZ = pc.cameraData.x;
    float farZ = pc.cameraData.y;
    float worldDepth = texture(sampler2D(t_worldDepth, NVR_SAMPLER(pc.samplerIndex)), p).x;
    float viewModelDepth = texture(sampler2D(t_viewModelDepth, NVR_SAMPLER(pc.samplerIndex)), p).x;
    float combinedViewZ = toVS(worldDepth, nearZ, farZ);
    if (viewModelDepth > 0.0)
        combinedViewZ = toVS(viewModelDepth, pc.depthConstants.x, farZ);
    return vec2(combinedViewZ / farZ, toPS(combinedViewZ, nearZ, farZ));
}

void main() {
    vec2 texel = pc.reciprocalResolution.xy;
    float farZ = pc.cameraData.y;
    vec2 scale = pc.renderScale.x > 0.0 ? pc.renderScale.xy : vec2(1.0);
    vec2 invScale = pc.renderScale.z > 0.0 ? pc.renderScale.zw : vec2(1.0);
    vec2 ruv = uv * scale;
    vec2 lo = 0.5 * texel;
    vec2 hi = scale - 0.5 * texel;

    vec2 centerDepth = combinedDepthAt(clamp(ruv, lo, hi));
    vec3 viewNormal = viewNormalFromTaps(uv, texel * invScale, pc.invProjection, farZ,
        centerDepth,
        combinedDepthAt(clamp(ruv + vec2(1.0, 0.0) * texel, lo, hi)), combinedDepthAt(clamp(ruv + vec2(2.0, 0.0) * texel, lo, hi)),
        combinedDepthAt(clamp(ruv + vec2(-1.0, 0.0) * texel, lo, hi)), combinedDepthAt(clamp(ruv + vec2(-2.0, 0.0) * texel, lo, hi)),
        combinedDepthAt(clamp(ruv + vec2(0.0, -1.0) * texel, lo, hi)), combinedDepthAt(clamp(ruv + vec2(0.0, -2.0) * texel, lo, hi)),
        combinedDepthAt(clamp(ruv + vec2(0.0, 1.0) * texel, lo, hi)), combinedDepthAt(clamp(ruv + vec2(0.0, 2.0) * texel, lo, hi)));

    o_depth = vec4(centerDepth.x, centerDepth.y, 1.0, 1.0);
    o_normal = vec4(viewNormal * 0.5 + 0.5, 1.0);
}
