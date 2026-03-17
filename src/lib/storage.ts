import type { ShellMode } from '../types/waves'

const PINS_KEY = 'waves:pinned-apps'
const SHELL_MODE_KEY = 'waves:shell-mode'
const ONBOARDING_KEY = 'waves:onboarding-complete'

export function loadPinnedApps(): string[] {
  if (typeof window === 'undefined') {
    return []
  }

  try {
    const raw = window.localStorage.getItem(PINS_KEY)
    if (!raw) {
      return []
    }

    const parsed = JSON.parse(raw) as unknown
    if (!Array.isArray(parsed)) {
      return []
    }

    return parsed.filter((value): value is string => typeof value === 'string')
  } catch {
    return []
  }
}

export function savePinnedApps(ids: string[]): void {
  if (typeof window === 'undefined') {
    return
  }

  window.localStorage.setItem(PINS_KEY, JSON.stringify(ids))
}

export function loadShellMode(): ShellMode {
  if (typeof window === 'undefined') {
    return 'desktop'
  }

  const raw = window.localStorage.getItem(SHELL_MODE_KEY)
  return raw === 'topbar' ? 'topbar' : 'desktop'
}

export function saveShellMode(mode: ShellMode): void {
  if (typeof window === 'undefined') {
    return
  }

  window.localStorage.setItem(SHELL_MODE_KEY, mode)
}

export function loadOnboardingComplete(): boolean {
  if (typeof window === 'undefined') {
    return false
  }

  return window.localStorage.getItem(ONBOARDING_KEY) === 'true'
}

export function saveOnboardingComplete(value: boolean): void {
  if (typeof window === 'undefined') {
    return
  }

  window.localStorage.setItem(ONBOARDING_KEY, value ? 'true' : 'false')
}
