import { execFileSync } from "node:child_process";
import { chmodSync, copyFileSync, mkdirSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

// Builds the `cork` CLI and stages it as a Tauri sidecar so `tauri build` /
// `tauri dev` embed it next to the app binary. Tauri requires the binary to
// carry a `-<target-triple>` suffix (see tauri.conf.json `bundle.externalBin`),
// which it strips when bundling. On Windows the resulting binary keeps its
// `.exe` extension after the triple is dropped.
//
// Platform layout inside the bundle after Tauri strips the triple:
// - macOS: `Corkly.app/Contents/MacOS/cork`, symlinked to /usr/local/bin/cork
//   by the Homebrew Cask.
// - Windows: `<InstallDir>\cork.exe`, renamed to `cork.exe` by the NSIS
//   installer's post-install hook and the install dir is added to user PATH.
// - Linux: `/usr/bin/cork`, symlinked to `/usr/bin/cork` by the deb
//   post-install script (or launched directly out of the AppImage).

const scriptDir = dirname(fileURLToPath(import.meta.url));
const srcTauri = join(scriptDir, "..", "src-tauri");

function hostTargetTriple(): string {
  const out = execFileSync("rustc", ["-vV"], { encoding: "utf8" });
  const line = out.split("\n").find((l) => l.startsWith("host:"));
  if (!line) {
    throw new Error("could not determine host target triple from `rustc -vV`");
  }
  return line.slice("host:".length).trim();
}

function main() {
  console.log("Building cork CLI (release)...");
  execFileSync("cargo", ["build", "--release", "-p", "cork"], {
    cwd: srcTauri,
    stdio: "inherit",
  });

  const triple = hostTargetTriple();
  const exeSuffix = process.platform === "win32" ? ".exe" : "";
  const source = join(srcTauri, "target", "release", `cork${exeSuffix}`);
  const binariesDir = join(srcTauri, "binaries");
  const dest = join(binariesDir, `cork-${triple}${exeSuffix}`);

  mkdirSync(binariesDir, { recursive: true });
  copyFileSync(source, dest);
  if (process.platform !== "win32") {
    chmodSync(dest, 0o755);
  }

  console.log(`Sidecar staged: ${dest}`);
}

main();
