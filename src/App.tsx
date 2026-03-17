import { useEffect, useMemo, useRef, useState } from 'react'
import { getMixerSnapshot, refreshSessions, setAppVolume, toggleAppMute } from './lib/mixer'
import { applyShellMode, hideMainWindow } from './lib/shell'
import {
  loadOnboardingComplete,
  loadPinnedApps,
  loadShellMode,
  saveOnboardingComplete,
  savePinnedApps,
  saveShellMode,
} from './lib/storage'
import type { AppAudioSession, MixerSnapshot, ShellMode } from './types/waves'

type ViewApp = AppAudioSession & {
  pinned: boolean
}

type QuickFilter = 'all' | 'live' | 'pinned' | 'controllable'

function classNames(...names: Array<string | false | null | undefined>): string {
  return names.filter(Boolean).join(' ')
}

function formatRelativeTimestamp(value: string): string {
  const parsed = Number(value)
  if (Number.isNaN(parsed)) {
    return 'just now'
  }

  const diff = Math.max(0, Math.floor(Date.now() / 1000) - parsed)
  if (diff < 5) {
    return 'just now'
  }

  if (diff < 60) {
    return `${diff}s ago`
  }

  const minutes = Math.floor(diff / 60)
  return `${minutes}m ago`
}

function describeShellMode(mode: ShellMode): string {
  return mode === 'topbar' ? 'Top bar mode' : 'Desktop app'
}

function describeQuickFilter(filter: QuickFilter): string {
  switch (filter) {
    case 'live':
      return 'Live only'
    case 'pinned':
      return 'Pinned only'
    case 'controllable':
      return 'Ready only'
    default:
      return 'All apps'
  }
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
  return (
    <article className={classNames('app-card', !app.active && 'app-card--inactive')}>
      <div className="app-card__wave">
        <WaveRail level={app.peakLevel} muted={app.muted} />
      </div>

      <div className="app-card__main">
        <div className="app-card__identity">
          <AppIcon label={app.displayName} />
          <div>
            <div className="app-card__title-row">
              <h3>{app.displayName}</h3>
              <span className={classNames('status-pill', app.muted && 'status-pill--muted', !app.active && 'status-pill--idle')}>
                {app.muted ? 'Muted' : app.active ? 'Live' : 'Idle'}
              </span>
              <span className="category-pill">{app.category}</span>
            </div>
            <p>{app.processName}</p>
            {!app.support.controllable && app.support.reason ? (
              <span className="support-copy">{app.support.reason}</span>
            ) : null}
          </div>
        </div>

        <div className="app-card__controls">
          <button
            type="button"
            className={classNames('control-button', app.pinned && 'control-button--active')}
            onClick={() => onPin(app.id)}
            aria-pressed={app.pinned}
          >
            Pin
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
      </div>

      <div className="app-card__slider-zone">
        <label className="slider-label" htmlFor={`slider-${app.id}`}>
          Level
        </label>
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
          <span>{app.muted ? '00' : String(app.volume).padStart(2, '0')}</span>
          <span>{busy ? 'syncing' : app.support.controllable ? 'ready' : 'locked'}</span>
        </div>
      </div>
    </article>
  )
}

