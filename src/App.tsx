import { useDeferredValue, useEffect, useMemo, useRef, useState } from 'react'
import { buildViewApps, partitionViewApps, type RecentActivityMap, type ViewApp, type VolumeDrafts } from './lib/apps'
import { getMixerSnapshot, getOutputDevices, refreshSessions, setAppVolume, setOutputDevice, toggleAppMute } from './lib/mixer'
import { getGlobalShortcutAction } from './lib/shortcuts'
import { applyShellMode, getShellMode, hideMainWindow } from './lib/shell'
import {
  loadOnboardingComplete,
  loadPinnedApps,
  loadShellMode,
  saveOnboardingComplete,
  savePinnedApps,
  saveShellMode,
} from './lib/storage'
import type { AppAudioSession, AudioOutputSnapshot, MixerSnapshot, ShellMode } from './types/waves'

function classNames(...names: Array<string | false | null | undefined>): string {
  return names.filter(Boolean).join(' ')
}

function describeShellMode(mode: ShellMode): string {
  return mode === 'topbar' ? 'Top bar mode' : 'Desktop app'
}

function describeSessionState(app: Pick<ViewApp, 'live' | 'muted'>): string {
  if (app.muted) {
    return 'Muted'
  }

  if (app.live) {
    return 'Live'
  }

  return 'Idle'
}

function omitRecordKey<T>(record: Record<string, T>, key: string): Record<string, T> {
  if (!(key in record)) {
    return record
  }

  const nextRecord = { ...record }
  delete nextRecord[key]
  return nextRecord
}

function formatGeneratedAt(value: string): string | null {
  if (!value || value === '0') {
    return null
  }

  const numericValue = Number(value)
  const parsed = Number.isFinite(numericValue)
    ? new Date(value.length > 10 ? numericValue : numericValue * 1000)
    : new Date(value)

  if (Number.isNaN(parsed.getTime())) {
    return null
  }

  return parsed.toLocaleTimeString([], {
    hour: 'numeric',
    minute: '2-digit',
    second: '2-digit',
  })
}

function WaveRail({ level, live, muted }: { level: number; live: boolean; muted: boolean }) {
  const bars = Array.from({ length: 12 }, (_, index) => {
    const intensity = muted ? 0.08 : Math.max(live ? 0.16 : 0.08, level * (0.5 + ((index % 4) + 1) * 0.16))
    return (
      <span
        key={index}
        className={classNames('wave-rail__bar', live && 'wave-rail__bar--live')}
        style={{
          height: `${Math.min(100, intensity * 100)}%`,
          opacity: muted ? 0.2 : live ? 0.38 + (index % 3) * 0.14 : 0.2 + (index % 4) * 0.04,
        }}
      />
    )
  })

  return <div className={classNames('wave-rail', muted && 'wave-rail--muted')}>{bars}</div>
}

function AppIcon({ label }: { label: string }) {
  const initials = label
    .split(/\s+/)
    .filter(Boolean)
    .slice(0, 2)
    .map((part) => part.charAt(0).toUpperCase())
    .join('')

  return <div className="app-icon" aria-hidden="true">{initials}</div>
}

function AppCard({
  app,
  busy,
  onPin,
  onMute,
  onVolumeChange,
}: {
  app: ViewApp
  busy: boolean
  onPin(appId: string): void
  onMute(appId: string): void
  onVolumeChange(appId: string, volume: number): void
}) {
  const stateLabel = describeSessionState(app)
  const displayedVolume = app.muted && app.displayVolume === app.volume ? 0 : app.displayVolume
  const showSupportNote = !app.support.controllable && Boolean(app.support.reason)

  return (
    <article className={classNames('app-card', !app.live && 'app-card--inactive', app.live && 'app-card--live')}>
      <div className="app-card__main">
        <div className="app-card__identity">
          <div className="app-card__media">
            <AppIcon label={app.displayName} />
            <div className="app-card__wave">
              <WaveRail level={app.peakLevel} live={app.live} muted={app.muted} />
            </div>
          </div>

          <div className="app-card__copy">
            <div className="app-card__title-row">
              <h3>{app.displayName}</h3>
              {!app.support.controllable ? <span className="status-pill status-pill--quiet">Read only</span> : null}
            </div>
          </div>
        </div>
      </div>

      <div className="app-card__slider-zone">
        <div className="slider-value-row">
          <strong className="slider-value" aria-label={`${stateLabel} volume ${displayedVolume}`}>
            {String(displayedVolume).padStart(2, '0')}
          </strong>
        </div>
        <input
          id={`slider-${app.id}`}
          type="range"
          min={0}
          max={100}
          value={app.displayVolume}
          aria-label={`${app.displayName} volume`}
          disabled={!app.support.controllable || busy}
          onChange={(event) => onVolumeChange(app.id, Number(event.target.value))}
          style={{ ['--track-fill' as string]: `${app.displayVolume}%` }}
        />
        {showSupportNote ? <div className="slider-metrics">{app.support.reason}</div> : null}
      </div>

      <div className="app-card__controls">
        <button
          type="button"
          className={classNames('control-button', app.pinned && 'control-button--active')}
          onClick={() => onPin(app.id)}
          aria-pressed={app.pinned}
        >
          {app.pinned ? 'Pinned' : 'Pin'}
        </button>

        <button
          type="button"
          className={classNames('control-button', app.muted && 'control-button--warning')}
          onClick={() => onMute(app.id)}
          disabled={!app.support.controllable || busy}
        >
          {app.muted ? 'Unmute' : 'Mute'}
        </button>
      </div>
    </article>
  )
}

