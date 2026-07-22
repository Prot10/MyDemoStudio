import { defineConfig } from 'vite'
import react from '@vitejs/plugin-react'
import tailwindcss from '@tailwindcss/vite'

/* Promo site. Built with base /MyDemoStudio/ for GitHub Pages
   (SITE_BASE=/MyDemoStudio/), plain / for local dev. */
export default defineConfig({
  base: process.env.SITE_BASE ?? '/',
  plugins: [react(), tailwindcss()],
  build: { outDir: 'dist', emptyOutDir: true },
  server: { port: 5310 },
})
