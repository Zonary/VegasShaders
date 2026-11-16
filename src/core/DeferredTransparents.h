#pragma once
// UNOFFICIAL 2026-11-15 DeferredTransparents: forward+ for the blended (alpha) draws of the deferred renderer (docs/next/FULL-DEFERRED-RENDERER-
// PLAN.md phase 5; results and bench request: docs/next/FD-GLASS-RESULTS.md).
//
// [Main.Main.Quality] DeferredTransparents (restart to compile the records, then live; test only; default 0; needs DeferredRenderer >= 1, whose
// prerequisites make the lamp table with its froxel lists and tile rows and the shadow atlas on both runtimes):
//  - Why: glass, bottles, windows and light shades draw in the game's sorted blended list (RenderBlendedHook), after the main list's G-buffer
//    span, so the deferred lamp pass never lights them: they keep the game's own one-pass lamps (the shader's slots: 2 in the ADTS2 / ADTS
//    records, 6 + f with MoreLampsPerObject in the ADTS10 one-pass record on native; the fork's ManyLamps 24 / the froxel's 31 in SLS2034-2036
//    only), and the rest of the room's lamps go missing on them (FD-GLASS-RESULTS.md, the census).
//  - Records (ShaderManager::LoadShader, at load, next to DeferredRenderer::LoadInterior): every lit Object pixel shader with an Interior record
//    (not the added-light, light-only or hair passes) gets one more from the same Interior overrides + LAMPS_DEFERRED 4 (ObjectTemplate.hlsl
//    NVR_FORWARD_PLUS, Includes/ForwardPlus.hlsl): the game's lamps out, the sun / cell light slot kept, every lamp of the pixel's froxel from
//    the table added, each shadowed from its atlas tile. If 4 does not load, 5 (the same unshadowed). Own cache folder.
//  - Choice (NiD3DPixelShaderEx::SetupShader, Choose): indoors, inside the blended list (ListScope, RenderBlendedHook), in the world context
//    (BeforeBind: not reflections, first person, an extra camera or menus: their cameras are not the table's), while the table made this frame
//    holds this frame's froxel lists and is unlocked (LampTableThread: FinishTable at the list's start). Anything else: the record chosen as
//    before.
//  - Bind (OnBind, after the game's bind): the table on s3 (point), the atlas on s8 (linear), c180 / c181 the lamp shadows' parameters
//    (PointShadowForward's own registers and values; its cache is kept in step).
//  - Safety net (Skip / AfterDraw): an object whose base pass drew with a forward+ record skips its own lamp passes (and highlight passes after
//    a SPECULAR base) for the frame, as the deferred renderer does for its deferred records; the census found none in the blended list.
// Off (0, the default): no record is made, nothing chosen, bound, written into the table or skipped.
#include "DeferredRenderer.h"
#include "ForwardPlusHeader.h"

namespace DeferredTransparents {
	inline const char* kSection = "Main.Main.Quality";
	inline const char* kKey = "DeferredTransparents";
	inline const char* kCache = "Deferred\\Glass\\";

	inline int Wanted = -1;
	inline bool WantedAtStartup() {
		if (Wanted < 0) Wanted = DeferredRenderer::On() && TheSettingManager->GetSettingI(kSection, kKey) != 0 ? 1 : 0;
		return Wanted != 0;
	}

	inline std::unordered_map<const void*, ShaderRecordPixel*> Records;	// NiD3DPixelShaderEx* -> its forward+ record
	inline std::unordered_set<IDirect3DPixelShader9*> Handles, SpecularHandles;
	inline unsigned Loaded = 0, Unshadowed = 0, Refused = 0;

	inline bool Live = false;			// this frame (BeginFrame): on, indoors, the table and its lists possible
	inline bool InList = false;			// the blended list is drawing (ListScope)
	inline bool ListReady = false;		// ... and this frame's table and lists are there and unlocked (checked at the list's start)
	inline bool BindWorld = false;		// the bind under way is in the world context (BeforeBind)
	inline bool BoundOurs = false, BoundSpecular = false;
	inline UInt32 FrameId = 1;

	// F10 line
	inline unsigned StatFrames = 0;
	inline unsigned long long StatBinds = 0, StatDraws = 0, StatLists = 0, StatListsRefused = 0, StatOtherContext = 0, StatSkipped = 0;

	// The Object template's lit base / one-pass records (DeferredRenderer::Eligible's families less the light-only AD passes: their light is
	// multiplied by the texture pass afterwards, and the census found none blended).
	inline bool Eligible(const char* name, const ShaderTemplate& tmpl) {
		if (!tmpl.Name || strcmp(tmpl.Name, "ObjectTemplate") || !DeferredRenderer::Eligible(name, tmpl, 1)) return false;
		return !DeferredRenderer::HasDefine(tmpl, "ONLY_LIGHT");
	}