function OutputControls({
  outputSnapshot,
  busy,
  onSelect,
}: {
  outputSnapshot: AudioOutputSnapshot
  busy: boolean
  onSelect(deviceId: string): void
}) {
  if (!outputSnapshot.supported) {
    return null
  }

  return (
    <label className="output-select" aria-label="Audio output device">
      <span>Output</span>
      <select
        value={outputSnapshot.currentDeviceId ?? ''}
        onChange={(event) => onSelect(event.target.value)}
        disabled={busy || outputSnapshot.devices.length === 0}
      >
        {outputSnapshot.devices.map((device) => (
          <option key={device.id} value={device.id}>
            {device.name}
          </option>
        ))}
      </select>
    </label>
  )
}

function AppSection({
  title,
  eyebrow,
  apps,
  busyAppIds,
  onPin,
  onMute,
  onVolumeChange,
}: {
  title: string
  eyebrow: string
  apps: ViewApp[]
  busyAppIds: string[]
  onPin(appId: string): void
  onMute(appId: string): void
  onVolumeChange(appId: string, volume: number): void
}) {
  if (apps.length === 0) {
    return null
  }

  return (
    <section className="panel session-panel">
      <div className="panel__header">
        <div>
          <p className="eyebrow">{eyebrow}</p>
          <h2>{title}</h2>
        </div>
        <p className="panel__summary">{apps.length} source{apps.length === 1 ? '' : 's'}</p>
      </div>

      <div className="app-list">
        {apps.map((app) => (
          <AppCard
            key={app.id}
            app={app}
            busy={busyAppIds.includes(app.id)}
            onPin={onPin}
            onMute={onMute}
            onVolumeChange={onVolumeChange}
          />
        ))}
      </div>
    </section>
  )
}

function ShellControls({
  shellMode,
  platform,
  outputSnapshot,
  busy,
  outputBusy,
  onModeChange,
  onOutputChange,
  onHideToTray,
}: {
  shellMode: ShellMode
  platform: string
  outputSnapshot: AudioOutputSnapshot
  busy: boolean
  outputBusy: boolean
  onModeChange(mode: ShellMode): void
  onOutputChange(deviceId: string): void
  onHideToTray(): void
}) {
  if (shellMode === 'topbar') {
    return (
      <div className="utility-bar">
        <OutputControls outputSnapshot={outputSnapshot} busy={outputBusy} onSelect={onOutputChange} />

        <button
          type="button"
          className="control-button"
          onClick={() => onModeChange('desktop')}
          disabled={busy}
        >
          Desktop mode
        </button>
      </div>
    )
  }

  return (
    <div className="utility-bar">
      <OutputControls outputSnapshot={outputSnapshot} busy={outputBusy} onSelect={onOutputChange} />

      <div className="mode-switch" role="group" aria-label="Shell mode">
        <button
          type="button"
          className={classNames('mode-switch__button', 'mode-switch__button--active')}
          onClick={() => onModeChange('desktop')}
          disabled={busy}
          aria-pressed
        >
          App mode
        </button>
        <button
          type="button"
          className="mode-switch__button"
          onClick={() => onModeChange('topbar')}
          disabled={busy}
          aria-pressed={false}
        >
          Top bar mode
        </button>
      </div>

      <button type="button" className="refresh-button" onClick={onHideToTray} disabled={busy}>
        {platform === 'macos' ? 'Hide window' : 'Hide to tray'}
      </button>
    </div>
  )
}

