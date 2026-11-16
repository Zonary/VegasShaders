// UNOFFICIAL 2026-11-14 full deferred renderer, phase 3 (docs/next/FULL-DEFERRED-RENDERER-PLAN.md 4.4 / 4.6, docs/next/FD-SUN-RESULTS.md):
// how a deferred light pass knows that a pixel was drawn by a LIGHTING-FREE record (LAMPS_DEFERRED 2, NVR_LIGHT_DEFERRED: the sun and every
// lamp compiled out), whether that record had a sun term to give back, which sun model it lit with, and its fog share. One place for the
// writers (the templates) and the readers (Shaders/DeferredSun.hlsl; DeferredLamps.hlsl / FlashlightDeferred.hlsl's keep), so the
// encoding can be switched here alone.
//
// The templates' lighting-free records write COLOR1.a with FD_LF_CODE (their only writer of it), keep = 1 - the draw's fog (0..1):
//
// | layout | forward record | LAMPS_DEFERRED 1 / 3 record (sun kept) | lighting-free, sun, PBRSun | lighting-free, sun, PBRDiffuse | lighting-free, no sun |
// |---|---|---|---|---|---|
// | without GBufferV2 (CAPTURED_NORMALS_ON 3) | 1 | keep (+ the old mark: COLOR2.a 1.01..1.99) | 3 + keep | 5 + keep | 7 + keep |
// | GBufferV2 (CAPTURED_NORMALS_ON 4) | 1 | 5 + keep (FD_LAMPS_CODE) | 1 + keep (model: COLOR2.r's specular bit) | 1 + keep | 3 + keep |
//
// UNOFFICIAL 2026-11-14 (claude/fd-interiors, DeferredRenderer 1: core/DeferredRenderer.h) the "sun kept" records: LAMPS_DEFERRED 1 (the
// DeferredLamps many-lamp records) and 3 (every lit family's lamps-deferred record). Their lamps are the lamp pass's, their sun stays in the
// colour. Under GBufferV2 they write FD_LAMPS_V2_BASE + keep (5..6), so the lamp pass lights them (a > 1) and DeferredSun does not (its test
// is a in (1, 2]): every deferred pixel is lit by each pass exactly once, a LAMPS_DEFERRED 1 / 3 pixel and a lighting-free one now told apart.
// Without v2 they keep the older code (keep alone + COLOR2.a's mark), which the passes already tell apart.
//
// Unwritten: 0 (CapturedCoverage's x 0 too). "No sun" = light 0 was a lamp (POINT, the table family's OPT, e.g. SLS2035) or the eye's EyeLight.
// GBufferV2 (its rules, Includes/CapturedNormals.hlsl): COLOR2.r = model + 16 x specular bit + 0.49 x metal; models 8 hair, 9 eye, 10 unlit
// get no sun from the pass either. (DeferredSun.h's old refusal of spans with both kinds is gone, 2026-11-14 fd-fixes: FD_LAMPS_CODE tells
// them apart on both layouts.) fp16 keeps keep to 1/1024 (v2 1..2) .. 1/256 (bases 5, 7).
// Readers: FDSunDeferredPixel / FDSunSpecular / FDLightFreeKeep (DeferredSun.hlsl), FDLightFreePixel / FDAddedLightKeep (DeferredLamps.hlsl,
// FlashlightDeferred.hlsl), and the path tracer's gFlashOwn (Compute/Rt/RtPathTrace.comp: COLOR1.a < 0.5 = unwritten, unchanged by this).
#ifndef NVR_DEFERRED_PIXEL_HLSL
#define NVR_DEFERRED_PIXEL_HLSL

#define FD_LF_SPEC 3.0f
#define FD_LF_MATTE 5.0f
#define FD_LF_NOSUN 7.0f
#define FD_LAMPS_V2_BASE 5.0f	// UNOFFICIAL 2026-11-14 GBufferV2: the "sun kept" records' base (LAMPS_DEFERRED 1 and 3)


#if defined(CAPTURED_NORMALS_ON) && CAPTURED_NORMALS_ON >= 4
    #define FD_GBUFFER_V2 1
#else
    #define FD_GBUFFER_V2 0
#endif

// Writer side: the albedo alpha of a lighting-free record (base: FD_LF_SPEC, FD_LF_MATTE or FD_LF_NOSUN; keep = 1 - fog).
#if FD_GBUFFER_V2
    #define FD_LF_CODE(base, keep) (((base) > 6.5f ? 3.0f : 1.0f) + saturate(keep))
    #define FD_LAMPS_CODE(keep) (FD_LAMPS_V2_BASE + saturate(keep))	// the "sun kept" records (LAMPS_DEFERRED 1 / 3)
#else
    #define FD_LF_CODE(base, keep) ((base) + saturate(keep))
    #define FD_LAMPS_CODE(keep) (keep)	// (the older code: the keep alone, the mark in COLOR2.a)
#endif

