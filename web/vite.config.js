import { defineConfig } from "vite"

// /api/* (the 0x proxy) lives on the surcofi.com worker; dev and preview borrow it.
const api = { "/api": { target: "https://surcofi.com", changeOrigin: true } }

export default defineConfig({
  server: { port: 5173, strictPort: true, proxy: api },
  preview: { port: 4173, strictPort: true, proxy: api },
  // Pages: landing (/), Chirp app (/chirp), press kit (/press), /pinto, and launcher (/coins, /launch, /coin, /creator).
  build: {
    rollupOptions: {
      input: {
        main: "index.html",
        chirp: "chirp.html",
        press: "press.html",
        pinto: "pinto.html",
        coins: "coins.html",
        launch: "launch.html",
        coin: "coin.html",
        creator: "creator.html",
        stake: "stake.html",
        docs: "docs.html",
      },
    },
  },
})
