// Sharpening as a Vulkan pass (needs NVR DXVK): Effects/Sharpening.fx.hlsl (kernelSize 3, falloffExponent 4) line for line.
// effects/Sharpening.cpp ExtRender. readDepth: linear depth / farZ in TESR_DepthBuffer's first channel, times farZ.
#version 450
#extension GL_GOOGLE_include_directive : enable
#include "Common.glsl"

layout(set = 1, binding = 0) uniform texture2D t_rendered;   // TESR_RenderedBuffer
layout(set = 1, binding = 1) uniform texture2D t_depth;      // TESR_DepthBuffer

layout(push_constant) uniform Push {
    vec4 sharpeningData;        // 0: TESR_SharpeningData (x intensity, y clamp, z offset / depth falloff, w 1 = CAS: 2026-11-13)
    vec4 reciprocalResolution;  // 16: TESR_ReciprocalResolution
    vec4 cameraData;            // 32: TESR_CameraData (y farZ)
    uint samplerIndex;          // 48: LINEAR, CLAMP
} pc;

layout(location = 0) in vec2 uv;
layout(location = 0) out vec4 o_color;

const int kernelSize = 3;
const float falloffExponent = 4.0;

float readDepth(vec2 coord) {
    return texture(sampler2D(t_depth, NVR_SAMPLER(pc.samplerIndex)), coord).x * pc.cameraData.y;
}

// UNOFFICIAL 2026-11-13 (ported from a tester fork, default off) [Shaders.Sharpening.Main] CAS: AMD FidelityFX Contrast Adaptive
// Sharpening (the non-scaling filter with CAS_BETTER_DIAGONALS) with the same depth falloff, in place of the filter below (TESR_SharpeningData.w 1).
// Ported from ffx_cas.h (FidelityFX CAS, https://github.com/GPUOpen-Effects/FidelityFX-CAS):
//   Copyright (c) 2017-2019 Advanced Micro Devices, Inc. All rights reserved.
//   Permission is hereby granted, free of charge, to any person obtaining a copy of this software and associated documentation
//   files (the "Software"), to deal in the Software without restriction, including without limitation the rights to use, copy,
//   modify, merge, publish, distribute, sublicense, and/or sell copies of the Software, and to permit persons to whom the Software
//   is furnished to do so, subject to the following conditions:
//   The above copyright notice and this permission notice shall be included in all copies or substantial portions of the Software.
//   THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES
//   OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE
//   LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN
//   CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
// CAS: a 3x3 neighbourhood; the soft minimum and maximum of the cross (b d e f h) and of the full 3x3 give how much headroom the pixel
// has before it would clip ("amp"); the four cross neighbours get a negative weight w = amp * peak, so low-contrast detail is sharpened
// more and strong edges are left nearly alone (no halos). One weight for all three channels (green's, as AMD's default path).
vec3 casTap(vec2 offset) {
    return textureLod(sampler2D(t_rendered, NVR_SAMPLER(pc.samplerIndex)), uv + offset * pc.reciprocalResolution.xy, 0.0).rgb;
}
vec4 casSharpen() {
    vec4 color = textureLod(sampler2D(t_rendered, NVR_SAMPLER(pc.samplerIndex)), uv, 0.0);
    const float maxDepth = pc.sharpeningData.z * 1000.0;
    if (maxDepth <= 0.0) return color;
    const float falloff = pow(saturate((maxDepth - textureLod(sampler2D(t_depth, NVR_SAMPLER(pc.samplerIndex)), uv, 0.0).x * pc.cameraData.y) / maxDepth), falloffExponent);
    if (falloff <= 0.0) return color;
    const vec3 a = casTap(vec2(-1.0, -1.0));
    const vec3 b = casTap(vec2( 0.0, -1.0));
    const vec3 c = casTap(vec2( 1.0, -1.0));
    const vec3 d = casTap(vec2(-1.0,  0.0));
    const vec3 e = color.rgb;
    const vec3 f = casTap(vec2( 1.0,  0.0));
    const vec3 g = casTap(vec2(-1.0,  1.0));
    const vec3 h = casTap(vec2( 0.0,  1.0));
    const vec3 i = casTap(vec2( 1.0,  1.0));
    vec3 mn = min(min(min(d, e), min(f, b)), h);
    vec3 mx = max(max(max(d, e), max(f, b)), h);
    mn += min(min(min(mn, a), min(c, g)), i);
    mx += max(max(max(mx, a), max(c, g)), i);
    const float amp = sqrt(saturate(min(mn.g, 2.0 - mx.g) / max(mx.g, 1.0e-5)));
    const float peak = -1.0 / mix(8.0, 5.0, saturate(pc.sharpeningData.x));
    const float w = amp * peak;
    const vec3 sharpened = saturate(((b + d + f + h) * w + e) / (1.0 + 4.0 * w));
    return vec4(mix(color.rgb, sharpened, falloff), color.a);
}

void main() {
    if (pc.sharpeningData.w > 0.5) { o_color = casSharpen(); return; }   // (2026-11-13 CAS)
    float intensity = pc.sharpeningData.x * 2.0;
    float maxDepth = pc.sharpeningData.z * 1000.0;

    vec4 color = texture(sampler2D(t_rendered, NVR_SAMPLER(pc.samplerIndex)), uv);
    float depth = readDepth(uv);

    float falloffFactor = pow(saturate((maxDepth - depth) / maxDepth), falloffExponent);

    vec3 average = vec3(0.0);
    float sum = 0.0;
    for (int x = -kernelSize / 2; x <= kernelSize / 2; x++) {
        for (int y = -kernelSize / 2; y <= kernelSize / 2; y++) {
            float weight = 1.0 - float(abs(x) + abs(y)) / float(kernelSize);
            average += texture(sampler2D(t_rendered, NVR_SAMPLER(pc.samplerIndex)), uv + vec2(float(x), float(y)) * pc.reciprocalResolution.xy).rgb * weight;
            sum += weight;
        }
    }
    average /= sum;

    float contrast = dot(abs(color.rgb - average), vec3(luma(color.rgb) / (luma(color.rgb) + 0.05)));

    color.rgb = mix(color.rgb, color.rgb + (color.rgb - average) * saturate(contrast * intensity), falloffFactor);
    o_color = color;
}