	// ShaderManager::LoadShader, where a lit shader's level-0 Interior record loaded (overrides: that record's Interior overrides).
	inline void Load(NiD3DPixelShaderEx* shader, const char* name, ShaderTemplate tmpl, const D3DXMACRO* interiorOverrides) {
		if (!WantedAtStartup() || !Eligible(name, tmpl) || Records.count(shader)) return;
		static D3DXMACRO overrides[14] = {};
		int n = 0;
		for (const D3DXMACRO* o = interiorOverrides; o && o->Name && n < 12; o++) overrides[n++] = *o;
		ShaderRecordPixel* record = nullptr;
		for (int level = 4; level <= 5 && !record; level++) {
			overrides[n] = { "LAMPS_DEFERRED", level == 4 ? "4" : "5" };
			overrides[n + 1] = { NULL, NULL };
			ShaderTemplate copy = tmpl;	// (LoadShader appends the global defines to the template it is given)
			record = (ShaderRecordPixel*)ShaderRecord::LoadShader(name, NULL, copy, level == 4 ? kCache : "Deferred\\GlassUnshadowed\\", overrides);
			if (!record && level == 4) Logger::Log("[WARNING] DEFERRED TRANSPARENTS record %s: the shadowed version did not load; trying it without lamp shadows", name);
			if (record && level == 5) Unshadowed++;
		}
		if (!record) { Refused++; Logger::Log("[WARNING] DEFERRED TRANSPARENTS record %s: did not load: its blended draws keep the game's lamps (%u loaded, %u not)", name, Loaded, Refused); return; }
		Records[shader] = record;
		Handles.insert(record->ShaderHandle);
		if (DeferredRenderer::HasDefine(tmpl, "SPECULAR")) SpecularHandles.insert(record->ShaderHandle);
		ForwardPlusHeader::Enabled = true;
		Loaded++;
		Logger::Log("DEFERRED TRANSPARENTS record %s: loaded (%u loaded, %u of them unshadowed, %u not so far)", name, Loaded, Unshadowed, Refused);
	}

	// Once a frame (Render.cpp, after DeferredRenderer::BeginFrame).
	inline void BeginFrame() {
		FrameId++;
		if (!WantedAtStartup() || Records.empty()) { Live = false; return; }
		static bool told = false;
		if (!told) {
			told = true;
			Logger::Log("UNOFFICIAL DeferredTransparents: %u forward+ records (%u unshadowed), %u did not load; the lamp table %s, its tile rows %s, the atlas %s",
				Loaded, Unshadowed, Refused, ManyLamps::FroxelRows() ? "with froxel lists" : "WITHOUT froxel lists (nothing to read: off)",
				ManyLamps::TileRowsWanted() ? "made" : "NOT made (no header: off)", PointShadowForward::AtlasRuns() ? "made" : "not made (unshadowed)");
		}
		Live = TheSettingManager->GetSettingI(kSection, kKey) != 0 && !TheShaderManager->GameState.isExterior && ManyLamps::FroxelRows() &&
			ManyLamps::TileRowsWanted() && !ManyLamps::TableFailed;
		if (!GpuTimer::Enabled) { StatFrames = 0; return; }
		if (++StatFrames < 240) return;
		const double f = (double)StatFrames;
		Logger::Log("DEFERRED TRANSPARENTS %u frames, %s: blended lists %.2f a frame (%.2f without this frame's table: the game's lamps), forward+ binds %.1f, draws %.1f, "
			"lamp / highlight passes skipped %.2f, binds left alone outside the world context %.1f; header writes %u (%u with lists)",
			StatFrames, Live ? "live" : "off", StatLists / f, StatListsRefused / f, StatBinds / f, StatDraws / f, StatSkipped / f, StatOtherContext / f,
			ForwardPlusHeader::Writes, ForwardPlusHeader::ValidWrites);
		StatFrames = 0; StatBinds = StatDraws = StatLists = StatListsRefused = StatOtherContext = StatSkipped = 0;
		ForwardPlusHeader::Writes = ForwardPlusHeader::ValidWrites = 0;
	}

