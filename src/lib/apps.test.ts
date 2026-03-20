import { describe, expect, test } from 'bun:test'
import { buildViewApps, filterViewApps, hasValidSessionIdentity, partitionViewApps, type VolumeDrafts } from './apps'
import type { AppAudioSession } from '../types/waves'

function createApp(overrides: Partial<AppAudioSession> = {}): AppAudioSession {
  return {
    id: overrides.id ?? 'spotify',
    displayName: overrides.displayName ?? 'Spotify',
    processName: overrides.processName ?? 'Spotify',
    bundleId: overrides.bundleId ?? null,
    detected: overrides.detected ?? true,
    audible: overrides.audible ?? (overrides.active ?? true),
    runningOutput: overrides.runningOutput ?? (overrides.active ?? true),
    recentSignal: overrides.recentSignal ?? (overrides.active ?? true),
    recentRender: overrides.recentRender ?? (overrides.active ?? true),
    lastSeenAt: overrides.lastSeenAt ?? '1000',
    lastSignalAt: overrides.lastSignalAt ?? ((overrides.active ?? true) ? '1000' : null),
    category: overrides.category ?? 'Music',
    volume: overrides.volume ?? 75,
    muted: overrides.muted ?? false,
    active: overrides.active ?? true,
    pinnedHint: overrides.pinnedHint ?? false,
    peakLevel: overrides.peakLevel ?? 0.65,
    support: overrides.support ?? {
      controllable: true,
      reason: null,
    },
  }
}

describe('app helpers', () => {
  test('keeps pinned inactive sessions visible so the mixer stays stable between launches', () => {
    const apps = [
      createApp({ id: 'spotify', active: false }),
      createApp({ id: 'discord', displayName: 'Discord', processName: 'Discord', peakLevel: 0.22 }),
    ]

    const viewApps = buildViewApps(apps, ['spotify'], {})

    expect(viewApps.map((app) => app.id)).toEqual(['discord', 'spotify'])
  })

  test('keeps active read-only sessions visible instead of hiding them', () => {
    const apps = [
      createApp({
        id: 'safari',
        displayName: 'Safari',
        processName: 'Safari',
        support: {
          controllable: false,
          reason: 'Read only session',
        },
      }),
    ]

    const viewApps = buildViewApps(apps, [], {})

    expect(viewApps.length).toEqual(1)
    expect(viewApps[0]?.support.controllable).toEqual(false)
  })

  test('keeps idle discovered sessions visible so browsers do not disappear between refreshes', () => {
    const viewApps = buildViewApps(
      [
        createApp({
          id: 'chrome',
          displayName: 'Google Chrome',
          processName: 'com.google.chrome',
          active: false,
          support: {
            controllable: false,
            reason: 'Idle right now',
          },
        }),
      ],
      [],
      {},
    )

    expect(viewApps.map((app) => app.id)).toEqual(['chrome'])
  })

  test('keeps recently active sessions in the live section during the short hold window', () => {
    const viewApps = buildViewApps(
      [
        createApp({
          id: 'chrome',
          displayName: 'Google Chrome',
          processName: 'com.google.chrome',
          active: false,
          recentSignal: true,
          lastSignalAt: '5000',
        }),
      ],
      [],
      {},
    )

    expect(viewApps[0]?.live).toEqual(true)
  })

  test('prefers draft slider values until the backend snapshot catches up', () => {
    const drafts: VolumeDrafts = {
      spotify: 24,
    }

    const viewApps = buildViewApps([createApp()], [], drafts)

    expect(viewApps[0]?.displayVolume).toEqual(24)
  })

  test('filters by search query and pinned-only mode', () => {
    const apps = buildViewApps(
      [
        createApp({ id: 'spotify', category: 'Music' }),
        createApp({ id: 'discord', displayName: 'Discord', processName: 'Discord', category: 'Chat' }),
      ],
      ['discord'],
      {},
    )

    expect(filterViewApps(apps, 'chat').map((app) => app.id)).toEqual(['discord'])
  })

  test('partitions the mixer into live, pinned idle, and optional hidden idle sections', () => {
    const apps = buildViewApps(
      [
        createApp({ id: 'spotify', displayName: 'Spotify', processName: 'Spotify', active: true }),
        createApp({ id: 'music', displayName: 'Music', processName: 'Music', active: false }),
        createApp({ id: 'chrome', displayName: 'Google Chrome', processName: 'Chrome', active: false }),
      ],
      ['music'],
      {},
    )

    const collapsed = partitionViewApps(apps, '', false)
    const expanded = partitionViewApps(apps, '', true)

    expect(collapsed.liveApps.map((app) => app.id)).toEqual(['spotify'])
    expect(collapsed.pinnedApps.map((app) => app.id)).toEqual(['music'])
    expect(collapsed.hiddenApps).toEqual([])
    expect(collapsed.hiddenCount).toEqual(1)
    expect(expanded.hiddenApps.map((app) => app.id)).toEqual(['chrome'])
  })

  test('reveals detected idle apps automatically when there is nothing live yet', () => {
    const apps = buildViewApps(
      [
        createApp({ id: 'chrome', displayName: 'Google Chrome', processName: 'Chrome', active: false }),
        createApp({ id: 'safari', displayName: 'Safari', processName: 'Safari', active: false }),
      ],
      [],
      {},
    )

    const sections = partitionViewApps(apps, '', false)

    expect(sections.liveApps).toEqual([])
    expect(sections.hiddenApps.map((app) => app.id)).toEqual(['chrome', 'safari'])
  })

  test('rejects placeholder process labels that should not reach the UI', () => {
    expect(
      hasValidSessionIdentity(
        createApp({
          displayName: 'Process 1044',
          processName: 'pid-1044',
        }),
      ),
    ).toEqual(false)
  })

  test('keeps pid-backed sessions when the display name is still meaningful', () => {
    expect(
      hasValidSessionIdentity(
        createApp({
          displayName: 'Helium',
          processName: 'pid-1044',
        }),
      ),
    ).toEqual(true)
  })
})