function OnboardingOverlay({
  shellMode,
  busy,
  loading,
  liveCount,
  onModeChange,
  onRefresh,
  onComplete,
  onClose,
  completed,
  panelRef,
}: {
  shellMode: ShellMode
  busy: boolean
  loading: boolean
  liveCount: number
  onModeChange(mode: ShellMode): void
  onRefresh(): void
  onComplete(): void
  onClose(): void
  completed: boolean
  panelRef(element: HTMLElement | null): void
}) {
  return (
    <div className="onboarding-overlay" role="dialog" aria-modal="true" aria-labelledby="waves-onboarding-title">
      <div className="onboarding-overlay__scrim" />

      <section ref={panelRef} className="panel onboarding-panel">
        <div className="onboarding-panel__header">
          <div>
            <p className="eyebrow">Launch guide</p>
            <h2 id="waves-onboarding-title">Get Waves ready for daily use</h2>
          </div>

          <span className={classNames('mode-pill', !completed && 'mode-pill--active')}>
            {completed ? 'Guide' : 'First launch'}
          </span>
        </div>

        <div className="onboarding-grid">
          <article className="onboarding-card">
            <p className="eyebrow">1. Confirm audio sessions</p>
            <h3>Mixer discovery</h3>
            <p>
              Waves starts by loading active sessions, then keeps your pinned apps anchored so the mixer stays stable between launches.
            </p>
            <div className="onboarding-card__meta">
              <span>{loading ? 'Checking sessions…' : `${liveCount} sessions visible`}</span>
              <button type="button" className="control-button" onClick={onRefresh} disabled={busy}>
                Refresh now
              </button>
            </div>
          </article>

          <article className="onboarding-card">
            <p className="eyebrow">2. Choose your shell</p>
            <h3>{describeShellMode(shellMode)}</h3>
            <p>
              Desktop mode gives you the full mixer surface. Top bar mode keeps Waves compact and always within reach like a native utility.
            </p>
            <div className="mode-switch" role="group" aria-label="Onboarding shell mode">
              <button
                type="button"
                className={classNames('mode-switch__button', shellMode === 'desktop' && 'mode-switch__button--active')}
                onClick={() => onModeChange('desktop')}
                disabled={busy}
                aria-pressed={shellMode === 'desktop'}
              >
                App mode
              </button>
              <button
                type="button"
                className={classNames('mode-switch__button', shellMode === 'topbar' && 'mode-switch__button--active')}
                onClick={() => onModeChange('topbar')}
                disabled={busy}
                aria-pressed={shellMode === 'topbar'}
              >
                Top bar mode
              </button>
            </div>
          </article>

          <article className="onboarding-card">
            <p className="eyebrow">3. Operate like a utility</p>
            <h3>Tray and relaunch behavior</h3>
            <p>
              Hide Waves when you want it out of the way. Reopen it from the menu bar or Dock, then reopen this guide any time from the command bar.
            </p>
            <div className="onboarding-card__stack">
              <span>Pin the apps you touch most.</span>
              <span>Use search to jump to noisy apps fast.</span>
              <span>Keep top bar mode for quick one-glance adjustments.</span>
            </div>
          </article>
        </div>

        <div className="onboarding-panel__actions">
          {completed ? (
            <button type="button" className="control-button" onClick={onClose}>
              Close guide
            </button>
          ) : null}

          <button type="button" className="refresh-button" onClick={onComplete} disabled={busy}>
            {completed ? 'Done' : 'Finish setup'}
          </button>
        </div>
      </section>
    </div>
  )
}

const emptySnapshot: MixerSnapshot = {
  platform: {
    platform: 'desktop',
    nativeBackend: 'loading',
    nativeControlReady: false,
    discoveryReady: false,
    notes: [],
  },
  apps: [],
  generatedAt: '0',
}

const emptyOutputSnapshot: AudioOutputSnapshot = {
  supported: false,
  reason: null,
  currentDeviceId: null,
  devices: [],
}

function isDocumentVisible(): boolean {
  if (typeof document === 'undefined') {
    return true
  }

  return document.visibilityState !== 'hidden'
}

