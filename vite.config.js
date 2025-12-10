import path from "path";
import { fileURLToPath } from "url";
import { defineConfig } from "vite";
import compression from "vite-plugin-compression2";
import { ViteMinifyPlugin } from "vite-plugin-minify";
import Sitemap from "vite-plugin-sitemap";

var __filename = fileURLToPath(import.meta.url);
var __dirname = path.dirname(__filename);

export default defineConfig({
  root: ".",
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
    Sitemap({
      hostname: "https://licenseware-collector.com",
      dynamicRoutes: ["/", "/404"],
      readable: true,
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
      input: {
        main: path.resolve(__dirname, "index.html"),
        notFound: path.resolve(__dirname, "404.html"),
      },
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
