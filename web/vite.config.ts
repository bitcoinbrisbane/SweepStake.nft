import { defineConfig } from "vite";
import react from "@vitejs/plugin-react";

// Relative asset paths, so the build works from any folder, including GitHub Pages.
export default defineConfig({ base: "./", plugins: [react()] });