function nextPresentationTickDelay(): number {
  return isDocumentVisible() ? 600 : 2000
}

function nextRefreshDelay(): number {
  return isDocumentVisible() ? 420 : 2400
}

export default function App() {
  const [snapshot, setSnapshot] = useState<MixerSnapshot>(emptySnapshot)
  const [outputSnapshot, setOutputSnapshot] = useState<AudioOutputSnapshot>(emptyOutputSnapshot)
  const [query, setQuery] = useState('')
  const deferredQuery = useDeferredValue(query)
  const [busyAppIds, setBusyAppIds] = useState<string[]>([])
  const [volumeDrafts, setVolumeDrafts] = useState<VolumeDrafts>({})
  const [recentActivity, setRecentActivity] = useState<RecentActivityMap>({})
  const [showHiddenApps, setShowHiddenApps] = useState(false)
  const [onboardingComplete, setOnboardingComplete] = useState<boolean>(() => loadOnboardingComplete())
  const [onboardingOpen, setOnboardingOpen] = useState<boolean>(() => !loadOnboardingComplete())
  const [shellMode, setShellModeState] = useState<ShellMode>(() => loadShellMode())
  const [onboardingShellMode, setOnboardingShellMode] = useState<ShellMode>(() => loadShellMode())
  const [shellBusy, setShellBusy] = useState(false)
  const [outputBusy, setOutputBusy] = useState(false)
  const [loading, setLoading] = useState(true)
  const [refreshing, setRefreshing] = useState(false)
  const [error, setError] = useState<string | null>(null)
  const [pinnedIds, setPinnedIds] = useState<string[]>(() => loadPinnedApps())
  const searchRef = useRef<HTMLInputElement | null>(null)
  const onboardingPanelRef = useRef<HTMLElement | null>(null)
  const previousFocusRef = useRef<HTMLElement | null>(null)
  const refreshActionRef = useRef<(() => void) | null>(null)
  const refreshingRef = useRef(false)
  const interactionBlockedRef = useRef(false)
  const onboardingCompleteRef = useRef(onboardingComplete)
  const outputRefreshAtRef = useRef(0)
  const volumeCommitTimersRef = useRef<Record<string, number>>({})
  const [presentationNow, setPresentationNow] = useState(() => Date.now())

  useEffect(() => {
    void (async () => {
      setError(null)

      const [snapshotResult, outputResult] = await Promise.allSettled([getMixerSnapshot(), getOutputDevices()])

      if (snapshotResult.status === 'fulfilled') {
        setSnapshot(snapshotResult.value)
      }

      if (outputResult.status === 'fulfilled') {
        setOutputSnapshot(outputResult.value)
        outputRefreshAtRef.current = Date.now()
      } else {
        setOutputSnapshot({
          supported: false,
          reason: outputResult.reason instanceof Error ? outputResult.reason.message : 'Unable to load output devices',
          currentDeviceId: null,
          devices: [],
        })
      }

      if (snapshotResult.status === 'rejected') {
        setError(snapshotResult.reason instanceof Error ? snapshotResult.reason.message : 'Unable to load mixer state')
      }

      setLoading(false)
    })()
  }, [])

  useEffect(() => {
    savePinnedApps(pinnedIds)
  }, [pinnedIds])

  useEffect(() => {
    saveShellMode(shellMode)
  }, [shellMode])

  useEffect(() => {
    saveOnboardingComplete(onboardingComplete)
  }, [onboardingComplete])

  useEffect(() => {
    onboardingCompleteRef.current = onboardingComplete
  }, [onboardingComplete])

  useEffect(() => {
    if (!onboardingOpen) {
      return
    }

    setOnboardingShellMode(shellMode)
  }, [onboardingOpen, shellMode])

  useEffect(() => {
    interactionBlockedRef.current = shellBusy || outputBusy
  }, [outputBusy, shellBusy])

  useEffect(() => {
    let timer = 0

    function schedulePresentationTick() {
      timer = window.setTimeout(() => {
        setPresentationNow(Date.now())
        schedulePresentationTick()
      }, nextPresentationTickDelay())
    }

    schedulePresentationTick()

    return () => window.clearTimeout(timer)
  }, [])

  useEffect(() => {
    const now = Date.now()

    setRecentActivity((current) => {
      const next = { ...current }

      for (const app of snapshot.apps) {
        if (app.active) {
          next[app.id] = now + 3_200
        }
      }

      for (const [appId, expiresAt] of Object.entries(next)) {
        if (expiresAt <= now) {
          delete next[appId]
        }
      }

      return next
    })
  }, [snapshot.apps])

  useEffect(() => {
    void (async () => {
      try {
        const currentShellMode = await getShellMode()
        setShellModeState(currentShellMode)
        setOnboardingShellMode(currentShellMode)
      } catch (cause) {
        setError(cause instanceof Error ? cause.message : 'Unable to read shell mode')
      }
    })()
  }, [])

  useEffect(() => {
    refreshActionRef.current = () => {
      if (interactionBlockedRef.current) {
        return
      }

      const includeOutput = Date.now() - outputRefreshAtRef.current > 5_000
      void handleRefresh({ includeOutput, silent: true })
    }
  })

  useEffect(() => {
    function handleWindowFocus() {
      refreshActionRef.current?.()
    }

    function handleVisibilityChange() {
      refreshActionRef.current?.()
    }

    let timer = 0

    function scheduleRefresh() {
      timer = window.setTimeout(() => {
        refreshActionRef.current?.()
        scheduleRefresh()
      }, nextRefreshDelay())
    }

    scheduleRefresh()

    window.addEventListener('focus', handleWindowFocus)
    document.addEventListener('visibilitychange', handleVisibilityChange)

    return () => {
      window.clearTimeout(timer)
      window.removeEventListener('focus', handleWindowFocus)
      document.removeEventListener('visibilitychange', handleVisibilityChange)
    }
  }, [])

  useEffect(() => {
    return () => {
      Object.values(volumeCommitTimersRef.current).forEach((handle) => {
        window.clearTimeout(handle)
      })
    }
  }, [])

  useEffect(() => {
    if (!onboardingOpen) {
      return
    }

    previousFocusRef.current = document.activeElement instanceof HTMLElement ? document.activeElement : null

    const panel = onboardingPanelRef.current
    const focusTimer = window.setTimeout(() => {
      const firstInteractiveElement = panel?.querySelector<HTMLElement>(
        'button:not([disabled]), [href], input:not([disabled]), select:not([disabled]), textarea:not([disabled]), [tabindex]:not([tabindex="-1"])',
      )
      firstInteractiveElement?.focus()
    }, 0)

    function handleOnboardingKeyDown(event: KeyboardEvent) {
      if (!panel) {
        return
      }

      if (event.key === 'Escape') {
        if (onboardingCompleteRef.current) {
          event.preventDefault()
          handleCloseOnboarding()
        }
        return
      }

      if (event.key !== 'Tab') {
        return
      }

      const focusableElements = Array.from(
        panel.querySelectorAll<HTMLElement>(
          'button:not([disabled]), [href], input:not([disabled]), select:not([disabled]), textarea:not([disabled]), [tabindex]:not([tabindex="-1"])',
        ),
      ).filter((element) => !element.hasAttribute('disabled') && element.tabIndex !== -1)

      if (focusableElements.length === 0) {
        return
      }

      const firstElement = focusableElements[0]
      const lastElement = focusableElements[focusableElements.length - 1]

      if (event.shiftKey && document.activeElement === firstElement) {
        event.preventDefault()
        lastElement?.focus()
      } else if (!event.shiftKey && document.activeElement === lastElement) {
        event.preventDefault()
        firstElement?.focus()
      }
    }

    document.addEventListener('keydown', handleOnboardingKeyDown)

    return () => {
      window.clearTimeout(focusTimer)
      document.removeEventListener('keydown', handleOnboardingKeyDown)
      previousFocusRef.current?.focus()
    }
  }, [onboardingOpen])

  useEffect(() => {
    function handleKeyDown(event: KeyboardEvent) {
      const target = event.target
      const inEditableField =
        target instanceof HTMLInputElement ||
        target instanceof HTMLTextAreaElement ||
        target instanceof HTMLSelectElement ||
        (target instanceof HTMLElement && target.isContentEditable)

      const action = getGlobalShortcutAction({
        ctrlKey: event.ctrlKey,
        inEditableField,
        key: event.key,
        metaKey: event.metaKey,
        onboardingOpen,
      })

      if (!action) {
        return
      }

      event.preventDefault()

      switch (action) {
        case 'focus-search':
          searchRef.current?.focus()
          searchRef.current?.select()
          return
        case 'refresh':
          void handleRefresh()
          return
        case 'open-guide':
          setOnboardingOpen(true)
          return
      }
    }

    window.addEventListener('keydown', handleKeyDown)
    return () => window.removeEventListener('keydown', handleKeyDown)
  }, [onboardingOpen])

  const baseApps = useMemo<ViewApp[]>(() => {
    return buildViewApps(snapshot.apps, pinnedIds, volumeDrafts, recentActivity, presentationNow)
  }, [pinnedIds, presentationNow, recentActivity, snapshot.apps, volumeDrafts])

  const sections = useMemo(
    () => partitionViewApps(baseApps, deferredQuery, showHiddenApps),
    [baseApps, deferredQuery, showHiddenApps],
  )

  const liveApps = sections.liveApps
  const pinnedApps = sections.pinnedApps
  const hiddenApps = sections.hiddenApps
  const hiddenCount = sections.hiddenCount
  const liveCount = liveApps.length
  const pinnedCount = pinnedApps.length
  const shownCount = liveApps.length + pinnedApps.length + hiddenApps.length
  const hasQuery = deferredQuery.trim().length > 0
  const snapshotTime = formatGeneratedAt(snapshot.generatedAt)
  const diagnostics = [...snapshot.platform.notes, ...(outputSnapshot.reason ? [`Output devices: ${outputSnapshot.reason}`] : [])]
  const shouldShowDiagnostics = !snapshot.platform.discoveryReady || Boolean(outputSnapshot.reason)

  function clearVolumeCommit(appId: string) {
    const handle = volumeCommitTimersRef.current[appId]
    if (typeof handle === 'undefined') {
      return
    }

    window.clearTimeout(handle)
    delete volumeCommitTimersRef.current[appId]
  }

  function setAppBusy(appId: string, busy: boolean) {
    setBusyAppIds((current) => {
      if (busy) {
        return current.includes(appId) ? current : [...current, appId]
      }

      return current.filter((id) => id !== appId)
    })
  }

  async function updateSnapshot(task: Promise<MixerSnapshot>, appId?: string): Promise<boolean> {
    if (appId) {
      setAppBusy(appId, true)
    }

    setError(null)

    try {
      const nextSnapshot = await task
      setSnapshot(nextSnapshot)
      return true
    } catch (cause) {
      setError(cause instanceof Error ? cause.message : 'Mixer action failed')
      return false
    } finally {
      if (appId) {
        setAppBusy(appId, false)
      }
    }
  }

  function handlePin(appId: string) {
    setPinnedIds((current) =>
      current.includes(appId) ? current.filter((id) => id !== appId) : [...current, appId],
    )
  }

  async function commitVolumeChange(appId: string, volume: number) {
    const completed = await updateSnapshot(setAppVolume(appId, volume), appId)

    setVolumeDrafts((current) => {
      if (current[appId] !== volume) {
        return current
      }

      return omitRecordKey(current, appId)
    })

    if (!completed) {
      clearVolumeCommit(appId)
    }
  }

  function handleVolumeChange(appId: string, volume: number) {
    setVolumeDrafts((current) => ({
      ...current,
      [appId]: volume,
    }))

    clearVolumeCommit(appId)
    volumeCommitTimersRef.current[appId] = window.setTimeout(() => {
      delete volumeCommitTimersRef.current[appId]
      void commitVolumeChange(appId, volume)
    }, 160)
  }

  function handleMute(appId: string) {
    clearVolumeCommit(appId)
    setVolumeDrafts((current) => omitRecordKey(current, appId))
    void updateSnapshot(toggleAppMute(appId), appId)
  }

  async function handleRefresh(options: { includeOutput?: boolean; silent?: boolean } = {}) {
    if (refreshingRef.current) {
      return
    }

    refreshingRef.current = true
    if (!options.silent) {
      setRefreshing(true)
    }

    setError(null)

    const snapshotResult = await refreshSessions()
      .then((value) => ({ status: 'fulfilled' as const, value }))
      .catch((reason) => ({ status: 'rejected' as const, reason }))

    let outputResult:
      | { status: 'fulfilled'; value: AudioOutputSnapshot }
      | { status: 'rejected'; reason: unknown }
      | null = null

    if (options.includeOutput !== false) {
      outputResult = await getOutputDevices()
        .then((value) => ({ status: 'fulfilled' as const, value }))
        .catch((reason) => ({ status: 'rejected' as const, reason }))
    }

    if (snapshotResult.status === 'fulfilled') {
      setSnapshot(snapshotResult.value)
    } else {
      setError(snapshotResult.reason instanceof Error ? snapshotResult.reason.message : 'Unable to refresh mixer sessions')
    }

    if (outputResult?.status === 'fulfilled') {
      setOutputSnapshot(outputResult.value)
      outputRefreshAtRef.current = Date.now()
    } else if (outputResult?.status === 'rejected') {
      setOutputSnapshot((current) => ({
        ...current,
        reason: outputResult.reason instanceof Error ? outputResult.reason.message : 'Unable to refresh output devices',
      }))
    }

    refreshingRef.current = false
    setRefreshing(false)
  }

  async function handleOutputChange(deviceId: string) {
    if (!deviceId || deviceId === outputSnapshot.currentDeviceId) {
      return
    }

    setOutputBusy(true)
    setError(null)

    try {
      const nextOutputSnapshot = await setOutputDevice(deviceId)
      setOutputSnapshot(nextOutputSnapshot)
      outputRefreshAtRef.current = Date.now()
    } catch (cause) {
      setError(cause instanceof Error ? cause.message : 'Unable to change output device')
    } finally {
      setOutputBusy(false)
    }
  }

  async function handleShellModeChange(nextMode: ShellMode) {
    if (nextMode === shellMode) {
      return
    }

    setShellBusy(true)
    setError(null)

    try {
      const applied = await applyShellMode(nextMode)
      setShellModeState(applied)
    } catch (cause) {
      setError(cause instanceof Error ? cause.message : 'Unable to update shell mode')
    } finally {
      setShellBusy(false)
    }
  }

  async function handleHideToTray() {
    setShellBusy(true)
    setError(null)

    try {
      await hideMainWindow()
    } catch (cause) {
      setError(cause instanceof Error ? cause.message : 'Unable to hide the Waves window')
    } finally {
      setShellBusy(false)
    }
  }

  function handleOnboardingShellModeChange(nextMode: ShellMode) {
    setOnboardingShellMode(nextMode)
  }

  async function handleCompleteOnboarding() {
    setShellBusy(true)
    setError(null)

    try {
      if (onboardingShellMode !== shellMode) {
        const applied = await applyShellMode(onboardingShellMode)
        setShellModeState(applied)
        setOnboardingShellMode(applied)
      }

      setOnboardingComplete(true)
      setOnboardingOpen(false)
    } catch (cause) {
      setError(cause instanceof Error ? cause.message : 'Unable to finish setup')
    } finally {
      setShellBusy(false)
    }
  }

  function handleCloseOnboarding() {
    setOnboardingShellMode(shellMode)
    setOnboardingOpen(false)
  }

  function handleClearDiscoveryFilters() {
    setQuery('')
    setShowHiddenApps(false)
    searchRef.current?.focus()
  }

  return (
    <main className={classNames('shell', shellMode === 'topbar' && 'shell--topbar')}>
      <div className="shell__backdrop" />

      {onboardingOpen ? (
        <OnboardingOverlay
          shellMode={onboardingShellMode}
          busy={shellBusy || refreshing}
          loading={loading}
          liveCount={liveCount}
          onModeChange={handleOnboardingShellModeChange}
          onRefresh={() => void handleRefresh()}
          onComplete={() => void handleCompleteOnboarding()}
          onClose={handleCloseOnboarding}
          completed={onboardingComplete}
          panelRef={(element) => {
            onboardingPanelRef.current = element
          }}
        />
      ) : null}

      <section className="frame">
        <section className="panel control-deck">
          <div className="control-deck__row control-deck__row--primary">
            <div className="command-bar__brand">
              <div className="hero__mark">W</div>
              <div>
                <h1>Waves</h1>
                <p>
                  {loading
                    ? 'Listening for active audio…'
                    : `${liveCount} live · ${pinnedCount} pinned${hiddenCount > 0 ? ` · ${hiddenCount} hidden idle` : ''}`}
                </p>
              </div>
            </div>

            <ShellControls
              shellMode={shellMode}
              platform={snapshot.platform.platform}
              outputSnapshot={outputSnapshot}
              busy={shellBusy}
              outputBusy={outputBusy}
              onModeChange={(nextMode) => void handleShellModeChange(nextMode)}
              onOutputChange={(deviceId) => void handleOutputChange(deviceId)}
              onHideToTray={() => void handleHideToTray()}
            />
          </div>

          <div className="control-deck__row control-deck__row--primary">
            <div className="search-box">
              <input
                id="session-search"
                ref={searchRef}
                type="search"
                value={query}
                onChange={(event) => setQuery(event.target.value)}
                placeholder="Search active or pinned apps"
                aria-label="Search audio sessions"
                name="query"
                autoComplete="off"
                spellCheck={false}
              />
            </div>

            <div className="command-bar__actions">
              {snapshotTime ? <span className="command-bar__status">Updated {snapshotTime}</span> : null}

              {hiddenCount > 0 && !hasQuery ? (
                <button type="button" className="control-button" onClick={() => setShowHiddenApps((current) => !current)}>
                  {showHiddenApps ? 'Hide idle' : `Show idle (${hiddenCount})`}
                </button>
              ) : null}

              {!onboardingComplete && shellMode !== 'topbar' ? (
                <button type="button" className="control-button" onClick={() => setOnboardingOpen(true)}>
                  Finish setup
                </button>
              ) : null}

              {hasQuery ? (
                <button type="button" className="control-button" onClick={handleClearDiscoveryFilters}>
                  Clear filters
                </button>
              ) : null}

              {shellMode !== 'topbar' ? (
                <button type="button" className="refresh-button" onClick={() => void handleRefresh()}>
                  {refreshing ? 'Refreshing…' : 'Refresh sessions'}
                </button>
              ) : null}
            </div>
          </div>

          <div className="control-deck__row control-deck__row--secondary">
            <p className="control-deck__hint">Live audio appears immediately. Pinned apps stay close when quiet.</p>
          </div>
        </section>

        {shouldShowDiagnostics && diagnostics.length > 0 ? (
          <section className="panel notes-panel" role="status" aria-live="polite">
            {diagnostics.map((note) => (
              <p key={note}>{note}</p>
            ))}
          </section>
        ) : null}

        {error ? (
          <section className="panel error-panel" role="alert" aria-live="assertive">
            {error}
          </section>
        ) : null}

        {!loading && shownCount === 0 ? (
          <section className="panel empty-panel" aria-live="polite">
            <p className="eyebrow">{hasQuery ? 'No matches' : snapshot.platform.discoveryReady ? 'No live audio yet' : 'Discovery unavailable'}</p>
            <h2>
              {hasQuery
                ? 'Nothing matches your current focus.'
                : snapshot.platform.discoveryReady
                  ? hiddenCount > 0
                    ? 'Nothing is actively playing right now.'
                    : 'Nothing is producing audio right now.'
                  : 'Waves could not read live macOS sessions.'}
            </h2>
            <p>
              {hasQuery
                ? 'Clear the search to widen the mixer view again.'
                : snapshot.platform.discoveryReady
                  ? hiddenCount > 0
                    ? 'You can reveal detected idle apps below, or start playback to bring sessions into the live surface instantly.'
                    : 'Launch audio apps and start playback. Waves will surface them as soon as macOS exposes the session.'
                  : 'Check the diagnostics above, then refresh after reopening the apps that should be audible.'}
            </p>
            {hiddenCount > 0 && !showHiddenApps && !hasQuery ? (
              <button type="button" className="refresh-button empty-panel__action" onClick={() => setShowHiddenApps(true)}>
                Show detected idle apps
              </button>
            ) : null}
            {hasQuery ? (
              <button type="button" className="refresh-button empty-panel__action" onClick={handleClearDiscoveryFilters}>
                Reset view
              </button>
            ) : null}
          </section>
        ) : null}

        <AppSection
          title="Live Now"
          eyebrow="Immediate control"
          apps={liveApps}
          busyAppIds={busyAppIds}
          onPin={handlePin}
          onMute={handleMute}
          onVolumeChange={handleVolumeChange}
        />

        <AppSection
          title="Pinned"
          eyebrow="Quiet but close"
          apps={pinnedApps}
          busyAppIds={busyAppIds}
          onPin={handlePin}
          onMute={handleMute}
          onVolumeChange={handleVolumeChange}
        />

        <AppSection
          title={hasQuery ? 'Detected Matches' : 'Other Detected'}
          eyebrow={hasQuery ? 'Search results' : 'Hidden by default'}
          apps={hiddenApps}
          busyAppIds={busyAppIds}
          onPin={handlePin}
          onMute={handleMute}
          onVolumeChange={handleVolumeChange}
        />
      </section>
    </main>
  )
}
