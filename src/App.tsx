import { useEffect, useMemo, useRef, useState } from 'react'
import { getMixerSnapshot, getOutputDevices, refreshSessions, setAppVolume, setOutputDevice, toggleAppMute } from './lib/mixer'
import { applyShellMode, hideMainWindow } from './lib/shell'
import {
  loadOnboardingComplete,
  loadPinnedApps,
  loadShellMode,
  saveOnboardingComplete,
  savePinnedApps,
  saveShellMode,
} from './lib/storage'
import type { AppAudioSession, AudioOutputSnapshot, MixerSnapshot, ShellMode } from './types/waves'

type ViewApp = AppAudioSession & {
  pinned: boolean
}

type QuickFilter = 'all' | 'pinned'

function classNames(...names: Array<string | false | null | undefined>): string {
  return names.filter(Boolean).join(' ')
}

function describeShellMode(mode: ShellMode): string {
  return mode === 'topbar' ? 'Top bar mode' : 'Desktop app'
}

function describeSessionState(app: AppAudioSession): string {
  if (app.muted) {
    return 'Muted'
  }

  if (app.active) {
    return 'Live'
  }

  return 'Idle'
}

function isDisplayableApp(app: AppAudioSession): boolean {
  if (!app.active || !app.support.controllable) {
    return false
  }

  const displayName = app.displayName.trim()
  const processName = app.processName.trim()

  if (!displayName || /^process\s+\d+$/i.test(displayName)) {
    return false
  }

  if (!processName || /^pid-\d+$/i.test(processName)) {
    return false
  }

  return true
}

