import { defineConfig } from 'vite'
import react from '@vitejs/plugin-react'

export default defineConfig({
  plugins: [react()],
  build: {
    outDir: 'dist',
    sourcemap: false,
  },
  server: {
    port: 5173,
    proxy: {
      // Local `npm run dev` proxies to a kind cluster (NodePort 31080 for gateway, 31180 for nginx).
      // In production both are served from the same nginx (see nginx.conf).
      '/api': { target: 'http://localhost:31080', rewrite: (p) => p.replace(/^\/api/, '') },
      '/ofrep': { target: 'http://localhost:31180' },
    },
  },
})
