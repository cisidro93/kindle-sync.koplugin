## Kindle Sync & Library for KOReader (`kindle-sync.koplugin`)

A KOReader plugin that lets you read the books in your Kindle's native library directly in KOReader, featuring **multi-book batch background preparation** and **daily reading goal / Amazon Whispersync streak tracking**. Your books appear in a **Kindle Library** folder in the file browser — tap to read. Everything happens on-device.

**[Download latest release](https://github.com/cisidro93/kindle-sync.koplugin/releases/latest)**

### Features

- **Native Kindle Library** — browse your Kindle books in KOReader, with covers and metadata
- **Entirely on-device** — your library is prepared and cached locally; no computer or external services needed
- **Multi-Book Batch Preparation** — prepare all your books in the background with progress reporting and abort support, without needing to open them one-by-one
- **Amazon Daily Reading Goals & Whispersync Tracking** — reading progress is automatically pushed to the Kindle Reader Data Store (`.yjf` KRDS sidecar) on book close and device sleep/suspend, updating your Amazon Reading Insights streaks
- **Automatic Sidecar Bootstrapping** — brand-new books never before opened in the native Kindle reader are automatically bootstrapped with full KRDS sidecars so Whispersync tracks them immediately
- **Whispersync Cloud Nudge** — automatically signals Kindle's `com.lab126.todo` background Whispersync daemon via LIPC to sync reading goals over Wi-Fi
- **Cross-device sync** — continue the same book on Kindle, Boox Palma/Go or any KOReader device through a self-hosted server with one-code pairing and a web dashboard
- **Exact reading state sync** — switch between KOReader and the stock Kindle reader at the exact same reading position, in either direction
- **Cached for speed** — books are prepared and cached so subsequent opening is instant

### Installation

1. Download `kindle-koplugin-armv7.zip` from the [latest release](https://github.com/cisidro93/kindle-sync.koplugin/releases/latest)
2. Extract `kindle.koplugin/` to your KOReader plugins directory:
   - Kindle: `/mnt/us/koreader/plugins/`
3. Restart KOReader

### Usage

**Opening a book:**
1. Open the file browser and tap **Kindle Library**
2. Browse your books and tap to read
3. The first open takes a while — the book is prepared on-device. After that it opens instantly. A "Preparing…" message shows while this happens; large books can take several minutes on older devices.

The library can also be opened via **Menu → Tools → KindleOS → Kindle Library → Browse Kindle Library**, or bound to a gesture or profile through KOReader's Dispatcher ("Kindle Library" action).

**Syncing reading progress with the built-in Kindle reader (same device):**
1. Go to **Menu → Tools → KindleOS → Sync with Kindle reader → Sync reading state with Kindle** to enable sync (works in the file browser and inside a book)
2. Open **Sync behavior** and enable **Enable sync FROM Kindle TO KOReader** — this is off by default, and without it no sync from Kindle ever happens. Sync TO Kindle is on by default and applies silently.
3. Choose what to do when one side has newer or older progress under the **FROM/TO Kindle sync settings** entries. Each case can be set to **Always sync**, **Ask me**, or **Never**.

After that, positions sync automatically when a book opens or closes. Exact position sync works whether the book is opened from Kindle Library, KOReader Bookshelf, Collections, or History.

If both KOReader and Kindle moved independently since the last sync, you'll get a conflict prompt showing both percentages — pick **Use Kindle**, **Use KOReader**, or **Cancel** (cancel keeps both sides unchanged and asks again next time). One-sided changes follow your FROM/TO rules instead: **Always sync** applies silently, **Ask me** prompts, **Never** skips.

> **Note:** if you enable sync while a Kindle book is already open, that reading session won't write back on close. Reopen the book once so its opening state can be reconciled first.

### Cross-device sync (Kindle, Boox and other devices)

Read a chapter on your Kindle, pick up a Boox Palma or Boox Go, and continue on the same page. Progress goes through a small sync server that you run yourself (a PC, Raspberry Pi or NAS on your home network is enough).

**1. Start the server** (Python 3.8+, no extra packages):

```sh
python3 server/kindle_sync_server.py --port 8081 --data ./sync-data
# or with Docker:
docker build -t reading-sync server/
docker run -d -p 8081:8081 -v reading-sync:/data -e KSYNC_ADMIN_PASSWORD=change-me reading-sync
```

The first start prints a dashboard password if you did not set one. Open `http://<computer-ip>:8081` in a browser and sign in.

**2. Pair each device.** On the dashboard tap **Get a pairing code**. On the device, open **Menu → Tools → KindleOS → Cross-device sync → Pair this device…**, enter the server address and the 6-character code. Repeat for every Kindle or Boox that runs KOReader with this plugin.

That's it. From then on:

- Opening a book (or waking the device) jumps to the furthest place you reached on any device, with a short "Continued from Boox Palma (52%)" note.
- Closing a book, putting the device to sleep, or reading for a few minutes uploads your place.
- No Wi-Fi? The position is saved and uploaded as soon as Wi-Fi reconnects.
- If you read on two devices without syncing in between, you are asked where to continue, showing both positions. Going *backwards* (another device is behind) asks first by default.
- Books match by title and author, so the Kindle's converted copy of a KFX book and the EPUB on your Boox are recognised as the same book. When both devices have the identical file, the position is exact; otherwise it is matched by percentage.

The dashboard shows each book with its progress on every device, the paired devices (with a **Remove** button), and pairing codes. Devices that already use KOReader's built-in **Progress sync** can point it at the same server and sign in as `reader` with the dashboard password, or use **Sign in with user name and password…** in this plugin's menu for any existing KOReader sync server.

**Syncing away from home (free HTTPS with Tailscale Funnel).** Out of the box the server only answers on your home network, over plain HTTP. Do not port-forward it as is: the password and device keys would travel unencrypted. To sync anywhere without buying a domain:

1. Install [Tailscale](https://tailscale.com/download) on the computer that runs the server and sign in.
2. Run `tailscale funnel --bg 8081`. The first time, it shows a link to turn on HTTPS and Funnel for your account; open it, approve, and run the command again.
3. It prints a public address such as `https://bookpc.tail1234.ts.net`. Use that address everywhere: when pairing a Kindle or Boox, and on the dashboard.

Only the server computer needs Tailscale; the Kindle and Boox just use the HTTPS address. Devices already paired with the home address keep working at home, or pair them again with the new address to sync everywhere. To stop public access, run `tailscale funnel --bg 8081 off` (or `tailscale funnel reset`). Pick a long dashboard password, since the dashboard is now reachable from the internet.

**Xteink X4 (CrossPoint firmware).** CrossPoint has its own sync client that works with this server:

1. On the X4, open **Settings → CrossPoint Sync**. Set **Sync Server URL** to the dashboard address, **Username** to `reader` and **Password** to your dashboard password, then choose **Authenticate**.
2. Leave **Send Document Metadata** on. The server uses the title and author it sends to recognise the book you are reading on your Kindle or Boox, even when the files differ.
3. In a book, choose **Sync** from the reader menu (or put it on a button). With **Smart Sync** the X4 jumps ahead if another device is further along, and otherwise uploads its own place.

The very first sync of a book on the X4 links it to the other devices. If another device is ahead, sync once more to jump there. A device that is new to a book can never pull the shared position backwards. When the X4 and another device have the same EPUB file, positions are exact; otherwise they are matched by percentage.

> On Boox, install KOReader for Android and copy this plugin into its `plugins` folder. The Kindle-only features stay idle there; cross-device sync works the same. Boox's own NeoReader app cannot be synced: it has no plugin system and only syncs with Onyx's cloud.

### Settings

Menu location: **Menu → Tools → KindleOS**. Items are grouped into *Cross-device sync*, *Kindle Library*, *Sync with Kindle reader*, *Reading & extras* and *Settings & storage*.

| Setting | Description |
| ------- | ----------- |
| Sync reading state with Kindle | Master switch for reading-position sync (off by default) |
| Sync current book now | Pushes current reading progress to Kindle without closing the book |
| Sync all books now | Bulk-sync all eligible prepared books; disabled while a book is open |
| Prepare all unprepared books | Converts and caches all Kindle books in the background with progress reporting |
| Automatic sync on book open and close | Run sync automatically instead of only manually (on by default) |
| Automatic sync on device sleep (suspend) | Automatically flushes and syncs reading progress when the Kindle goes to sleep |
| Trigger Kindle Cloud Sync after sync | Signals Whispersync over Wi-Fi after sync to update Amazon daily goals/streaks |
| Trigger Kindle Cloud Sync now | Manually triggers Whispersync cloud sync immediately |
| Enable sync FROM Kindle TO KOReader | Pull Kindle's position into KOReader (off by default) |
| Enable sync FROM KOReader TO Kindle | Push KOReader's position to Kindle (on by default) |
| FROM / TO Kindle sync settings | Per-direction rules for newer/older progress: Always sync, Ask me, or Never |
| Virtual Library Enabled | Show the Kindle Library folder in the file browser |
| Virtual Library Folder Cover | Set a custom cover image for the folder entry |
| Clear Book Keys | Clear cached per-book keys; re-extracted when needed |
| Clear Kindle Cache | Delete all prepared books; disabled while a book is open |
| Refresh Kindle Index | Rescan the on-device library for new/removed books |

### Troubleshooting

**"This Kindle firmware cannot extract this book's access key by itself"** means the plugin could not obtain the key needed to open that DRM-protected book.

v0.0.6 supports both the legacy Kindle Java runtime (`/usr/java/bin/cvm`) and the newer Java runtime (`/usr/java/bin/java`, including Java 21 firmware) directly. If the built-in Java extraction path is unavailable or fails, the plugin can automatically fall back to a compatible native extractor from Satsuoni/Jadehawk's `kfxdedrm` tooling when installed at either of these locations:

- `/mnt/us/extensions/kfxdedrm/bin/`
- `/mnt/us/extensions/kfxdedrm-scriptlet/bin/`

The fallback is optional and is not bundled with this plugin. If a book still fails to open, include KOReader's `crash.log` when reporting the issue.

### Compatibility

> Designed for Kindle devices running KOReader alongside stock firmware. Requires a jailbroken Kindle with KOReader installed.

- Firmware 5.16.2.x and earlier (softfp) and 5.16.3+ (hardfp) are both covered by the single armv7 package
- Book access uses the Kindle's own stored credentials and normally requires no external tools
- Java 21 firmware on newer Kindle devices is supported as of v0.0.6
- A compatible `kfxdedrm` native extractor is detected automatically as a fallback when the built-in Java extraction path is unavailable or fails

### Acknowledgments

- [KFX Input and kfxlib](https://www.mobileread.com/forums/showthread.php?t=291290) by John Howell
- [Satsuoni's DeDRM fork](https://github.com/Satsuoni/DeDRM_tools)

### License

MIT License

---

## How it works

KOReader only ever sees real file paths. Browsing the Kindle Library reads the device's `cc.db` metadata with no side effects; opening a book prepares a cached, KOReader-friendly copy of that book on-device and hands the real path to KOReader's normal open flow. History, Collections, sidecars, and provider selection all work natively.

Reading-state sync is exact, not percentage-based: when a book is prepared, the helper emits a text-free position map alongside it, and the plugin translates between KOReader XPointers and native Kindle coordinates in-process, reading and writing the Kindle reader's own state store. See [AGENTS.md](AGENTS.md) for the full architecture, data flow, and design constraints.

## Building from source

No local toolchain is required — just Docker and [just](https://github.com/casey/just).
All tests run against the real KOReader runtime from the pinned [koplugin-dev](https://github.com/kaikozlov/koplugin-dev) image.

```sh
just setup     # one-time: install git hooks and pull the development image

just verify    # canonical: formatting, lint, Lua specs on real KOReader,
               # Python/Java suite, and the ARMv7 DRM hook matrix

# Focused commands
just test                               # all non-e2e Lua tests
just test-file spec/virtual_library_spec.lua   # one exact spec file
just test-python                        # Python/Java tests (also runs Java voucher contract tests)
just test-drm-hook                      # shipped crypto_hook.so under ARMv7 OpenSSL 1.1 + 3

# Product builds
just build-voucher   # rebuild the DRM voucher extractor JAR (JDK 8+)
just build           # build the self-contained ARMv7 release package
```

`just --list` shows every recipe, including `shell` (drop into the container)
and `lua` (KOReader's LuaJIT REPL).
