import { defineConfig } from 'vite'
import react from '@vitejs/plugin-react'

// Local dev only: Aspire injects the API endpoint via service discovery env vars
// (services__api__http__0). In production the app is published as an nginx
// container that reverse-proxies /api to the API (see AppHost.cs + Dockerfile),
// so this dev proxy is not used at runtime in Azure.
const apiTarget =
  process.env.services__api__https__0 ??
  process.env.services__api__http__0 ??
  'http://localhost:5180'

// APP_VERSION drives the visible web build version. AppHost passes it as a Docker
// build arg (from the `appVersion` parameter) so the deployed web image and the
// API report the same version, keeping the UI and the deployed revision in step.
const webVersion = process.env.APP_VERSION ?? 'dev'

export default defineConfig({
  plugins: [react()],
  define: {
    __WEB_VERSION__: JSON.stringify(webVersion),
  },
  server: {
    proxy: {
      '/api': {
        target: apiTarget,
        changeOrigin: true,
        secure: false,
      },
    },
  },
})
