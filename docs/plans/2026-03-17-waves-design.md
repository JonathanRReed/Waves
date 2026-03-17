---
title: Waves v1 design
---

# Waves

## Product

Waves is a Tauri desktop utility for per-application audio control. The first milestone focuses on a clean mixer experience: active app discovery, volume, mute, pinning, search, and strong desktop ergonomics.

## Architecture

- React and TypeScript frontend rendered inside Tauri
- Rust command layer for app state and backend orchestration
- Shared backend contract with platform-specific implementations for Windows and macOS
- Local persistence for pinned apps and presentation preferences

## UX direction

The interface follows an industrial studio utility aesthetic: compact, dark, tactile, and fast to scan. The app should feel closer to a premium audio control surface than a dashboard.

## Delivery phases

1. Tauri shell, polished UI, local persistence, and backend seam
2. Windows native audio-session backend
3. macOS native adapter with explicit capability handling
4. Tray behavior, shortcuts, and device-level expansion
