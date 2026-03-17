import { invoke } from '@tauri-apps/api/core'
import type { ShellMode } from '../types/waves'

type TauriWindow = Window & {
  __TAURI__?: unknown
  __TAURI_INTERNALS__?: unknown
}

function hasTauriRuntime(): boolean {
  if (typeof window === 'undefined') {
    return false
  }

  const candidate = window as TauriWindow
  return Boolean(candidate.__TAURI__ || candidate.__TAURI_INTERNALS__)
}

export async function applyShellMode(mode: ShellMode): Promise<ShellMode> {
  if (!hasTauriRuntime()) {
    return mode
  }

  return invoke<ShellMode>('set_shell_mode', {
    mode,
  })
}

export async function hideMainWindow(): Promise<void> {
  if (!hasTauriRuntime()) {
    return
  }

  await invoke('hide_main_window')
}

export async function showMainWindow(): Promise<void> {
  if (!hasTauriRuntime()) {
    return
  }

  await invoke('show_main_window')
}