function WaveRail({ level, muted }: { level: number; muted: boolean }) {
  const bars = Array.from({ length: 12 }, (_, index) => {
    const intensity = muted ? 0.12 : Math.max(0.18, level * (0.55 + ((index % 4) + 1) * 0.14))
    return (
      <span
        key={index}
        className="wave-rail__bar"
        style={{
          height: `${Math.min(100, intensity * 100)}%`,
          opacity: muted ? 0.26 : 0.4 + (index % 3) * 0.16,
          animationDelay: `${index * 55}ms`,
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

  return <div className="app-icon">{initials}</div>
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

  return (
    <article className={classNames('app-card', !app.active && 'app-card--inactive')}>
      <div className="app-card__main">
        <div className="app-card__identity">
          <div className="app-card__media">
            <AppIcon label={app.displayName} />
            <div className="app-card__wave">
              <WaveRail level={app.peakLevel} muted={app.muted} />
            </div>
          </div>

          <div className="app-card__copy">
            <div className="app-card__title-row">
              <h3>{app.displayName}</h3>
              <span className={classNames('status-pill', app.muted && 'status-pill--muted', !app.active && 'status-pill--idle')}>
                {stateLabel}
              </span>
              {app.pinned ? <span className="category-pill">Pinned</span> : null}
              <span className="category-pill">{app.category}</span>
            </div>
          </div>
        </div>
      </div>

      <div className="app-card__slider-zone">
        <div className="slider-label-row">
          <label className="slider-label" htmlFor={`slider-${app.id}`}>
            Level
          </label>
          <strong className="slider-value">{app.muted ? '00' : String(app.volume).padStart(2, '0')}</strong>
        </div>
        <input
          id={`slider-${app.id}`}
          type="range"
          min={0}
          max={100}
          value={app.volume}
          disabled={!app.support.controllable || busy}
          onChange={(event) => onVolumeChange(app.id, Number(event.target.value))}
          style={{ ['--track-fill' as string]: `${app.volume}%` }}
        />
        <div className="slider-metrics">
          <span>{busy ? 'Syncing changes…' : app.support.controllable ? 'Instant control' : 'Read only'}</span>
          <span>{app.active ? 'Live session' : 'Waiting for audio'}</span>
        </div>
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

function QuickFilters({
  activeFilter,
  shownCount,
  pinnedCount,
  onSelect,
}: {
  activeFilter: QuickFilter
  shownCount: number
  pinnedCount: number
  onSelect(filter: QuickFilter): void
}) {
  const options: Array<{ filter: QuickFilter; label: string; count: number }> = [
    { filter: 'all', label: 'All', count: shownCount },
    { filter: 'pinned', label: 'Pinned', count: pinnedCount },
  ]

  return (
    <div className="filter-strip" role="tablist" aria-label="Session filters">
      {options.map((option) => (
        <button
          key={option.filter}
          type="button"
          className={classNames('filter-chip', activeFilter === option.filter && 'filter-chip--active')}
          onClick={() => onSelect(option.filter)}
        >
          <span>{option.label}</span>
          <strong>{option.count}</strong>
        </button>
      ))}
    </div>
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
  apps,
  busyAppId,
  onPin,
  onMute,
  onVolumeChange,
}: {
  title: string
  apps: ViewApp[]
  busyAppId: string | null
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
          <p className="eyebrow">{title === 'Pinned' ? 'Quick access' : 'Mixer surface'}</p>
          <h2>{title}</h2>
        </div>
        <span className="panel__count">{apps.length}</span>
      </div>

      <div className="app-list">
        {apps.map((app) => (
          <AppCard
            key={app.id}
            app={app}
            busy={busyAppId === app.id}
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
  outputSnapshot,
  busy,
  outputBusy,
  onModeChange,
  onOutputChange,
  onHideToTray,
}: {
  shellMode: ShellMode
  outputSnapshot: AudioOutputSnapshot
  busy: boolean
  outputBusy: boolean
  onModeChange(mode: ShellMode): void
  onOutputChange(deviceId: string): void
  onHideToTray(): void
}) {
  return (
    <div className="utility-bar">
      <OutputControls outputSnapshot={outputSnapshot} busy={outputBusy} onSelect={onOutputChange} />

      <div className="mode-switch" role="tablist" aria-label="Shell mode">
        <button
          type="button"
          className={classNames('mode-switch__button', shellMode === 'desktop' && 'mode-switch__button--active')}
          onClick={() => onModeChange('desktop')}
          disabled={busy}
        >
          App mode
        </button>
        <button
          type="button"
          className={classNames('mode-switch__button', shellMode === 'topbar' && 'mode-switch__button--active')}
          onClick={() => onModeChange('topbar')}
          disabled={busy}
        >
          Top bar mode
        </button>
      </div>

      <button type="button" className="refresh-button" onClick={onHideToTray} disabled={busy}>
        Hide to tray
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
}) {
  return (
    <div className="onboarding-overlay" role="dialog" aria-modal="true" aria-labelledby="waves-onboarding-title">
      <div className="onboarding-overlay__scrim" />

      <section className="panel onboarding-panel">
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
            <div className="mode-switch" role="tablist" aria-label="Onboarding shell mode">
              <button
                type="button"
                className={classNames('mode-switch__button', shellMode === 'desktop' && 'mode-switch__button--active')}
                onClick={() => onModeChange('desktop')}
                disabled={busy}
              >
                App mode
              </button>
              <button
                type="button"
                className={classNames('mode-switch__button', shellMode === 'topbar' && 'mode-switch__button--active')}
                onClick={() => onModeChange('topbar')}
                disabled={busy}
              >
                Top bar mode
              </button>
            </div>
          </article>

          <article className="onboarding-card">
            <p className="eyebrow">3. Operate like a utility</p>
            <h3>Tray and relaunch behavior</h3>
            <p>
              Hide Waves to the tray when you want it out of the way. Left-click the tray icon to reopen it, and reopen this guide any time from the command bar.
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

export default function App() {
  const [snapshot, setSnapshot] = useState<MixerSnapshot>(emptySnapshot)
  const [outputSnapshot, setOutputSnapshot] = useState<AudioOutputSnapshot>(emptyOutputSnapshot)
  const [query, setQuery] = useState('')
  const [quickFilter, setQuickFilter] = useState<QuickFilter>('all')
  const [busyAppId, setBusyAppId] = useState<string | null>(null)
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

  useEffect(() => {
    void (async () => {
      try {
        const nextSnapshot = await getMixerSnapshot()
        setSnapshot(nextSnapshot)
      } catch (cause) {
        setError(cause instanceof Error ? cause.message : 'Unable to load mixer state')
      }

      try {
        const nextOutputSnapshot = await getOutputDevices()
        setOutputSnapshot(nextOutputSnapshot)
      } catch (cause) {
        setOutputSnapshot({
          supported: false,
          reason: cause instanceof Error ? cause.message : 'Unable to load output devices',
          currentDeviceId: null,
          devices: [],
        })
      } finally {
        setLoading(false)
      }
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
    if (!onboardingOpen) {
      return
    }

    setOnboardingShellMode(shellMode)
  }, [onboardingOpen, shellMode])

  useEffect(() => {
    void (async () => {
      try {
        const applied = await applyShellMode(shellMode)
        setShellModeState(applied)
      } catch (cause) {
        setError(cause instanceof Error ? cause.message : 'Unable to apply shell mode')
      }
    })()
  }, [])

  useEffect(() => {
    function handleKeyDown(event: KeyboardEvent) {
      const target = event.target
      const inEditableField =
        target instanceof HTMLInputElement ||
        target instanceof HTMLTextAreaElement ||
        target instanceof HTMLSelectElement ||
        (target instanceof HTMLElement && target.isContentEditable)

      if ((event.metaKey || event.ctrlKey) && event.key.toLowerCase() === 'k') {
        event.preventDefault()
        searchRef.current?.focus()
        searchRef.current?.select()
        return
      }

      if (!inEditableField && event.key === '/') {
        event.preventDefault()
        searchRef.current?.focus()
        return
      }

      if (!inEditableField && event.key.toLowerCase() === 'r') {
        event.preventDefault()
        void handleRefresh()
        return
      }

      if (!inEditableField && event.key === '?') {
        event.preventDefault()
        setOnboardingOpen(true)
      }
    }

    window.addEventListener('keydown', handleKeyDown)
    return () => window.removeEventListener('keydown', handleKeyDown)
  }, [refreshing, shellBusy])

  const baseApps = useMemo<ViewApp[]>(() => {
    return snapshot.apps
      .filter(isDisplayableApp)
      .map((app) => ({
        ...app,
        pinned: pinnedIds.includes(app.id) || app.pinnedHint,
      }))
      .sort((left, right) => {
        if (left.pinned !== right.pinned) {
          return left.pinned ? -1 : 1
        }

        if (left.active !== right.active) {
          return left.active ? -1 : 1
        }

        return right.peakLevel - left.peakLevel
      })
  }, [snapshot.apps, pinnedIds])

  const apps = useMemo<ViewApp[]>(() => {
    const normalizedQuery = query.trim().toLowerCase()

    return baseApps
      .filter((app) => {
        const matchesQuery =
          !normalizedQuery ||
          [app.displayName, app.processName, app.category]
            .join(' ')
            .toLowerCase()
            .includes(normalizedQuery)

        if (!matchesQuery) {
          return false
        }

        switch (quickFilter) {
          case 'pinned':
            return app.pinned
          default:
            return true
        }
      })
  }, [baseApps, query, quickFilter])

  const pinnedApps = apps.filter((app) => app.pinned)
  const activeApps = apps.filter((app) => !app.pinned)
  const liveCount = baseApps.length
  const pinnedCount = baseApps.filter((app) => app.pinned).length
  const shownCount = apps.length
  const totalCount = baseApps.length
  const hasQuery = query.trim().length > 0
  const hasFilters = hasQuery || quickFilter !== 'all'
  const diagnostics = [
    ...snapshot.platform.notes,
    ...(outputSnapshot.reason ? [`Output devices: ${outputSnapshot.reason}`] : []),
  ]

  async function updateSnapshot(task: Promise<MixerSnapshot>, appId?: string) {
    if (appId) {
      setBusyAppId(appId)
    }

    setError(null)

    try {
      const nextSnapshot = await task
      setSnapshot(nextSnapshot)
    } catch (cause) {
      setError(cause instanceof Error ? cause.message : 'Mixer action failed')
    } finally {
      if (appId) {
        setBusyAppId(null)
      }
    }
  }

  function handlePin(appId: string) {
    setPinnedIds((current) =>
      current.includes(appId) ? current.filter((id) => id !== appId) : [...current, appId],
    )
  }

  function handleVolumeChange(appId: string, volume: number) {
    void updateSnapshot(setAppVolume(appId, volume), appId)
  }

  function handleMute(appId: string) {
    void updateSnapshot(toggleAppMute(appId), appId)
  }

  async function handleRefresh() {
    setRefreshing(true)
    await updateSnapshot(refreshSessions())

    try {
      const nextOutputSnapshot = await getOutputDevices()
      setOutputSnapshot(nextOutputSnapshot)
    } catch (cause) {
      setOutputSnapshot({
        supported: false,
        reason: cause instanceof Error ? cause.message : 'Unable to refresh output devices',
        currentDeviceId: null,
        devices: [],
      })
    }

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
      setError(cause instanceof Error ? cause.message : 'Unable to hide Waves to the tray')
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
    setQuickFilter('all')
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
                  {loading ? 'Checking live apps…' : `${shownCount} live app${shownCount === 1 ? '' : 's'}`}
                  {quickFilter === 'pinned' ? ' · pinned only' : ''}
                </p>
              </div>
            </div>

            <ShellControls
              shellMode={shellMode}
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
                ref={searchRef}
                type="search"
                value={query}
                onChange={(event) => setQuery(event.target.value)}
                placeholder="Search live apps"
              />
            </div>

            <div className="command-bar__actions">
              {!onboardingComplete ? (
                <button type="button" className="control-button" onClick={() => setOnboardingOpen(true)}>
                  Finish setup
                </button>
              ) : null}

              {hasFilters ? (
                <button type="button" className="control-button" onClick={handleClearDiscoveryFilters}>
                  Clear filters
                </button>
              ) : null}

              <button type="button" className="refresh-button" onClick={() => void handleRefresh()}>
                {refreshing ? 'Refreshing…' : 'Refresh sessions'}
              </button>
            </div>
          </div>

          <div className="control-deck__row control-deck__row--secondary">
            <QuickFilters
              activeFilter={quickFilter}
              shownCount={totalCount}
              pinnedCount={pinnedCount}
              onSelect={setQuickFilter}
            />
          </div>
        </section>

        {diagnostics.length > 0 ? (
          <section className="panel notes-panel">
            {diagnostics.map((note) => (
              <p key={note}>{note}</p>
            ))}
          </section>
        ) : null}

        {error ? <section className="panel error-panel">{error}</section> : null}

        {!loading && apps.length === 0 ? (
          <section className="panel empty-panel">
            <p className="eyebrow">{hasFilters ? 'No matches' : snapshot.platform.discoveryReady ? 'No sessions found' : 'Discovery unavailable'}</p>
            <h2>
              {hasFilters
                ? 'Nothing matches your current focus.'
                : snapshot.platform.discoveryReady
                  ? 'Nothing is playing right now.'
                  : 'Waves could not read live macOS sessions.'}
            </h2>
            <p>
              {hasFilters
                ? 'Clear the search or switch filters to widen the mixer view again.'
                : snapshot.platform.discoveryReady
                  ? 'Launch audio apps and refresh. If something is already playing, check the diagnostics above.'
                  : 'Check the diagnostics above, then refresh after reopening the apps that should be audible.'}
            </p>
            {hasFilters ? (
              <button type="button" className="refresh-button empty-panel__action" onClick={handleClearDiscoveryFilters}>
                Reset view
              </button>
            ) : null}
          </section>
        ) : null}

        <AppSection
          title="Pinned"
          apps={pinnedApps}
          busyAppId={busyAppId}
          onPin={handlePin}
          onMute={handleMute}
          onVolumeChange={handleVolumeChange}
        />

        <AppSection
          title="All sessions"
          apps={activeApps}
          busyAppId={busyAppId}
          onPin={handlePin}
          onMute={handleMute}
          onVolumeChange={handleVolumeChange}
        />
      </section>
    </main>
  )
}