// Reader side: a = the resolved COLOR1.a, r = COLOR2.r.
float FDLightFreeBase(float a) { return a < 4.5f ? FD_LF_SPEC : a < 6.5f ? FD_LF_MATTE : FD_LF_NOSUN; }
// The material model (v1: the class; v2: the model without the specular bit).
float FDModel(float r) {
    const float m = floor(r + 0.01f);
#if FD_GBUFFER_V2
    return m >= 15.5f ? m - 16.0f : m;
#else
    return m;
#endif
}
// The pixel's sun was compiled out of its record and is DeferredSun's to add. THE function to switch for another flag.
float FDSunDeferredPixel(float a, float r) {
#if FD_GBUFFER_V2
    const float model = FDModel(r);
    #if defined(FD_HAIR) && FD_HAIR	// UNOFFICIAL 2026-11-15 DeferredHair (core/LightFreeRecords.h HairDeferred): the alpha-tested hair's records (model 8) too
    return a > 1.0001f && a < 2.0005f && (model < 8.5f || model > 10.5f) ? 1.0f : 0.0f;
    #else
    return a > 1.0001f && a < 2.0005f && (model < 7.5f || model > 10.5f) ? 1.0f : 0.0f;
    #endif
#else
    return a > 2.5f && a < 6.5f ? 1.0f : 0.0f;
#endif
}
// The sun model the record lit with: 1 PBRSun (diffuse + the disc's highlight), 0 PBRDiffuse.
float FDSunSpecular(float a, float r) {
#if FD_GBUFFER_V2
    return floor(r + 0.01f) >= 15.5f ? 1.0f : 0.0f;
#else
    return a < 4.5f ? 1.0f : 0.0f;
#endif
}
// Any lighting-free record's pixel, with or without a sun term (a lamp pass lights them all).
float FDLightFreePixel(float a) {
#if FD_GBUFFER_V2
    return a > 1.0001f && a < 4.5f ? 1.0f : 0.0f;	// (2026-11-14: the "sun kept" records' 5 + keep are not lighting-free; the lamp pass's clip takes them by a > 1)
#else
    return a > 2.5f ? 1.0f : 0.0f;
#endif
}
// 1 - fog of a pixel FDSunDeferredPixel accepted.
float FDLightFreeKeep(float a) {
#if FD_GBUFFER_V2
    return saturate(a > 2.5f ? a - 3.0f : a - 1.0f);
#else
    return saturate(a - FDLightFreeBase(a));
#endif
}
// UNOFFICIAL 2026-11-14 (claude/fd-foliage's finding, verified in the templates: ObjectTemplate.hlsl `shaded = LinEncode(lighting)` then
// OBJ_WITH_FOG then LinearSceneOut; ParallaxTemplate and TerrainTemplate alike) THE added-light helper of the deferred passes. The
// templates fog in the STORED curve: forward writes dec(lerp(enc(A + D), F, f)), a deferred record dec(lerp(enc(A), F, f)) (enc = x^(1/gamma),
// dec its inverse; the frame is linear under LinearScene). Adding D x (1 - f) in linear light (plan 4.1's identity) is exact only without fog.
// This returns what a ONE / ONE pass adds so that the pixel becomes exactly the forward value:
//   frame  the pixel's value as the frame holds it now (from a copy of the target), linear if frameLinear > 0.5, else the stored curve
//   D      the light the pass adds (linear); keep = 1 - f; F the fog colour the draw lerped with (stored curve); gamma = TESR_LinearLighting.x
// enc(A) = (enc(frame) - f F) / keep is recovered from the frame and enc(A + D) put back under the same fog, so passes chain exactly (the sun,
// then the lamps over it). No fog (keep 1) or no linear lighting (gamma 1: the lerp is linear already) give D x keep by the same formula, so
// there is no branch (the lamp pass has no temp register to spare for one: X4505); the callers skip it where keep is 1.
float3 FDAddFogged(float3 frame, float3 D, float keep, float3 F, float gamma, float frameLinear) {
    gamma = max(gamma, 1.0f);
    const float invGamma = 1.0f / gamma;
    const float3 v = frameLinear > 0.5f ? pow(max(frame, 0.0f), invGamma) : max(frame, 0.0f);	// the stored value the record left
    const float f = 1.0f - keep;
    const float3 encA = max(v - f * F, 0.0f) / max(keep, 1.0e-4f);
    const float3 v2 = f * F + keep * pow(pow(encA, gamma) + max(D, 0.0f), invGamma);
    return frameLinear > 0.5f ? pow(v2, gamma) - max(frame, 0.0f) : v2 - v;
}

// The keep for a pass that lights every kind of pixel (DeferredLamps, FlashlightDeferred): a lighting-free pixel's from its code, the
// older writers' as they wrote it (v2: a deferred record's 1 + keep; a forward record's 1 = keep 1).
float FDAddedLightKeep(float a) {
#if FD_GBUFFER_V2
    return a > 4.5f ? a - FD_LAMPS_V2_BASE : a > 2.5f ? a - 3.0f : a > 1.0001f ? a - 1.0f : a;	// (2026-11-14: + the "sun kept" records' 5 + keep)
#else
    return a > 2.5f ? FDLightFreeKeep(a) : a;
#endif
}

