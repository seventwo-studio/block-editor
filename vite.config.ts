import react from "@vitejs/plugin-react"
import { defineConfig } from "vite"

export default defineConfig({
  base: "/block-editor/",
  plugins: [react()],
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
