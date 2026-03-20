export type GlobalShortcutAction = 'focus-search' | 'refresh' | 'open-guide' | null

export type GlobalShortcutContext = {
  ctrlKey: boolean
  inEditableField: boolean
  key: string
  metaKey: boolean
  onboardingOpen: boolean
}

export function getGlobalShortcutAction({
  ctrlKey,
  inEditableField,
  key,
  metaKey,
  onboardingOpen,
}: GlobalShortcutContext): GlobalShortcutAction {
  if (onboardingOpen) {
    return null
  }

  const normalizedKey = key.toLowerCase()

  if ((metaKey || ctrlKey) && normalizedKey === 'k') {
    return 'focus-search'
  }

  if (inEditableField) {
    return null
  }

  if (key === '/') {
    return 'focus-search'
  }

  if (normalizedKey === 'r') {
    return 'refresh'
  }

  if (key === '?') {
    return 'open-guide'
  }

  return null
}