function QuickFilters({
  activeFilter,
  shownCount,
  liveCount,
  pinnedCount,
  controllableCount,
  onSelect,
}: {
  activeFilter: QuickFilter
  shownCount: number
  liveCount: number
  pinnedCount: number
  controllableCount: number
  onSelect(filter: QuickFilter): void
}) {
  const options: Array<{ filter: QuickFilter; label: string; count: number }> = [
    { filter: 'all', label: 'All', count: shownCount },
    { filter: 'live', label: 'Live', count: liveCount },
    { filter: 'pinned', label: 'Pinned', count: pinnedCount },
    { filter: 'controllable', label: 'Ready', count: controllableCount },
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
    <section className="panel">
      <div className="panel__header">
        <div>
          <p className="eyebrow">Mixer lane</p>
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
  busy,
  onModeChange,
  onHideToTray,
}: {
  shellMode: ShellMode
  busy: boolean
  onModeChange(mode: ShellMode): void
  onHideToTray(): void
}) {
  return (
    <section className="panel utility-bar">
      <div className="utility-bar__group">
        <div>
          <p className="eyebrow">Window shell</p>
          <h2>{describeShellMode(shellMode)}</h2>
        </div>
        <p className="utility-bar__copy">
          Keep Waves as a full app, or condense it into a slick top bar utility shape with tray access.
        </p>
      </div>

      <div className="utility-bar__group utility-bar__group--controls">
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
    </section>
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

export default function App() {
  const [snapshot, setSnapshot] = useState<MixerSnapshot>(emptySnapshot)
  const [query, setQuery] = useState('')
  const [quickFilter, setQuickFilter] = useState<QuickFilter>('all')
  const [busyAppId, setBusyAppId] = useState<string | null>(null)
  const [onboardingComplete, setOnboardingComplete] = useState<boolean>(() => loadOnboardingComplete())
  const [onboardingOpen, setOnboardingOpen] = useState<boolean>(() => !loadOnboardingComplete())
  const [shellMode, setShellModeState] = useState<ShellMode>(() => loadShellMode())
  const [shellBusy, setShellBusy] = useState(false)
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
          case 'live':
            return app.active
          case 'pinned':
            return app.pinned
          case 'controllable':
            return app.support.controllable
          default:
            return true
        }
      })
  }, [baseApps, query, quickFilter])

  const pinnedApps = apps.filter((app) => app.pinned)
  const activeApps = apps.filter((app) => !app.pinned)
  const liveCount = baseApps.filter((app) => app.active).length
  const pinnedCount = baseApps.filter((app) => app.pinned).length
  const controllableCount = baseApps.filter((app) => app.support.controllable).length
  const shownCount = apps.length
  const totalCount = baseApps.length
  const hasQuery = query.trim().length > 0
  const hasFilters = hasQuery || quickFilter !== 'all'

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
    setRefreshing(false)
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

  function handleCompleteOnboarding() {
    setOnboardingComplete(true)
    setOnboardingOpen(false)
  }

  function handleCloseOnboarding() {
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
          shellMode={shellMode}
          busy={shellBusy || refreshing}
          loading={loading}
          liveCount={liveCount}
          onModeChange={(nextMode) => void handleShellModeChange(nextMode)}
          onRefresh={() => void handleRefresh()}
          onComplete={handleCompleteOnboarding}
          onClose={handleCloseOnboarding}
          completed={onboardingComplete}
        />
      ) : null}

      <section className="frame">
        <header className="hero panel">
          <div className="hero__brand">
            <div className="hero__mark">W</div>
            <div>
              <p className="eyebrow">Per-app mixer</p>
              <div className="hero__title-row">
                <h1>Waves</h1>
                <span className={classNames('mode-pill', shellMode === 'topbar' && 'mode-pill--active')}>
                  {describeShellMode(shellMode)}
                </span>
              </div>
            </div>
          </div>

          <div className="hero__meta">
            <div className="hero-stat">
              <span>Platform</span>
              <strong>{snapshot.platform.platform}</strong>
            </div>
            <div className="hero-stat">
              <span>Backend</span>
              <strong>{snapshot.platform.nativeBackend}</strong>
            </div>
            <div className="hero-stat">
              <span>Updated</span>
              <strong>{formatRelativeTimestamp(snapshot.generatedAt)}</strong>
            </div>
          </div>
        </header>

        <section className="top-grid">
          <div className="panel summary-card">
            <p className="eyebrow">Session load</p>
            <div className="summary-card__value">{loading ? '...' : liveCount}</div>
            <p className="summary-card__copy">Active apps currently emitting audio or tracked by the mixer.</p>
          </div>

          <div className="panel summary-card">
            <p className="eyebrow">Pinned</p>
            <div className="summary-card__value">{pinnedApps.length}</div>
            <p className="summary-card__copy">Favorites stay anchored at the top for fast access.</p>
          </div>

          <div className="panel summary-card">
            <p className="eyebrow">Native path</p>
            <div className={classNames('summary-card__value', snapshot.platform.nativeControlReady && 'summary-card__value--ready')}>
              {snapshot.platform.nativeControlReady ? 'Ready' : 'Scaffolded'}
            </div>
            <p className="summary-card__copy">
              {snapshot.platform.discoveryReady
                ? 'Platform adapter is connected to the shared mixer contract.'
                : 'Discovery is not available yet on this platform.'}
            </p>
          </div>
        </section>

        <ShellControls
          shellMode={shellMode}
          busy={shellBusy}
          onModeChange={(nextMode) => void handleShellModeChange(nextMode)}
          onHideToTray={() => void handleHideToTray()}
        />

        <section className="panel command-bar">
          <div className="search-box">
            <div className="search-box__label-row">
              <span>Search</span>
              <span className="shortcut-hint">⌘K</span>
            </div>
            <input
              ref={searchRef}
              type="search"
              value={query}
              onChange={(event) => setQuery(event.target.value)}
              placeholder="Spotify, Discord, browser..."
            />
            <div className="search-box__meta">
              <span>{describeQuickFilter(quickFilter)}</span>
              <span>{shownCount} visible</span>
            </div>
          </div>

          <div className="command-bar__actions">
            <button type="button" className="control-button" onClick={() => setOnboardingOpen(true)}>
              {onboardingComplete ? 'Review guide' : 'Finish setup'}
            </button>

            {hasFilters ? (
              <button type="button" className="control-button" onClick={handleClearDiscoveryFilters}>
                Clear filters
              </button>
            ) : null}

            <button type="button" className="refresh-button" onClick={() => void handleRefresh()}>
              {refreshing ? 'Refreshing…' : 'Refresh sessions'}
            </button>
          </div>
        </section>

        <section className="panel focus-bar">
          <div className="focus-bar__group">
            <p className="eyebrow">Session focus</p>
            <QuickFilters
              activeFilter={quickFilter}
              shownCount={totalCount}
              liveCount={liveCount}
              pinnedCount={pinnedCount}
              controllableCount={controllableCount}
              onSelect={setQuickFilter}
            />
          </div>

          <div className="focus-bar__group focus-bar__group--meta">
            <div className="focus-stat">
              <span>Shortcuts</span>
              <strong>⌘K search · / jump · R refresh · ? guide</strong>
            </div>
            <div className="focus-stat">
              <span>Visible now</span>
              <strong>{shownCount} sessions</strong>
            </div>
          </div>
        </section>

        {snapshot.platform.notes.length > 0 ? (
          <section className="panel notes-panel">
            {snapshot.platform.notes.map((note) => (
              <p key={note}>{note}</p>
            ))}
          </section>
        ) : null}

        {error ? <section className="panel error-panel">{error}</section> : null}

        {!loading && apps.length === 0 ? (
          <section className="panel empty-panel">
            <p className="eyebrow">{hasFilters ? 'No matches' : 'No sessions found'}</p>
            <h2>{hasFilters ? 'Nothing matches your current focus.' : 'Nothing is playing right now.'}</h2>
            <p>
              {hasFilters
                ? 'Clear the search or switch filters to widen the mixer view again.'
                : 'Launch audio apps and refresh. Pinned apps will stay visible here once native discovery is connected.'}
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
          title="Active applications"
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
