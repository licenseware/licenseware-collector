import { defineConfig } from "vite";
import compression from "vite-plugin-compression2";
import { ViteMinifyPlugin } from "vite-plugin-minify";

export default defineConfig({
  plugins: [
    ViteMinifyPlugin({
      collapseWhitespace: true,
      removeComments: true,
      removeRedundantAttributes: true,
      removeScriptTypeAttributes: true,
      removeStyleLinkTypeAttributes: true,
      useShortDoctype: true,
      minifyCSS: true,
      minifyJS: true,
    }),
    compression({
      algorithm: "gzip",
      ext: ".gz",
      threshold: 1024,
    }),
    compression({
      algorithm: "brotliCompress",
      ext: ".br",
      threshold: 1024,
    }),
  ],
  build: {
    minify: "terser",
    terserOptions: {
      compress: {
        drop_console: true,
        drop_debugger: true,
      },
    },
    sourcemap: false,
    cssMinify: true,
    rollupOptions: {
      output: {
        manualChunks: function splitVendorChunk(id) {
          if (id.includes("node_modules")) {
            return "vendor";
          }
        },
        assetFileNames: "assets/[name]-[hash][extname]",
        chunkFileNames: "assets/[name]-[hash].js",
        entryFileNames: "assets/[name]-[hash].js",
      },
    },
    chunkSizeWarningLimit: 500,
    assetsInlineLimit: 4096,
  },
  server: {
    open: true,
    port: 3000,
    strictPort: true,
  },
  preview: {
    open: true,
  },
});
