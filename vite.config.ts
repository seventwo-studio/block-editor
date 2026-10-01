import react from "@vitejs/plugin-react"
import { defineConfig } from "vite"

export default defineConfig({
  base: "/block-editor/",
  cacheDir: new URL("./.build/vite-cache", import.meta.url).pathname,
  plugins: [react()],
  optimizeDeps: { include: ["@bjorn3/browser_wasi_shim"] },
  server: { proxy: { "/relay": { target: "http://127.0.0.1:4319", rewrite: path => path.replace(/^\/relay/, "") } } },
  resolve: {
    alias: [
      {
        find: "@seventwo-studio/block-editor/react.css",
        replacement: new URL("./src/react.css", import.meta.url).pathname,
      },
      {
        find: "@seventwo-studio/block-editor/react",
        replacement: new URL(
          "./src/react.tsx",
          import.meta.url,
        ).pathname,
      },
      {
        find: "@seventwo-studio/block-editor",
        replacement: new URL("./src/index.ts", import.meta.url).pathname,
      },
    ],
  },
  root: "demo",
  build: {
    outDir: "../dist-demo",
    emptyOutDir: true,
  },
})
