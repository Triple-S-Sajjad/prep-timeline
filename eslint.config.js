import js from "@eslint/js";
import { defineConfig } from "eslint/config";
import tseslint from "typescript-eslint";

export default defineConfig(
  { ignores: ["**/node_modules/", "**/dist/", "**/build/", "**/.dart_tool/"] },
  {
    files: ["**/*.{ts,tsx}"],
    // strictTypeChecked bans `any` and the no-unsafe-* family (#11), and
    // requires a description on every @ts-expect-error.
    extends: [js.configs.recommended, tseslint.configs.strictTypeChecked],
    languageOptions: {
      parserOptions: { projectService: true, tsconfigRootDir: import.meta.dirname },
    },
    rules: {
      "no-console": "error", // #12
      "no-empty": "error", // #13
      "no-useless-catch": "error", // #6
    },
  },
);
