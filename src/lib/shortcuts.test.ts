import { describe, expect, test } from 'bun:test'
import { getGlobalShortcutAction } from './shortcuts'

describe('global shortcut routing', () => {
  test('suppresses global shortcuts while onboarding is open', () => {
    expect(
      getGlobalShortcutAction({
        ctrlKey: false,
        inEditableField: false,
        key: '/',
        metaKey: false,
        onboardingOpen: true,
      }),
    ).toEqual(null)

    expect(
      getGlobalShortcutAction({
        ctrlKey: false,
        inEditableField: false,
        key: 'r',
        metaKey: false,
        onboardingOpen: true,
      }),
    ).toEqual(null)
  })

  test('allows command-k to focus search even from non-editable contexts', () => {
    expect(
      getGlobalShortcutAction({
        ctrlKey: false,
        inEditableField: false,
        key: 'k',
        metaKey: true,
        onboardingOpen: false,
      }),
    ).toEqual('focus-search')
  })

  test('does not refresh or search while typing in editable fields', () => {
    expect(
      getGlobalShortcutAction({
        ctrlKey: false,
        inEditableField: true,
        key: 'r',
        metaKey: false,
        onboardingOpen: false,
      }),
    ).toEqual(null)

    expect(
      getGlobalShortcutAction({
        ctrlKey: false,
        inEditableField: true,
        key: '/',
        metaKey: false,
        onboardingOpen: false,
      }),
    ).toEqual(null)
  })

  test('routes slash, r, and question mark to the expected actions', () => {
    expect(
      getGlobalShortcutAction({
        ctrlKey: false,
        inEditableField: false,
        key: '/',
        metaKey: false,
        onboardingOpen: false,
      }),
    ).toEqual('focus-search')

    expect(
      getGlobalShortcutAction({
        ctrlKey: false,
        inEditableField: false,
        key: 'r',
        metaKey: false,
        onboardingOpen: false,
      }),
    ).toEqual('refresh')

    expect(
      getGlobalShortcutAction({
        ctrlKey: false,
        inEditableField: false,
        key: '?',
        metaKey: false,
        onboardingOpen: false,
      }),
    ).toEqual('open-guide')
  })
})
