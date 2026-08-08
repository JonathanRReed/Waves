#ifndef WAVES_REALTIME_SUPPORT_H
#define WAVES_REALTIME_SUPPORT_H

#include <stdbool.h>
#include <stdint.h>

typedef struct WavesAtomicTapRenderState WavesAtomicTapRenderState;

WavesAtomicTapRenderState *WavesAtomicTapRenderStateCreate(
    float volume,
    float volumeBoost,
    uint32_t isMuted,
    uint32_t isActive,
    float peakLevel,
    float rmsLevel,
    float analysisRMS,
    float voiceBandEnergy,
    uint64_t renderTick);
void WavesAtomicTapRenderStateDestroy(WavesAtomicTapRenderState *state);
void WavesAtomicTapRenderStateLoad(
    const WavesAtomicTapRenderState *state,
    float *volume,
    float *volumeBoost,
    uint32_t *isMuted,
    uint32_t *isActive,
    float *peakLevel,
    float *rmsLevel,
    float *analysisRMS,
    float *voiceBandEnergy,
    uint64_t *renderTick);
void WavesAtomicTapRenderStateStoreControls(
    WavesAtomicTapRenderState *state,
    float volume,
    float volumeBoost,
    uint32_t isMuted);
void WavesAtomicTapRenderStateStoreLevels(
    WavesAtomicTapRenderState *state,
    float peakLevel,
    float rmsLevel,
    float analysisRMS,
    float voiceBandEnergy);
void WavesAtomicTapRenderStateMarkRenderTick(WavesAtomicTapRenderState *state);
uint64_t WavesAtomicTapRenderStateReadRenderTick(const WavesAtomicTapRenderState *state);
void WavesAtomicTapRenderStateSetInactive(WavesAtomicTapRenderState *state);
void WavesAtomicTapRenderStateFlagGeometryMismatch(WavesAtomicTapRenderState *state);
bool WavesAtomicTapRenderStateConsumeGeometryMismatch(WavesAtomicTapRenderState *state);

#endif