	// RenderBlendedHook: the sorted blended list. At its start the table made at this frame's first world draw is finished (LampTableThread's
	// binding waited for and the table unlocked: the blended draws read it) and checked; a table of another frame, or one without this frame's
	// froxel lists (no world draw made them), is not read: every draw keeps its forward record.
	struct ListScope {
		bool was;
		ListScope() : was(InList) {
			InList = true;
			ListReady = false;
			if (!Live) return;
			ManyLamps::FinishTable();
			ListReady = ManyLamps::Table && !ManyLamps::TableFailed && ManyLamps::TableFrame == ManyLamps::FrameId &&
				ManyLamps::ListsFrame == ManyLamps::FrameId && !ManyLamps::TableJob.pending;
			StatLists++;
			if (!ListReady) StatListsRefused++;
		}
		~ListScope() { InList = was; if (!was) ListReady = false; }
	};

	// SetShadersHook, before the game's bind (SetupShader runs inside it): the context of this bind.
	inline void BeforeBind(bool world) { BindWorld = world; }

	// NiD3DPixelShaderEx::SetupShader.
	inline ShaderRecordPixel* Choose(const void* shader) {
		if (!Live || !InList || !ListReady) return nullptr;
		auto found = Records.find(shader);
		if (found == Records.end()) return nullptr;
		if (!BindWorld) { StatOtherContext++; return nullptr; }
		StatBinds++;
		return found->second;
	}

	// SetShadersHook, after the game's bind: a forward+ record bound gets the table, the atlas and the lamp shadows' parameters.
	inline void OnBind(IDirect3DPixelShader9* handle) {
		BoundOurs = Live && handle && Handles.count(handle) != 0;
		BoundSpecular = BoundOurs && SpecularHandles.count(handle) != 0;
		if (!BoundOurs) return;
		PointShadowForward::Bind(3, ManyLamps::Table, true, true);
		PointShadowForward::Bind(8, PointShadowForward::AtlasTexture ? (IDirect3DBaseTexture9*)PointShadowForward::AtlasTexture : (IDirect3DBaseTexture9*)ManyLamps::Table, true, false);
		float k[2][4] = {};
		if (PointShadowForward::Active && PointShadowForward::AtlasTexture) memcpy(k[0], PointShadowForward::Params, sizeof(k[0]));	// x 0: TableLampShadow lights every lamp
		k[1][1] = PointShadowForward::NearFade;
		k[1][3] = PointShadowForward::Quality;
		TheRenderManager->device->SetPixelShaderConstantF(180, &k[0][0], 2);
		memcpy(PointShadowForward::Uploaded[6], k, sizeof(k));	// (its cache of c174-c189 in step: c180, c181)
	}

	// Objects whose base pass drew with a forward+ record this frame (open addressing tagged with the frame, as DeferredRenderer's).
	constexpr unsigned kSlots = 4096;
	inline const void* Key[kSlots] = {};
	inline UInt32 Frame[kSlots] = {};
	inline bool Spec[kSlots] = {};
	inline int Find(const void* geometry, bool insert) {
		unsigned h = (unsigned)(((uintptr_t)geometry >> 4) * 2654435761u) & (kSlots - 1);
		for (unsigned probe = 0; probe < 32; probe++, h = (h + 1) & (kSlots - 1)) {
			if (Frame[h] == FrameId && Key[h] == geometry) return (int)h;
			if (Frame[h] != FrameId) {
				if (!insert) return -1;
				Key[h] = geometry; Frame[h] = FrameId; Spec[h] = false;
				return (int)h;
			}
		}
		return -1;
	}

	// Render.cpp's pass hooks, early: the lamp passes (and after a SPECULAR base the highlight passes) of an object lit by forward+ this frame.
	inline bool Skip(const void* passPtr, bool world) {
		if (!Live || !InList || !world || !passPtr) return false;
		const PointShadowForward::RenderPassView* pass = (const PointShadowForward::RenderPassView*)passPtr;
		const PassSums::Kind kind = PassSums::KindOf(pass->passEnum);
		if (kind == PassSums::None) return false;
		const int slot = Find(pass->geometry, false);
		if (slot < 0 || (kind == PassSums::Highlights && !Spec[slot])) return false;
		StatSkipped++;
		return true;
	}

	// Render.cpp's pass hooks, after the game drew the pass.
	inline void AfterDraw(const void* passPtr, bool world) {
		if (!BoundOurs || !InList || !world || !passPtr) return;
		const PointShadowForward::RenderPassView* pass = (const PointShadowForward::RenderPassView*)passPtr;
		StatDraws++;
		if (PassSums::KindOf(pass->passEnum) != PassSums::None || !pass->geometry) return;
		const int slot = Find(pass->geometry, true);
		if (slot >= 0) Spec[slot] = BoundSpecular;
	}
}
