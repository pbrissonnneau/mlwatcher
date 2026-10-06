# mlwatcher

A tiny always-available overlay for **Windows** (and Linux) that watches a self-hosted **MLflow** tracking server and
shows your runs at a glance. Built with Flutter.

- One line per run: status dot, run name, `epoch/total`, and a 2-pixel progress bar underneath.
  - 🟢 running · 🟠 running but no new metric for a while (stale, default 30 min) · 🔴 failed or killed · ✓ finished
- A run stays until you **right-click → Dismiss** it. **Click** a run to open it in the MLflow web UI.
  Hover for the experiment name, status and duration.
- No main window: mlwatcher lives in the **notification area** (bottom right). Left-click the icon to show/hide the
  overlay, right-click for *Settings…* and *Quit*. The icon turns red while a failure is shown or the server is
  unreachable.
- Overlay header: 📌 toggles *always on top*, `–` hides the overlay. Drag the header to move it, drag the edges to
  resize it; position, size and opacity are remembered.
- Desktop notifications when a run fails / is killed / finishes (each can be turned off).
- Optional start at login (per user, no admin rights).

## What it shows

- **At start-up:** every running run, plus the failed/killed runs that started after the oldest running one.
- **Afterwards:** new running runs, and any run that ends (finished, failed or killed) stays on the list. Runs that
  start and fail between two polls are caught too.
- Shown runs and dismissed runs are remembered across restarts.
- When the server cannot be reached, the overlay shows a red warning **instead of** the runs (never stale data).

## Settings

| Setting | Default | |
|---|---|---|
| Server URL | – | e.g. `http://mlflow.lan:5000` |
| Authentication | none | username + password (HTTP basic) or token (bearer). The secret is encrypted for your Windows user (DPAPI); on Linux it is a file only you can read. |
| Accept a self-signed certificate | off | for HTTPS servers with a private certificate (that host only) |
| Experiments | all | exact names, one per line |
| Only runs of user | everyone | matches the `mlflow.user` tag |
| Epoch metric | `epoch` | metric holding the current epoch |
| Total epochs parameter | `epochs` | parameter holding the number of epochs (no bar when missing) |
| Orange after | 30 min | a running run with no new metric for this long is shown orange |
| Opacity, always on top | 90 %, on | |
| Notifications | on | on failure/kill, on finish |
| Start when I log in | off | Windows: `HKCU\…\Run`; enable again if you move the folder |

## Network

The server is polled every **2 seconds**, one round at a time (a slow answer never piles up requests):

- `runs/search` for running runs: MLflow has no way to request only some fields, so each running run comes back with
  all its params/metrics/tags, about **4–8 KB per running run** (measured on MLflow 3.16). mlwatcher keeps only the
  name, status, times, the epoch metric and the total-epochs parameter.
- `runs/search` for runs that started since the previous poll and are no longer running (almost always empty).
- `runs/get` only when a shown run stops running; `experiments/search` once a minute.

With 5 running runs that is roughly 20 KB/s.

## Building

Requires Flutter 3.47+.

```sh
flutter pub get
flutter analyze
flutter test                     # unit + widget tests
flutter build windows --release  # on Windows with Visual Studio (Desktop C++)
flutter build linux --release    # needs clang cmake ninja libgtk-3-dev libayatana-appindicator3-dev libnotify-dev
```

Integration test against a real MLflow server (creates an experiment and a few runs, use a scratch server):

```sh
mlflow server --port 5055 &
MLWATCHER_TEST_SERVER=http://127.0.0.1:5055 flutter test test/integration
```

## Windows test builds (CI)

`.github/workflows/release-windows.yml` analyses and tests on Ubuntu, builds the Windows app and publishes it as an
**AES-256 encrypted 7z archive** (file names encrypted too).

1. Once: add the repository secret `RELEASE_ARCHIVE_PASSWORD` (*Settings → Secrets and variables → Actions*).
2. Push, or run *Actions → Windows release → Run workflow*. Pushing a `v*` tag also attaches the archive to a GitHub
   Release.
3. Download the artifact from the run page, unzip the GitHub wrapper, open `mlwatcher-windows-x64-*.7z` with 7-Zip
   and your password, and run `mlwatcher.exe` (keep the folder together; no installation or admin rights needed).

## Architecture

```
lib/
  main.dart                    single instance, services, window + tray, first frame
  src/mlflow/                  REST client (experiments/search, runs/search, runs/get) and parsed models
  src/domain/run_tracker.dart  which runs are shown, transitions, dismissals (pure, tested)
  src/domain/watched_run.dart  a shown run: indicator (running/stale/finished/failed), progress, duration
  src/data/                    settings + state (JSON files), secret store (DPAPI on Windows)
  src/app/watcher_service.dart polling loop, notifications, persistence
  src/platform/                window modes + tray (shell.dart), single instance, autostart, notifications
  src/ui/                      overlay and settings views
windows/runner, linux/runner   frameless tool window (no taskbar entry), shown by Dart when configured
```

- One process, one window: the window is the overlay, and temporarily becomes the settings form.
- A second launch only brings the running overlay to the front (OS file lock + request file, no sockets).
- Data lives in `%APPDATA%\mlwatcher\mlwatcher\` (Windows) or `~/.local/share/app.mlwatcher.mlwatcher/` (Linux):
  `settings.json`, `state.json`, and the encrypted secret.

## Platform notes

- **Windows** notifications create a Start-menu shortcut for the current user the first time (required by Windows
  for toast notifications from unpackaged apps).
- **Linux:** the tray icon needs an AppIndicator-capable panel (on GNOME, the AppIndicator extension). Wayland
  compositors may ignore *always on top* and window positioning.
