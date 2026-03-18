import { invoke } from '@tauri-apps/api/core'
import type { AppAudioSession, AudioOutputSnapshot, MixerSnapshot } from '../types/waves'

type TauriWindow = Window & {
  __TAURI__?: unknown
  __TAURI_INTERNALS__?: unknown
}

function detectPlatform(): string {
  if (typeof navigator === 'undefined') {
    return 'desktop'
  }

  const userAgent = navigator.userAgent.toLowerCase()

  if (userAgent.includes('windows')) {
    return 'windows'
  }

  if (userAgent.includes('mac')) {
    return 'macos'
  }

  return 'desktop'
}

function createApp(
  id: string,
  displayName: string,
  processName: string,
  volume: number,
  peakLevel: number,
  options: Partial<AppAudioSession> = {},
): AppAudioSession {
  return {
    id,
    displayName,
    processName,
    bundleId: options.bundleId ?? null,
    category: options.category ?? 'Utility',
    volume,
    muted: options.muted ?? false,
    active: options.active ?? true,
    pinnedHint: options.pinnedHint ?? false,
    peakLevel,
    support: options.support ?? {
      controllable: true,
      reason: null,
    },
  }
}

function createBrowserSnapshot(): MixerSnapshot {
  const platform = detectPlatform()

  return {
    platform: {
      platform,
      nativeBackend: `${platform}-scaffold`,
      nativeControlReady: false,
      discoveryReady: true,
      notes: ['Running in browser fallback mode with a simulated mixer backend.'],
    },
    generatedAt: new Date().toISOString(),
    apps: [
      createApp('spotify', 'Spotify', 'Spotify.exe', 82, 0.82, {
        category: 'Music',
        pinnedHint: true,
        bundleId: 'com.spotify.client',
      }),
      createApp('discord', 'Discord', 'Discord.exe', 38, 0.36, {
        category: 'Chat',
        bundleId: 'com.hnc.Discord',
      }),
      createApp('chrome', 'Chrome', 'chrome.exe', 55, 0.61, {
        category: 'Browser',
        bundleId: 'com.google.Chrome',
      }),
      createApp('zoom', 'Zoom', 'Zoom.exe', 44, 0.43, {
        category: 'Calls',
      }),
      createApp('notion', 'Notion', 'Notion.exe', 21, 0.08, {
        category: 'Productivity',
        active: false,
      }),
    ],
  }
}

function createBrowserOutputs(): AudioOutputSnapshot {
  return {
    supported: true,
    reason: null,
    currentDeviceId: 'default-speakers',
    devices: [
      {
        id: 'default-speakers',
        name: 'MacBook Speakers',
        current: true,
      },
      {
        id: 'default-headphones',
        name: 'Headphones',
        current: false,
      },
      {
        id: 'default-display',
        name: 'Studio Display',
        current: false,
      },
    ],
  }
}

let browserSnapshot = createBrowserSnapshot()
let browserOutputs = createBrowserOutputs()

function cloneSnapshot(snapshot: MixerSnapshot): MixerSnapshot {
  return JSON.parse(JSON.stringify(snapshot)) as MixerSnapshot
}

function hasTauriRuntime(): boolean {
  if (typeof window === 'undefined') {
    return false
  }

  const candidate = window as TauriWindow
  return Boolean(candidate.__TAURI__ || candidate.__TAURI_INTERNALS__)
}

function updateBrowserSnapshot(nextApps: AppAudioSession[]): MixerSnapshot {
  browserSnapshot = {
    ...browserSnapshot,
    apps: nextApps,
    generatedAt: new Date().toISOString(),
  }

  return cloneSnapshot(browserSnapshot)
}

function pulseLevel(app: AppAudioSession, offset: number): number {
  if (!app.active || app.muted) {
    return 0.04
  }

  const swing = ((offset % 7) + 2) / 10
  return Math.min(1, Math.max(0.06, (app.volume / 100) * swing))
}

async function fallbackInvoke<T>(command: string, args: Record<string, unknown> = {}): Promise<T> {
  switch (command) {
    case 'get_mixer_snapshot':
      return cloneSnapshot(browserSnapshot) as T
    case 'refresh_sessions': {
      const refreshed = browserSnapshot.apps.map((app, index) => ({
        ...app,
        peakLevel: pulseLevel(app, index + Date.now()),
      }))
      return updateBrowserSnapshot(refreshed) as T
    }
    case 'set_app_volume': {
      const appId = String(args.appId)
      const volume = Number(args.volume)
      const nextApps = browserSnapshot.apps.map((app, index) =>
        app.id === appId
          ? {
              ...app,
              volume,
              muted: volume === 0 ? true : false,
              peakLevel: pulseLevel({ ...app, volume, muted: volume === 0 }, index + volume),
            }
          : app,
      )
      return updateBrowserSnapshot(nextApps) as T
    }
    case 'toggle_app_mute': {
      const appId = String(args.appId)
      const nextApps = browserSnapshot.apps.map((app, index) =>
        app.id === appId
          ? {
              ...app,
              muted: !app.muted,
              peakLevel: pulseLevel({ ...app, muted: !app.muted }, index),
            }
          : app,
      )
      return updateBrowserSnapshot(nextApps) as T
    }
    case 'get_output_devices':
      return JSON.parse(JSON.stringify(browserOutputs)) as T
    case 'set_output_device': {
      const deviceId = String(args.deviceId)
      browserOutputs = {
        ...browserOutputs,
        currentDeviceId: deviceId,
        devices: browserOutputs.devices.map((device) => ({
          ...device,
          current: device.id === deviceId,
        })),
      }
      return JSON.parse(JSON.stringify(browserOutputs)) as T
    }
    default:
      throw new Error(`Unsupported fallback command: ${command}`)
  }
}

async function invokeMixer<T>(command: string, args: Record<string, unknown> = {}): Promise<T> {
  if (hasTauriRuntime()) {
    return invoke<T>(command, args)
  }

  return fallbackInvoke<T>(command, args)
}

export function getMixerSnapshot(): Promise<MixerSnapshot> {
  return invokeMixer<MixerSnapshot>('get_mixer_snapshot')
}

export function refreshSessions(): Promise<MixerSnapshot> {
  return invokeMixer<MixerSnapshot>('refresh_sessions')
}

export function setAppVolume(appId: string, volume: number): Promise<MixerSnapshot> {
  return invokeMixer<MixerSnapshot>('set_app_volume', {
    appId,
    volume,
  })
}

export function toggleAppMute(appId: string): Promise<MixerSnapshot> {
  return invokeMixer<MixerSnapshot>('toggle_app_mute', {
    appId,
  })
}

export function getOutputDevices(): Promise<AudioOutputSnapshot> {
  return invokeMixer<AudioOutputSnapshot>('get_output_devices')
}

export function setOutputDevice(deviceId: string): Promise<AudioOutputSnapshot> {
  return invokeMixer<AudioOutputSnapshot>('set_output_device', {
    deviceId,
  })
}
