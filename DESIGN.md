---
name: Waves
description: Native macOS per-app audio mixer with quiet Liquid Glass polish.
colors:
  night-ink: "#08101c"
  deep-graphite: "#050913"
  shadow-blue: "#03050a"
  glass-highlight: "#ffffff1f"
  glass-lowlight: "#ffffff08"
  hairline: "#ffffff17"
  signal-cyan: "#00ffff"
  warning-amber: "#ff9500"
  error-red: "#ff3b30"
typography:
  body:
    fontFamily: "SF Pro, -apple-system, BlinkMacSystemFont, system-ui, sans-serif"
    fontSize: "13px"
    fontWeight: 400
    lineHeight: 1.35
  title:
    fontFamily: "SF Pro, -apple-system, BlinkMacSystemFont, system-ui, sans-serif"
    fontSize: "15px"
    fontWeight: 600
    lineHeight: 1.25
  label:
    fontFamily: "SF Pro, -apple-system, BlinkMacSystemFont, system-ui, sans-serif"
    fontSize: "11px"
    fontWeight: 600
    lineHeight: 1.2
rounded:
  compact: "14px"
  card: "22px"
spacing:
  xs: "6px"
  sm: "10px"
  md: "14px"
  lg: "24px"
components:
  button-icon:
    backgroundColor: "{colors.glass-lowlight}"
    textColor: "{colors.signal-cyan}"
    rounded: "{rounded.compact}"
    padding: "6px"
  panel:
    backgroundColor: "{colors.glass-lowlight}"
    textColor: "{colors.glass-highlight}"
    rounded: "{rounded.card}"
    padding: "{spacing.md}"
---

# Design System: Waves

## 1. Overview

**Creative North Star: "Control Center for app audio."**

Waves should feel like a compact macOS system utility that happens to expose powerful audio routing. The interface is task-first, dense enough for repeated use, and visually quiet enough to live beside native settings, Control Center, and menu-bar extras without feeling like a web dashboard.

The current design uses a dark, layered audio-console atmosphere with cyan reserved for signal and action. Liquid Glass should come from system materials and modern SwiftUI structure first. Custom translucent surfaces are allowed only where they clarify app-specific mixer state.

**Key Characteristics:**
- Native macOS density with system fonts and standard controls.
- Restrained dark materials with one signal accent.
- Clear route-state language for visible, monitored, and managed apps.
- Slider-first interaction, with diagnostics nearby but never dominant.

## 2. Colors

The palette is restrained: tinted night neutrals carry the shell, while cyan marks active signal and recoverable control paths.

### Primary
- **Signal Cyan** (#00ffff): Use for active routing, live levels, selected controls, and recovery actions. It should stay rare enough to mean "audio is live or actionable."

### Neutral
- **Night Ink** (#08101c): Main custom backdrop when a non-system background is required.
- **Deep Graphite** (#050913): Deeper window base for contrast behind detail content.
- **Shadow Blue** (#03050a): Lowest layer only, used sparingly so the app does not become a flat black panel.
- **Glass Highlight** (#ffffff1f): Top edge and panel highlight in custom surfaces.
- **Glass Lowlight** (#ffffff08): Subtle panel fill for compact utility surfaces.
- **Hairline** (#ffffff17): Separator, border, and route-state outlines.

### Tertiary
- **Warning Amber** (#ff9500): Permission, route degradation, and recoverable warning states.
- **Error Red** (#ff3b30): Failed route, missing permission, destructive actions.

### Named Rules

**The Signal Rarity Rule.** Cyan appears only where audio state or a primary control path is live. Do not use it as decoration.

## 3. Typography

**Display Font:** SF Pro with system fallbacks.
**Body Font:** SF Pro with system fallbacks.
**Label/Mono Font:** SF Pro with system fallbacks.

**Character:** Native, compact, and legible. Waves should not use display typography, dramatic headlines, or marketing copy inside the app surface.

### Hierarchy
- **Title** (600, 15px, 1.25): Window and panel titles, selected app names, section headers that need authority.
- **Body** (400, 13px, 1.35): Mixer rows, settings descriptions, diagnostics copy, normal control labels.
- **Label** (600, 11px, 1.2): Status chips, secondary section labels, compact metadata.

### Named Rules

**The Utility Type Rule.** Type serves scanning and control. Keep row labels short, avoid paragraph blocks in the mixer, and move longer diagnostics into settings.

## 4. Elevation

Depth is primarily material-based, not shadow-based. Use system window, sidebar, toolbar, sheet, and popover materials before adding custom shadows. Custom elevation should be tonal: slight fill changes, hairline strokes, and live-level motion.

### Named Rules

**The Material First Rule.** Do not paint over a system sidebar, toolbar, or sheet just to force a custom dark surface. Let macOS provide the glass where it owns the chrome.

## 5. Components

### Buttons
- **Shape:** Native rounded rectangles or toolbar icon buttons, using the system shape for the current control size.
- **Primary:** Use system prominent styling or signal cyan tint only for recovery, save, and routing actions.
- **Hover / Focus:** Preserve macOS focus rings and keyboard discoverability. Do not replace focus with color-only feedback.
- **Icon Buttons:** Use SF Symbols, `help`, and accessibility labels for all icon-only controls.

### Chips
- **Style:** Small, semantic route-state labels with text plus icon where useful.
- **State:** Visible, monitored, managed, degraded, and failed states must be distinguishable without color alone.

### Cards / Containers
- **Corner Style:** Compact custom surfaces use 14px; larger panels use 22px only when they are genuine app-specific surfaces.
- **Background:** Prefer system materials. Use `glass-lowlight` and `hairline` only for custom mixer panels.
- **Shadow Strategy:** Avoid heavy shadows; depth comes from material, stroke, and content layering.
- **Internal Padding:** Compact utility rows use 10 to 14px. Main detail groups use 24px when they need breathing room.

### Inputs / Fields
- **Style:** Use native SwiftUI fields, search, sliders, toggles, and menus.
- **Focus:** Keep standard keyboard focus and VoiceOver semantics intact.
- **Error / Disabled:** Disabled controls should explain why the app is not manageable or which permission is missing.

### Navigation
- **Style:** `NavigationSplitView` for the main window, native `MenuBarExtra` for the compact mixer, and a dedicated `Settings` scene for preferences.
- **Behavior:** Search applies across the current app list. Presets and source filters should stay close to the mixer, not buried in a dashboard.

### Signature Component

The mixer row is the signature component. It needs app icon, app name, route state, live level, mute, gain slider, boost, pin, and enough diagnostics to explain why control is limited without crowding the primary slider.

## 6. Do's and Don'ts

### Do:
- **Do** keep the primary menu-bar panel focused on active, pinned, and recent apps.
- **Do** show visible, monitored, and managed states honestly.
- **Do** use standard macOS materials, toolbars, settings, menu commands, and keyboard shortcuts.
- **Do** reserve cyan for live audio signal, selected control, and primary route actions.
- **Do** keep diagnostic text short in the mixer and fuller in settings.

### Don't:
- **Don't** make Waves feel like a DAW, EQ suite, gamer mixer, or neon dashboard.
- **Don't** use decorative glass cards where system Liquid Glass already owns the surface.
- **Don't** hide weak routing behind optimistic UI copy.
- **Don't** add side-stripe borders, gradient text, or repeated identical marketing cards.
- **Don't** use color as the only difference between route states.
