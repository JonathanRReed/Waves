import { defineConfig } from 'vite'
import react from '@vitejs/plugin-react'

const host = process.env.TAURI_DEV_HOST
const isTauriDebug = Boolean(process.env.TAURI_ENV_DEBUG)
const target = process.env.TAURI_ENV_PLATFORM === 'windows' ? 'chrome105' : 'safari13'

export default defineConfig({
  plugins: [react()],
  clearScreen: false,
  envPrefix: ['VITE_', 'TAURI_ENV_*'],
  server: {
    host: host || false,
    port: 5173,
    strictPort: true,
    hmr: host
      ? {
          protocol: 'ws',
          host,
          port: 1421,
        }
      : undefined,
    watch: {
      ignored: ['**/src-tauri/**'],
    },
  },
  build: {
    target,
    minify: isTauriDebug ? false : 'esbuild',
    sourcemap: isTauriDebug,
  },
})
