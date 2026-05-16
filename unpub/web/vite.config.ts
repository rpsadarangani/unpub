import { defineConfig } from "vite";
import vue from "@vitejs/plugin-vue";
import { viteSingleFile } from "vite-plugin-singlefile";

// Build the entire SPA into a single inlined index.html so we can embed the
// whole UI as one Dart string constant served by the unpub Dart server.
export default defineConfig({
  plugins: [vue(), viteSingleFile()],
  build: {
    target: "es2020",
    cssCodeSplit: false,
    assetsInlineLimit: 100_000_000,
    chunkSizeWarningLimit: 100_000_000,
    rollupOptions: {
      output: {
        inlineDynamicImports: true,
      },
    },
    outDir: "dist",
    emptyOutDir: true,
  },
  server: {
    // `pnpm dev` proxies API calls to a locally running unpub server.
    port: 5173,
    proxy: {
      "/webapi": "http://localhost:4000",
      "/packages": "http://localhost:4000",
      "/api": "http://localhost:4000",
      "/metrics": "http://localhost:4000",
    },
  },
});
