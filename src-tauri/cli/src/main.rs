// On Windows release builds, ship as a GUI-subsystem binary so launching
// `cork.exe` from a shortcut / Run dialog / Explorer doesn't flash a black
// console window. The CLI's job is a fire-and-forget spawn of Corkly.exe, so
// it never actually needs a console. Downside: `eprintln!` errors from the
// CLI go nowhere on Windows — an acceptable trade because the fatal cases
// (missing app binary, invalid path) are rare post-install and the alternative
// is a persistent console window every time the user launches from anywhere
// other than an interactive terminal. Debug / test builds stay console-
// subsystem so `cargo test` output still prints.
#![cfg_attr(all(not(debug_assertions), target_os = "windows"), windows_subsystem = "windows")]

use std::path::{Path, PathBuf};
use std::process::{Command, ExitCode, Stdio};

use clap::Parser;

/// Corkly — Kanban board for local Markdown files.
///
/// Running `cork` with no arguments opens a new empty Corkly window (the same as
/// the `File > New Window` menu). Passing a directory opens it as a workspace,
/// focusing the existing window if that workspace is already open.
#[derive(Parser)]
#[command(name = "cork", version = env!("CORK_VERSION"), about, long_about = None)]
struct Cli {
    /// Directory to open as a workspace. Omit to open a new empty window.
    path: Option<PathBuf>,
}

/// The Corkly app executable that ships next to this CLI. Launching it is how
/// the CLI reaches the app: a cold launch boots Corkly normally, and a launch
/// while Corkly is already running is intercepted by
/// `tauri-plugin-single-instance`, which forwards our argv to the live
/// instance and exits the spawned process.
///
/// Platform layout:
/// - macOS: `Corkly.app/Contents/MacOS/{cork,cork}` (siblings, Cargo package
///   name for the GUI; Homebrew Cask symlinks `cork` to `cork` on PATH)
/// - Linux: `/usr/bin/{cork,cork}` (siblings; deb postinst symlinks
///   `cork` → `cork` on PATH), AppImage-extracted equivalent
/// - Windows: **GUI and CLI live in different directories** because Windows
///   is case-insensitive and `Corkly.exe` (GUI) would collide with `cork.exe`
///   (CLI) in a shared parent. NSIS lays it out as
///   `<InstallDir>\Corkly.exe` and `<InstallDir>\bin\cork.exe`, and only the
///   `bin\` subdir is added to user PATH so `cork` on the command line
///   resolves to the CLI, not the GUI
#[cfg(target_os = "windows")]
const APP_BINARY_NAME: &str = "Corkly.exe";
#[cfg(not(target_os = "windows"))]
const APP_BINARY_NAME: &str = "cork";

fn main() -> ExitCode {
    let cli = Cli::parse();
    match run(cli.path) {
        Ok(()) => ExitCode::SUCCESS,
        Err(message) => {
            eprintln!("cork: {message}");
            ExitCode::FAILURE
        }
    }
}

fn run(path: Option<PathBuf>) -> Result<(), String> {
    // Resolve the workspace argument to an absolute, symlink-free directory
    // *before* handing it to the app. The running Corkly instance receives our
    // argv over a Unix socket with no shared working directory, so a relative
    // path would be meaningless on the other side. Validating here also lets us
    // fail fast with a terminal-friendly message instead of silently launching
    // the app to do nothing.
    let workspace = path.map(|p| resolve_workspace(&p)).transpose()?;

    let app = locate_app_binary()?;

    let mut command = Command::new(&app);
    if let Some(workspace) = &workspace {
        command.arg(workspace);
    }
    // Detach from the terminal: the CLI must return immediately rather than
    // block for the app's lifetime, and we don't want the GUI app's output on
    // the user's terminal. On a cold start the spawned process *is* the app and
    // keeps running after the CLI exits (reparented to launchd); on a warm
    // start single-instance forwards our argv and the spawned process exits on
    // its own almost immediately.
    command
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null());

    // Windows-specific: put Corkly.exe in its own process group and detach it
    // from any console the CLI might have inherited. Without this, a user who
    // launches `cork` from an interactive cmd/PowerShell would see the GUI
    // die together with the shell window because Windows delivers
    // CTRL_CLOSE_EVENT to every process sharing the same console process
    // group. `DETACHED_PROCESS` (0x08) and `CREATE_NEW_PROCESS_GROUP` (0x200)
    // are the standard flags for a launcher-pattern spawn.
    #[cfg(target_os = "windows")]
    {
        use std::os::windows::process::CommandExt;
        const DETACHED_PROCESS: u32 = 0x0000_0008;
        const CREATE_NEW_PROCESS_GROUP: u32 = 0x0000_0200;
        command.creation_flags(DETACHED_PROCESS | CREATE_NEW_PROCESS_GROUP);
    }

    command
        .spawn()
        .map_err(|e| format!("failed to launch Corkly at {}: {e}", app.display()))?;

    Ok(())
}

