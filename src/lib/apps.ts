import type { AppAudioSession } from '../types/waves'

export type VolumeDrafts = Record<string, number>
export type RecentActivityMap = Record<string, number>

export type ViewApp = AppAudioSession & {
  pinned: boolean
  displayVolume: number
  live: boolean
}

export type MixerSections = {
  hiddenCount: number
  hiddenApps: ViewApp[]
  liveApps: ViewApp[]
  pinnedApps: ViewApp[]
}

export function hasValidSessionIdentity(app: Pick<AppAudioSession, 'displayName' | 'processName'>): boolean {
  const displayName = app.displayName.trim()

  if (!displayName || /^process\s+\d+$/i.test(displayName)) {
    return false
  }

  if (!app.processName.trim()) {
    return false
  }

  return true
}

export function isVisibleSession(app: ViewApp): boolean {
  return hasValidSessionIdentity(app)
}

export function buildViewApps(
  apps: AppAudioSession[],
  pinnedIds: string[],
  volumeDrafts: VolumeDrafts,
  recentActivity: RecentActivityMap = {},
  now = Date.now(),
): ViewApp[] {
  return apps
    .map((app) => {
      const pinned = pinnedIds.includes(app.id) || app.pinnedHint
      const live = app.active || (recentActivity[app.id] ?? 0) > now

      return {
        ...app,
        pinned,
        displayVolume: volumeDrafts[app.id] ?? app.volume,
        live,
      }
    })
    .filter(isVisibleSession)
    .sort((left, right) => {
      if (left.live !== right.live) {
        return left.live ? -1 : 1
      }

      if (left.pinned !== right.pinned) {
        return left.pinned ? -1 : 1
      }

      if (right.peakLevel !== left.peakLevel) {
        return right.peakLevel - left.peakLevel
      }

      return left.displayName.localeCompare(right.displayName)
    })
}

export function filterViewApps(apps: ViewApp[], query: string): ViewApp[] {
  const normalizedQuery = query.trim().toLowerCase()

  return apps.filter((app) => {
    return (
      !normalizedQuery ||
      [app.displayName, app.processName, app.category]
        .join(' ')
        .toLowerCase()
        .includes(normalizedQuery)
    )
  })
}

export function partitionViewApps(apps: ViewApp[], query: string, showHidden: boolean): MixerSections {
  const filteredApps = filterViewApps(apps, query)
  const liveApps = filteredApps.filter((app) => app.live)
  const pinnedApps = filteredApps.filter((app) => !app.live && app.pinned)
  const hiddenIdleApps = filteredApps.filter((app) => !app.live && !app.pinned)

  return {
    liveApps,
    pinnedApps,
    hiddenApps: showHidden || query.trim().length > 0 ? hiddenIdleApps : [],
    hiddenCount: hiddenIdleApps.length,
  }
}