// UNOFFICIAL 2026-11-14 foliage (claude/fd-foliage; Includes/FoliageDeferred.hlsl, core/DeferredFoliage.h): the leaf / grass DEFERRED records'
// fog factor, the writer and the reader in one place like the templates' FD_LF_CODE. Those records keep COLOR1.a at a forward record's 1
// (their lamps are in the colour: no lamp pass, no object sun branch), and the grass is SRCALPHA-blended (every alpha its 0 / 1 coverage),
// so the keep goes in COLOR2.g, the "no shading normal" channel (g 4 and up), in ranges no other writer uses, every code ON fp16's grid
// (so the target stores it exactly and the reader gets the same integer back):
//   leaves  g = 16 + round(1023 keep) / 64      [16, 32), fp16 steps 1/64 there: keep to 1/1023 (the templates' 1 + keep: 1/1024)
//   grass   g = the code i = 40 k + h written as the i-th fp16 value from 32 on: 32 x 2^o x (1 + m / 1024), o = i / 1024 (0..4), m = i mod 1024,
//           so g in [32, 1024) holds 5120 codes: k = round(127 keep) (128 levels, keep to 1/127) x h = round(39 enc(highlight)) (40 levels,
//           FOLIAGE_HIGHLIGHT_MAX 1: the sun's highlight, which has the sun's hue, not the albedo's)
// A record fogs its colour with the keep its code holds (FDFoliage*KeepQ), so the colour and the code agree and FDAddFogged is exact; the
// forward fog moves by at most half a level (1/2046 of the fog's share on leaves, 1/254 on grass). Readers of COLOR2.g as the grass mark
// (CapturedNormals.h MergeIntoNormals, its self-check) take [32, 1024) as grass while foliage records are made (CapturedNormals::FoliageGrassRange).
#define FD_FOLIAGE_LEAF_BASE 16.0f
#define FD_FOLIAGE_GRASS_BASE 32.0f
#define FD_FOLIAGE_GRASS_TOP 1024.0f
float FDFoliageLeafKeepQ(float keep) { return floor(saturate(keep) * 1023.0f + 0.5f) / 1023.0f; }
float FDFoliageGrassKeepQ(float keep) { return floor(saturate(keep) * 127.0f + 0.5f) / 127.0f; }
float FDFoliageLeafCode(float keepQ) { return FD_FOLIAGE_LEAF_BASE + floor(saturate(keepQ) * 1023.0f + 0.5f) / 64.0f; }
float FDFoliageGrassCode(float keepQ, float highlightEnc) {
    const float i = 40.0f * floor(saturate(keepQ) * 127.0f + 0.5f) + floor(saturate(highlightEnc) * 39.0f + 0.5f);
    const float o = floor(i / 1024.0f + 1.0e-4f);
    const float p = FD_FOLIAGE_GRASS_BASE * (o > 0.5f ? 2.0f : 1.0f) * (o > 1.5f ? 2.0f : 1.0f) * (o > 2.5f ? 2.0f : 1.0f) * (o > 3.5f ? 2.0f : 1.0f);
    return p * (1.0f + (i - 1024.0f * o) / 1024.0f);
}
float FDFoliageIsGrass(float g) { return g > FD_FOLIAGE_GRASS_BASE - 0.01f && g < FD_FOLIAGE_GRASS_TOP ? 1.0f : 0.0f; }
// The grass code's index back from g (exact for any value the writer made).
float FDFoliageGrassIndex(float g) {
    const float o = (g >= 63.99f ? 1.0f : 0.0f) + (g >= 127.99f ? 1.0f : 0.0f) + (g >= 255.99f ? 1.0f : 0.0f) + (g >= 511.99f ? 1.0f : 0.0f);
    const float p = FD_FOLIAGE_GRASS_BASE * (o > 0.5f ? 2.0f : 1.0f) * (o > 1.5f ? 2.0f : 1.0f) * (o > 2.5f ? 2.0f : 1.0f) * (o > 3.5f ? 2.0f : 1.0f);
    return 1024.0f * o + floor((g / p - 1.0f) * 1024.0f + 0.5f);
}
// keep (1 - fog) of a foliage deferred pixel (leaf or grass), and the grass's encoded highlight (0..1, the record's LinEncode of it)
float FDFoliageKeep(float g) {
    return g < FD_FOLIAGE_GRASS_BASE - 0.01f ? saturate(floor((g - FD_FOLIAGE_LEAF_BASE) * 64.0f + 0.5f) / 1023.0f)
                                             : floor(FDFoliageGrassIndex(g) / 40.0f + 1.0e-3f) / 127.0f;
}
float FDFoliageHighlightEnc(float g) {
    const float i = FDFoliageGrassIndex(g);
    return (i - 40.0f * floor(i / 40.0f + 1.0e-3f)) / 39.0f;
}

#endif