/// Turn a user-supplied path into the absolute, canonical directory the app
/// should open, or a human-readable error if it can't be used as a workspace.
/// `canonicalize` resolves the path against the current working directory and
/// follows symlinks, and fails outright if the path doesn't exist.
fn resolve_workspace(path: &Path) -> Result<PathBuf, String> {
    let canonical =
        std::fs::canonicalize(path).map_err(|e| format!("cannot open '{}': {e}", path.display()))?;
    if !canonical.is_dir() {
        return Err(format!("'{}' is not a directory", path.display()));
    }
    Ok(canonical)
}

/// Resolve the path of the Corkly app binary that sits next to the CLI. We
/// canonicalize our own executable path first: Homebrew exposes the CLI as a
/// `cork` symlink on `PATH`, so without resolving it we'd look for the app
/// binary in `/opt/homebrew/bin` (and `cork` there is the symlink to ourselves)
/// instead of inside the bundle's `Contents/MacOS`.
///
/// On Windows the NSIS installer moves the CLI into a `bin\` subdirectory to
/// avoid the case-insensitive filename collision between `Corkly.exe` (the GUI)
/// and `cork.exe` (the CLI). If the sibling lookup misses there, walk one
/// directory up.
fn locate_app_binary() -> Result<PathBuf, String> {
    let exe =
        std::env::current_exe().map_err(|e| format!("cannot determine the CLI's own path: {e}"))?;
    let exe = std::fs::canonicalize(&exe)
        .map_err(|e| format!("cannot resolve the CLI's own path ({}): {e}", exe.display()))?;
    let dir = exe
        .parent()
        .ok_or_else(|| "the CLI binary has no parent directory".to_string())?;

    let sibling_err = match resolve_app_binary(dir) {
        Ok(app) => return Ok(app),
        Err(e) => e,
    };

    #[cfg(target_os = "windows")]
    if let Some(parent) = dir.parent() {
        if let Ok(app) = resolve_app_binary(parent) {
            return Ok(app);
        }
    }

    Err(sibling_err)
}

/// Join `APP_BINARY_NAME` onto the CLI's directory and confirm it's a real
/// file. Split out from `locate_app_binary` so the lookup can be unit-tested
/// without depending on the test binary's own location.
fn resolve_app_binary(cli_dir: &Path) -> Result<PathBuf, String> {
    let app = cli_dir.join(APP_BINARY_NAME);
    if !app.is_file() {
        return Err(format!(
            "could not find the Corkly app binary next to the CLI (expected at {})",
            app.display()
        ));
    }
    Ok(app)
}

#[cfg(test)]
mod tests {
    use super::*;
    use tempfile::TempDir;

    #[test]
    fn resolve_workspace_accepts_an_existing_directory() {
        let tmp = TempDir::new().unwrap();
        let resolved = resolve_workspace(tmp.path()).unwrap();
        // The result is canonical, so it round-trips through canonicalize.
        assert_eq!(resolved, std::fs::canonicalize(tmp.path()).unwrap());
        assert!(resolved.is_absolute());
    }

    #[test]
    fn resolve_workspace_rejects_a_missing_path() {
        let tmp = TempDir::new().unwrap();
        let missing = tmp.path().join("does-not-exist");
        let err = resolve_workspace(&missing).unwrap_err();
        assert!(err.contains("cannot open"), "unexpected error: {err}");
    }

    #[test]
    fn resolve_workspace_rejects_a_regular_file() {
        let tmp = TempDir::new().unwrap();
        let file = tmp.path().join("note.md");
        std::fs::write(&file, "").unwrap();
        let err = resolve_workspace(&file).unwrap_err();
        assert!(err.contains("is not a directory"), "unexpected error: {err}");
    }

    #[test]
    fn resolve_app_binary_finds_a_sibling_file() {
        let tmp = TempDir::new().unwrap();
        let app = tmp.path().join(APP_BINARY_NAME);
        std::fs::write(&app, "").unwrap();
        assert_eq!(resolve_app_binary(tmp.path()).unwrap(), app);
    }

    #[test]
    fn resolve_app_binary_errors_when_sibling_is_missing() {
        let tmp = TempDir::new().unwrap();
        let err = resolve_app_binary(tmp.path()).unwrap_err();
        assert!(
            err.contains("could not find the Corkly app binary"),
            "unexpected error: {err}"
        );
    }

    #[test]
    fn resolve_app_binary_errors_when_sibling_is_a_directory() {
        // A directory named `cork` next to the CLI is not a launchable binary.
        let tmp = TempDir::new().unwrap();
        std::fs::create_dir(tmp.path().join(APP_BINARY_NAME)).unwrap();
        assert!(resolve_app_binary(tmp.path()).is_err());
    }
}
