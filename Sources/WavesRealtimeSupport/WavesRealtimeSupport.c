#include "WavesRealtimeSupport.h"

#include <stdatomic.h>
#include <stdlib.h>

struct WavesAtomicTapRenderState {
  _Atomic(float) volume;
  _Atomic(float) volumeBoost;
  _Atomic(uint32_t) isMuted;
  _Atomic(uint32_t) isActive;
  _Atomic(float) peakLevel;
  _Atomic(float) rmsLevel;
  _Atomic(float) analysisRMS;
  _Atomic(float) voiceBandEnergy;
  _Atomic(uint64_t) renderTick;
  _Atomic(bool) geometryMismatch;
};

WavesAtomicTapRenderState *WavesAtomicTapRenderStateCreate(
    float volume, float volumeBoost, uint32_t isMuted, uint32_t isActive,
    float peakLevel, float rmsLevel, float analysisRMS, float voiceBandEnergy,
    uint64_t renderTick) {
  WavesAtomicTapRenderState *state = malloc(sizeof(*state));
  if (state == NULL) return NULL;
  atomic_init(&state->volume, volume);
  atomic_init(&state->volumeBoost, volumeBoost);
  atomic_init(&state->isMuted, isMuted);
  atomic_init(&state->isActive, isActive);
  atomic_init(&state->peakLevel, peakLevel);
  atomic_init(&state->rmsLevel, rmsLevel);
  atomic_init(&state->analysisRMS, analysisRMS);
  atomic_init(&state->voiceBandEnergy, voiceBandEnergy);
  atomic_init(&state->renderTick, renderTick);
  atomic_init(&state->geometryMismatch, false);
  return state;
}

void WavesAtomicTapRenderStateDestroy(WavesAtomicTapRenderState *state) { free(state); }

void WavesAtomicTapRenderStateLoad(
    const WavesAtomicTapRenderState *state, float *volume, float *volumeBoost,
    uint32_t *isMuted, uint32_t *isActive, float *peakLevel, float *rmsLevel,
    float *analysisRMS, float *voiceBandEnergy, uint64_t *renderTick) {
  *volume = atomic_load_explicit(&state->volume, memory_order_acquire);
  *volumeBoost = atomic_load_explicit(&state->volumeBoost, memory_order_acquire);
  *isMuted = atomic_load_explicit(&state->isMuted, memory_order_acquire);
  *isActive = atomic_load_explicit(&state->isActive, memory_order_acquire);
  *peakLevel = atomic_load_explicit(&state->peakLevel, memory_order_acquire);
  *rmsLevel = atomic_load_explicit(&state->rmsLevel, memory_order_acquire);
  *analysisRMS = atomic_load_explicit(&state->analysisRMS, memory_order_acquire);
  *voiceBandEnergy = atomic_load_explicit(&state->voiceBandEnergy, memory_order_acquire);
  *renderTick = atomic_load_explicit(&state->renderTick, memory_order_acquire);
}

void WavesAtomicTapRenderStateStoreControls(
    WavesAtomicTapRenderState *state, float volume, float volumeBoost,
    uint32_t isMuted) {
  atomic_store_explicit(&state->volume, volume, memory_order_release);
  atomic_store_explicit(&state->volumeBoost, volumeBoost, memory_order_release);
  atomic_store_explicit(&state->isMuted, isMuted, memory_order_release);
}

void WavesAtomicTapRenderStateStoreLevels(
    WavesAtomicTapRenderState *state, float peakLevel, float rmsLevel,
    float analysisRMS, float voiceBandEnergy) {
  atomic_store_explicit(&state->peakLevel, peakLevel, memory_order_release);
  atomic_store_explicit(&state->rmsLevel, rmsLevel, memory_order_release);
  atomic_store_explicit(&state->analysisRMS, analysisRMS, memory_order_release);
  atomic_store_explicit(&state->voiceBandEnergy, voiceBandEnergy, memory_order_release);
}

void WavesAtomicTapRenderStateMarkRenderTick(WavesAtomicTapRenderState *state) {
  atomic_fetch_add_explicit(&state->renderTick, 1, memory_order_relaxed);
}

uint64_t WavesAtomicTapRenderStateReadRenderTick(const WavesAtomicTapRenderState *state) {
  return atomic_load_explicit(&state->renderTick, memory_order_acquire);
}

void WavesAtomicTapRenderStateSetInactive(WavesAtomicTapRenderState *state) {
  atomic_store_explicit(&state->isActive, 0, memory_order_release);
}

void WavesAtomicTapRenderStateFlagGeometryMismatch(WavesAtomicTapRenderState *state) {
  atomic_store_explicit(&state->geometryMismatch, true, memory_order_release);
}

bool WavesAtomicTapRenderStateConsumeGeometryMismatch(WavesAtomicTapRenderState *state) {
  return atomic_exchange_explicit(&state->geometryMismatch, false, memory_order_acq_rel);
}
