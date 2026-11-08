import react from '@vitejs/plugin-react'
import { defineConfig } from 'vite'

// https://vite.dev/config/
export default defineConfig({
  plugins: [react()],
  // Fixed port: the docs and screenshot checks use http://localhost:5173. If it is taken, fail instead of silently moving to 5174.
  server: { port: 5173, strictPort: true },
})
