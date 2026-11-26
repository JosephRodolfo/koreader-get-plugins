# Get Plugins

A KOReader plugin that pulls KOReader plugins from a forked [leaf-casa](https://leaf.casa)
relay that permits uploading plugins and installs them into the KOReader plugins folder.

The primary use case for me was being able to transfer books and plugins at once from one application, leaf-casa. 

This is the device-side counterpart to the forked leaf-casa's plugin-transfer support
(`.koplugin` / `.zip` uploads are tagged with `target: "plugin"`).

## What it does

1. Reads the queue for a 4-character pairing code from the reciever server.
2. Filters files flagged as plugins (`target == "plugin"`, `.koplugin`, `.zip`).
3. Downloads each archive (`GET /api/download/<key>/<id>/<filename>`).
4. Extracts it into the KOReader user plugin folder:
   `<koreader-data>/plugins/`
   - Kobo: `.adds/koreader/plugins/`
   - Kindle: `koreader/plugins/`
   - PocketBook: `applications/koreader/plugins/`
   - Android: `koreader/plugins/`

Only ever tested on Kobo however. 

5. Offers to restart KOReader so the new plugin loads.

It can do this automatically in the background (see **Auto-sync** below), so
uploading a plugin is normally all you do.

`frontend/pluginloader.lua` already scans `<koreader-data>/plugins/` as an
extra plugin path, so no root access is required.

## Auto-sync

Enabled by default once a server and pairing code are saved. Toggle it under
**Menu → More tools → Get KOReader plugins → Auto-sync while awake on Wi-Fi**.

- Checks every **45 seconds** while KOReader is awake and online.
- After **3 empty checks** it backs off to every **5 minutes**.
- Resets to the fast cadence after an install, a manual sync, resume from
  sleep, or network-up.
- Polls immediately (2 s) on **resume** and **NetworkConnected**.
- Pauses on **suspend**, **NetworkDisconnected**, and when the plugin/UI is
  closed.
- **Silent when the queue is empty.** It only shows a notification when
  something was installed, and asks **once** per session to restart KOReader.

The poll is a plain `GET /api/status/<key>`; uploads are unaffected by whether
the sender browser is still open.

## Supported archive layouts

| Layout | Example | Result |
| --- | --- | --- |
| Plugin folder(s) at root | `leafsync.koplugin/main.lua` | `plugins/leafsync.koplugin/` |
| Plugin files at archive root | `main.lua`, `_meta.lua` | `plugins/<archive-name>.koplugin/` |
| One top-level folder | `leafsync/main.lua` | `plugins/leafsync.koplugin/` |

Archives containing multiple `*.koplugin/` folders install all of them.

`main.lua` and `_meta.lua` are required; archives with path traversal
(`..`), absolute paths, symlinks, or other unsafe entries are rejected.

## Install manually (one time)

Copy the plugin folder into your KOReader plugins directory and restart:

```
cp -r getplugins.koplugin <koreader-data>/plugins/
```

Or zip the folder contents and use KOReader's built-in archive viewer:
open the archive → *Extract all files* → choose `<koreader-data>/plugins`.

## Build a `.koplugin` bundle to send through leaf-casa

```
./build.sh
```

This produces `dist/getplugins.koplugin`, a ZIP archive with `main.lua` at the
root. Upload it on the leaf-casa sender page after pairing; the Get Plugins
client will install it as `<koreader-data>/plugins/getplugins.koplugin/`.

## Usage

1. On your phone/desktop, open your leaf-casa instance and pair with the code
   shown on the e-reader.
2. Upload a `.koplugin` or `.zip` archive (leaf-casa keeps archives byte-for-byte;
   it does not convert them).
3. In KOReader: **Menu → More tools → Get KOReader plugins**.
4. Enter the relay URL (e.g. `https://leaf.casa`) and the pairing code.
5. Leave it to auto-sync, or tap **Sync plugins now**. Restart when prompted.

Only files not yet marked downloaded are installed. To reinstall, upload the
archive again (the sender creates a fresh queue entry).

## Notes

- A `Content-Disposition` download on the stock Kobo/Kindle browser can only go
  to Downloads; that is why this plugin exists. It writes directly to the
  plugins folder using KOReader's own file APIs.
- Downloads are capped by the relay's `MAX_FILE_SIZE_MB` and validated server-side.
- Existing plugin folder contents are overwritten file-by-file on upgrade; stale
  files from removed plugin modules are not pruned.
