import { afterEach, describe, expect, test } from 'bun:test'
import {
  loadOnboardingComplete,
  loadPinnedApps,
  loadShellMode,
  saveOnboardingComplete,
  savePinnedApps,
  saveShellMode,
} from './storage'

type StorageShape = {
  getItem(key: string): string | null
  setItem(key: string, value: string): void
}

const originalWindow = globalThis.window

function createWindow(): Window & { localStorage: StorageShape } {
  const store = new Map<string, string>()

  return {
    localStorage: {
      getItem(key: string) {
        return store.has(key) ? store.get(key)! : null
      },
      setItem(key: string, value: string) {
        store.set(key, value)
      },
    },
  } as Window & { localStorage: StorageShape }
}

afterEach(() => {
  if (typeof originalWindow === 'undefined') {
    delete (globalThis as { window?: Window }).window
    return
  }

  globalThis.window = originalWindow
})

describe('storage helpers', () => {
  test('savePinnedApps persists ids that loadPinnedApps can restore', () => {
    ;(globalThis as { window?: Window }).window = createWindow() as unknown as Window

    savePinnedApps(['spotify', 'discord'])

    expect(loadPinnedApps()).toEqual(['spotify', 'discord'])
  })

  test('savePinnedApps removes duplicates and blank ids', () => {
    ;(globalThis as { window?: Window }).window = createWindow() as unknown as Window

    savePinnedApps(['spotify', 'spotify', ' ', 'discord'])

    expect(loadPinnedApps()).toEqual(['spotify', 'discord'])
  })

  test('loadPinnedApps returns an empty list when local storage is missing data', () => {
    ;(globalThis as { window?: Window }).window = createWindow() as unknown as Window

    expect(loadPinnedApps()).toEqual([])
  })

  test('saveShellMode persists the desktop shell mode', () => {
    ;(globalThis as { window?: Window }).window = createWindow() as unknown as Window

    saveShellMode('desktop')

    expect(loadShellMode()).toEqual('desktop')
  })

  test('loadShellMode falls back to desktop when unset', () => {
    ;(globalThis as { window?: Window }).window = createWindow() as unknown as Window

    expect(loadShellMode()).toEqual('desktop')
  })

  test('saveOnboardingComplete persists first-run completion', () => {
    ;(globalThis as { window?: Window }).window = createWindow() as unknown as Window

    saveOnboardingComplete(true)

    expect(loadOnboardingComplete()).toEqual(true)
  })

  test('loadOnboardingComplete falls back to false when unset', () => {
    ;(globalThis as { window?: Window }).window = createWindow() as unknown as Window

    expect(loadOnboardingComplete()).toEqual(false)
  })
})
