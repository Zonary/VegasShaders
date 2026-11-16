// Pixel-shader pieces shared by the SpeedTree leaf shaders (STLEAF2000/2001 and their TMS variants).
// The vertex shader hands over the game's summed lighting (TEXCOORD1) and, separately, the sun's share of it (TEXCOORD3), so the
// pixel shader can take away exactly the shadowed part of the sun: fully lit gives back the game's own value to the bit.
#ifndef LEAF_INCLUDED
#define LEAF_INCLUDED

// UNOFFICIAL linear lighting (Includes/LinearLight.hlsl, [Shaders.PBR.Linear]), compiled in only when on at startup
// (LINEAR_LIGHTING_ON, ShaderRecord::LoadShader); otherwise LinColor / LinEncode / LinScale return their input.
#if defined(LINEAR_LIGHTING_ON) && LINEAR_LIGHTING_ON && !defined(LINEAR_LIGHTING)
    #define LINEAR_LIGHTING
#endif
#ifdef __INTELLISENSE__
    #include "LinearLight.hlsl"
#else
    #include "includes/LinearLight.hlsl"
#endif

sampler2D DiffuseMap: register(s0);	// leaf texture

// Interpolators written by the leaf vertex shaders (the member names are used by the STLEAF pixel shaders).
struct PS_INPUT {	// vertex to pixel
    float2 uv:             TEXCOORD0;
    float4 lighting:       TEXCOORD1_centroid;	// game lighting, all lights summed
    float4 fog:            TEXCOORD2_centroid;	// xyz fog colour, w fog amount
    float3 sun:            TEXCOORD3_centroid;	// the sun's part of .lighting
    float4 shadowWorldPos: TEXCOORD4;	// w flags whether the vertex shader filled it in
};

// UNOFFICIAL 2026-11-12 leaf records (docs/next/PT-COMPAT-AUDIT-2026-11-12.md item 9; Includes/CapturedNormals.hlsl CAPTURED_FOLIAGE;
// core/CapturedNormals.h LeafWriters, [Main.Main.Quality] CapturedLeaves): with the AlbedoBuffer compiled in, the leaf shaders write
// their own colour, material and normal records (COLOR1-3) where the capture binds them. Without it they are exactly as before. The four
// STLEAF pixel shaders include Shadow.hlsl first (CapturedNormalOut needs its ShadowEncodeNormal).
#if defined(CAPTURED_NORMALS_ON) && CAPTURED_NORMALS_ON >= 3
    #ifdef __INTELLISENSE__
        #include "CapturedNormals.hlsl"
    #else
        #include "includes/CapturedNormals.hlsl"
    #endif
#endif

struct PS_OUTPUT {
    float4 color: COLOR0;
#ifdef CAPTURED_FOLIAGE
    CAPTURED_FOLIAGE_OUTPUTS	// (discarded where nothing is bound there)
#endif
};

// Call from main's top level, after OUT.color (the face normal takes gradients). The leaf texture's colour, decoded (the vertex shader
// hands over light, not a tint); class 5 (plants) with a matte roughness; the card's own face normal (the leaf vertex shaders pass no
// normal on: the one the sun shadow lookup uses) with the camera distance. Written only with Vegas Shaders' leaf vertex shader (the
// position is its); the cut-out's holes write nothing anywhere (the game's alpha test).
#ifdef CAPTURED_FOLIAGE
    #define LeafRecords(OUT, leaf, albedo) {         const float leafWritten = SHADOW_VS_PRESENT((leaf).shadowWorldPos.w) ? 1.0f : 0.0f;         (OUT).capturedPad1 = CapturedFoliageAlbedo(saturate(LinColor((albedo).rgb)), leafWritten);         (OUT).capturedPad2 = CapturedFoliageMaterial(0.85f, leafWritten);         (OUT).capturedNormal = CapturedFoliageNormal(GetShadowGeometricNormal((leaf).shadowWorldPos.xyz), (leaf).shadowWorldPos.xyz, leafWritten); }
