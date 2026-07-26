import { build } from "esbuild";

const args = process.argv.slice(2);
const entryPoint = args[0];
const outFile = args[1];
const format = args[2] || "iife";
const platform = args[3] || "browser";

if (!entryPoint || !outFile) {
  console.error("Usage: node esbuild-wrapper.mjs <entryPoint> <outFile> [format] [platform]");
  process.exit(1);
}

await build({
  entryPoints: [entryPoint],
  bundle: true,
  format,
  platform,
  outfile: outFile,
});
