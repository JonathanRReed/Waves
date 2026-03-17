export type PlatformSupport = {
  platform: string
  nativeBackend: string
  nativeControlReady: boolean
  discoveryReady: boolean
  notes: string[]
}

export type ShellMode = 'desktop' | 'topbar'

export type SessionSupport = {
  controllable: boolean
  reason: string | null
}

export type AppAudioSession = {
  id: string
  displayName: string
  processName: string
  bundleId: string | null
  category: string
  volume: number
  muted: boolean
  active: boolean
  pinnedHint: boolean
  peakLevel: number
  support: SessionSupport
}

export type MixerSnapshot = {
  platform: PlatformSupport
  apps: AppAudioSession[]
  generatedAt: string
}