#else
    #define LeafRecords(OUT, leaf, albedo)
#endif

// UNOFFICIAL 2026-11-14 full deferred renderer, phase 3: the leaf's DEFERRED record (FOLIAGE_DEFERRED 1, made by core/DeferredFoliage.h only
// with [Main.Main.Quality] DeferredFoliage and GBufferV2 at startup; Includes/FoliageDeferred.hlsl has the model). No sun shadow lookup here:
// COLOR0 is the leaf without its sun, COLOR2.b carries the sun's unshadowed light for DeferredSun. Call after LeafRecords. Without the
// define: nothing (the macro is empty and the leaf shaders compile as before).
#if defined(FOLIAGE_DEFERRED) && FOLIAGE_DEFERRED && defined(CAPTURED_FOLIAGE) && CAPTURED_NORMALS_ON >= 4
    #define NVR_FOLIAGE_DEFERRED 1
    #ifdef __INTELLISENSE__
        #include "FoliageDeferred.hlsl"
    #else
        #include "includes/FoliageDeferred.hlsl"
    #endif
    void LeafDeferredApply(inout PS_OUTPUT OUT, PS_INPUT leaf, float4 albedo, float3 fogColour, float fogAmount) {
        const float3 a = LinColor(albedo.rgb);
        const float3 rest = LinColor(leaf.lighting.rgb - leaf.sun), sun = LinColor(leaf.sun);	// as LeafLighting splits them (identity without linear lighting)
        const float keepQ = FDFoliageLeafKeepQ(1.0f - fogAmount);	// (2026-11-14 fog: the keep the code holds, so DeferredSun's FDAddFogged is exact)
        const float3 without = lerp(LinEncode(a * rest), fogColour, 1.0f - keepQ);
        const float3 with = lerp(LinEncode(a * (rest + sun)), fogColour, fogAmount);
        const bool ours = SHADOW_VS_PRESENT(leaf.shadowWorldPos.w);	// Vegas Shaders' leaf VS (the sun handed over apart); else no record was written
        OUT.color.rgb = ours ? without : with;
        // the sun's light, unshadowed and unfogged, per unit of A x the sun's hue: its luma (the leaf's light IS the sun's colour x one number)
        OUT.capturedPad2.b = ours ? FoliageSunCode(FoliageLuma(sun)) : OUT.capturedPad2.b;
        OUT.capturedPad2.g = ours ? FDFoliageLeafCode(keepQ) : OUT.capturedPad2.g;
    }
    #define LeafDeferred(OUT, leaf, albedo, fogColour, fogAmount) LeafDeferredApply(OUT, leaf, albedo, fogColour, fogAmount);
#else
    #define LeafDeferred(OUT, leaf, albedo, fogColour, fogAmount)
#endif

// Call from main's top level only (the shadow lookup takes gradients, which dynamic branches would forbid).
float3 LeafLighting(PS_INPUT leaf) {
#if FORWARD_SHADOWS && !defined(NVR_FOLIAGE_DEFERRED)	// NVR sun shadows in the object pass (2026-11-14: not in the deferred record: DeferredSun's)
    float3 faceN = GetShadowGeometricNormal(leaf.shadowWorldPos.xyz);
    float sunVis = SHADOW_VS_PRESENT(leaf.shadowWorldPos.w) ? GetSunShadow(leaf.shadowWorldPos.xyz, faceN) : 1.0f;
    #ifdef LINEAR_LIGHTING
        // UNOFFICIAL linear lighting: decode the sun and everything else separately and add them in linear (the leaf shaders encode).
        return LinColor(leaf.lighting.rgb - leaf.sun) + LinColor(leaf.sun) * sunVis;
    #else
        return leaf.lighting.rgb - leaf.sun * (1.0f - sunVis);
    #endif
#else
    #ifdef LINEAR_LIGHTING
        return LinColor(leaf.lighting.rgb - leaf.sun) + LinColor(leaf.sun);
    #else
        return leaf.lighting.rgb;
    #endif
#endif
}

#endif
