<h1 align="center">Corkly</h1>

<p align="center">
<img src="./src-tauri/icons/icon.png" alt="Corkly Logo" width="200">
</p>

<p align="center">
<i>Kanban board for local Markdown files.</i><br>
<i><strong>Corklyly</strong> is a cross-platform evolved fork of the original macOS-exclusive repository, <strong>Corkly</strong>.</i>
</p>

<p align='center'>
<a href="https://github.com/koki-develop/Corkly/releases/latest"><img alt="GitHub release (latest by date)" src="https://img.shields.io/github/v/release/koki-develop/Corkly?style=flat"></a>
<a href="./LICENSE"><img src="https://img.shields.io/github/license/koki-develop/Corkly?style=flat" /></a>
<a href="https://github.com/koki-develop/Corkly/actions/workflows/ci.yml"><img alt="GitHub Workflow Status" src="https://img.shields.io/github/actions/workflow/status/koki-develop/Corkly/ci.yml?branch=main&logo=github&style=flat" /></a>
<img alt="macOS" src="https://img.shields.io/badge/platform-macOS-blue?style=flat" />
<img alt="Windows" src="https://img.shields.io/badge/platform-Windows-blue?style=flat" />
<img alt="Linux" src="https://img.shields.io/badge/platform-Linux-blue?style=flat" />
</p>

<p align="center">
<img src="./screenshots/board.png" alt="Board" width="680">
<img src="./screenshots/task.png" alt="Task" width="680">
<img src="./screenshots/settings.png" alt="Settings" width="680">
</p>

## Installation

### macOS (Homebrew)

```
brew install --cask koki-develop/tap/cork
```

To update:

```
brew update
brew upgrade koki-develop/tap/cork
```

### Windows

Download the latest `Corkly_<version>_x64-setup.exe` from the [Releases page](https://github.com/koki-develop/Corkly/releases/latest) and run it. The installer is a per-user install (no admin rights required) and adds `cork` to your `PATH`.

> **Note on SmartScreen warning:** The Windows installer is **not code-signed**, so on first launch Windows Defender SmartScreen will display _"Windows protected your PC"_. Click **More info** → **Run anyway** to proceed. This is expected — Corkly does not carry an Authenticode signature.

> **Upgrading from a previous Windows install:** Please fully uninstall your existing Corkly (Settings → Apps → Corkly → Uninstall) before running a new `setup.exe`, rather than installing directly over it. Windows installers reuse the previous version's uninstaller during an in-place upgrade, and older Corkly builds had a bug there that could corrupt your `PATH` environment variable.

### Linux

Download either `Corkly_<version>_amd64.deb` (Debian / Ubuntu) or `Corkly_<version>_amd64.AppImage` (any distro) from the [Releases page](https://github.com/koki-develop/Corkly/releases/latest).

```sh
# Debian / Ubuntu
sudo dpkg -i Corkly_<version>_amd64.deb

# AppImage
chmod +x Corkly_<version>_amd64.AppImage
./Corkly_<version>_amd64.AppImage
```

The `.deb` installer registers `cork` on your `PATH`.

## How it works

Corkly has no database. A workspace is just a folder, and every task is a plain Markdown file inside it — so your board lives entirely in version-controllable, editor-friendly text.

- **One task = one `.md` file.** The file name is the task title; the Markdown body is the task description.
- **Frontmatter holds the metadata.** `status`, `order`, `tags`, and `date` live in the YAML frontmatter at the top of each file.

```markdown
---
status: In Progress
order: 0
tags:
  - feature
  - urgent
date: 2026-06-12
---

Write the project README, including a "How it works" section.
```

Because it's all just files, you can edit tasks in any editor, grep them, and track the whole board in Git.

## CLI

Installing via Homebrew also puts a `cork` command on your `PATH`.

```sh
# Open a new window.
cork

# Open a directory as a workspace.
cork ./path/to/workspace
```

## License

[MIT](./LICENSE)
