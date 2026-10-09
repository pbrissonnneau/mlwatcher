# mlwatcher

A tiny always-available overlay for **Windows** (and Linux) that watches a self-hosted **MLflow** tracking server and
shows your runs at a glance. Built with Flutter.

- One line per run: status dot, run name, `epoch/total`, and a 2-pixel progress bar underneath.
  - 🟢 running · 🟠 running but no new metric for a while (stale, default 30 min) · 🔴 failed or killed · blue ✓ finished
- A run stays until you **right-click → Dismiss** it. **Click** a run to open it in the MLflow web UI.
  Hover for the experiment name, status and duration.
- No main window: mlwatcher lives in the **notification area** (bottom right). Left-click the icon to show/hide the
  overlay, right-click for *Settings…* and *Quit*. The icon turns red while a failure is shown or the server is
  unreachable.
- Overlay header: 📌 toggles *always on top*, `–` hides the overlay. Drag the header to move it, drag the edges to
  resize it; position, size and opacity are remembered. When runs go away the overlay shrinks to fit them (the top
  edge stays put); it grows by itself only if *Grow automatically* is on.
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
| Accept a self-signed certificate | off | for HTTPS servers with a private certificate (that host only); see [HTTPS certificates](#https-certificates) |
| Client certificate | none | for servers that require one (mutual TLS): a `.p12` / `.pfx` file, or a `.pem` holding the certificate and its key, plus its password (encrypted like the secret above); see [Client certificates](#client-certificates) |
| Experiments | all | exact names, one per line |
| Only runs of user | everyone | matches the `mlflow.user` tag |
| Epoch metric | `epoch` | metric holding the current epoch |
| Total epochs parameter | `epochs` | parameter holding the number of epochs (no bar when missing) |
| Orange after | 30 min | a running run with no new metric for this long is shown orange |
| Opacity, always on top | 90 %, on | |
| Grow automatically with the runs | off | the overlay always shrinks to fit fewer runs; with this it also grows, up to the screen height |
| Notifications | on | on failure/kill, on finish |
| Start when I log in | off | Windows: `HKCU\…\Run`; enable again if you move the folder |

## HTTPS certificates

For an `https://` server, mlwatcher checks the server certificate like a browser does. It has **no certificate file
or folder of its own**: it trusts the certificate authorities of the operating system.

- Certificate from a public authority (Let's Encrypt, DigiCert, …): nothing to do.
- Certificate from a **private (company) authority**, or **self-signed**: install the certificate in the system
  (option 1, recommended), or turn on *Accept a self-signed certificate* (option 2).

When the certificate is not trusted, the overlay shows `TLS error: …` (also in *Settings → Test connection*).

### Option 1 – install the certificate in the system (recommended)

**Which file.** For a private authority, the authority's **root certificate**; for a self-signed server, the server
certificate itself. A `.crt`, `.cer` or `.pem` file, never the private key (`.key`). Ask your server administrator,
or export it from a browser: open the MLflow URL, click the padlock, view the certificate, select the **top** of the
chain and export it. For a self-signed server, `openssl s_client -connect mlflow.lan:443 -showcerts` also works:
copy the `-----BEGIN CERTIFICATE-----` … `-----END CERTIFICATE-----` block into a `.crt` file (servers usually do
not send their root certificate, so for a private authority use the browser or ask the administrator).

**Windows** (no admin rights needed):

1. Double-click the certificate file, then **Install Certificate…**
2. Store location: **Current User**, then *Next*.
3. **Place all certificates in the following store** → *Browse…* → **Trusted Root Certification Authorities** →
   *OK* → *Next* → *Finish*.
4. Windows warns that it cannot confirm the origin of the certificate: check the thumbprint with your administrator
   if in doubt, then **Yes**.
5. **Restart mlwatcher** (right-click the tray icon → *Quit mlwatcher*, then start it again): certificates are read
   at start-up.

The same from a command prompt: `certutil -user -addstore Root C:\path\to\company-ca.crt`
(PowerShell: `Import-Certificate -FilePath C:\path\to\company-ca.crt -CertStoreLocation Cert:\CurrentUser\Root`).
To check or remove it: run `certmgr.msc` → *Trusted Root Certification Authorities* → *Certificates*.

Good to know:

- mlwatcher reads the *Trusted Root*, *Intermediate*, *Enterprise Trust* and *Personal* stores of both the current
  user and the computer, so certificates deployed by your company (group policy) already work.
- If the server does not send its intermediate certificate, also install that one, in **Intermediate Certification
  Authorities**.
- Expired certificates are ignored.

**Linux:**

```sh
# Debian, Ubuntu (the file must be PEM and end in .crt)
sudo cp company-ca.crt /usr/local/share/ca-certificates/
sudo update-ca-certificates

# Fedora, RHEL
sudo cp company-ca.crt /etc/pki/ca-trust/source/anchors/
sudo update-ca-trust
```

Then restart mlwatcher.

### Option 2 – *Accept a self-signed certificate*

In *Settings*, tick **Accept a self-signed certificate**. mlwatcher then accepts whatever certificate the configured
server presents, without checking it: only for that host name, and only over HTTPS. It is quicker, but anyone able to
intercept the network traffic could impersonate the server (and receive your password or token). Prefer option 1.

### Client certificates

Some servers also ask **you** for a certificate (mutual TLS): without a valid one, the connection is refused before
any login, and the overlay shows `TLS error: …`. The certificate is a file you get from your administrator, usually a
`.p12` or `.pfx` (certificate + private key, protected by a password).

1. Copy the file somewhere only you can read, for example in your user folder.
2. *Settings* → **Client certificate** → *Browse…* and pick the file (`.p12`, `.pfx`, or a `.pem` holding both the
   certificate and its private key).
3. Type its **Certificate password** (leave it empty if the file has none). It is stored encrypted for your user
   account, like the MLflow password.
4. **Test connection**, then *Save*.

mlwatcher reads the file when it connects: keep it where it is (if you move it, choose it again). Messages you may
see:

- `Client certificate: cannot read …`: the file was moved, renamed or is not readable.
- `Client certificate: wrong password, or not a .p12 / .pfx / .pem file with its private key`: check the password,
  and that the file contains the private key (a `.crt` / `.cer` alone is not enough).
- `TLS error: …` or `Authentication failed (HTTP 403)` with a certificate set: the server does not accept this
  certificate (expired, or not issued by the authority it expects). Ask your administrator.

**Certificate only in Windows** (in `certmgr.msc` → *Personal* → *Certificates*, not as a file): mlwatcher cannot use
it from there. Export it to a file: right-click it → *All Tasks* → *Export…* → **Yes, export the private key** →
*Personal Information Exchange (.PFX)* → choose a password → save, then pick that file in mlwatcher. If *export the
private key* is greyed out (smart card, or a key marked non-exportable), the certificate cannot be used by
mlwatcher.

The server certificate is still checked as described above: a server using a private authority also needs option 1
or option 2.

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
  `settings.json`, `state.json`, and the encrypted secrets (MLflow password or token, client certificate password).

## Platform notes

- **Windows** notifications create a Start-menu shortcut for the current user the first time (required by Windows
  for toast notifications from unpackaged apps).
- **Linux:** the tray icon needs an AppIndicator-capable panel (on GNOME, the AppIndicator extension). Wayland
  compositors may ignore *always on top* and window positioning.
