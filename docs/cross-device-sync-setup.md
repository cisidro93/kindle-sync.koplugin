# Set up cross-device sync, step by step

This guide gets your Kindle, Boox and (optionally) Xteink X4 keeping the same place in every book, at home and away. It takes about 20 minutes.

You need:

- A computer that stays on: a desktop PC, Mac, Raspberry Pi or NAS. This runs the sync server.
- Your Kindle with KOReader and this plugin installed (see the README's **Installation** section).
- Your Boox with **KOReader for Android** installed (from the [KOReader releases page](https://github.com/koreader/koreader/releases) or F-Droid). Boox's own NeoReader app can't sync.

Both your Kindle-store books and your own EPUBs sync. When two devices have the very same file, the position is exact. When the files differ (for example, the Kindle's converted copy of a store book and an EPUB on the Boox), the book is matched by title and author and positioned by percentage.

---

## Step 1: Start the sync server

Pick one of these on the computer that stays on.

**Option A: Python (Windows, Mac, Linux, Raspberry Pi).** Python 3.8 or newer, no extra packages.

1. Download this repository (green **Code → Download ZIP** on GitHub) and unzip it.
2. Open a terminal in the unzipped folder and run:

   ```sh
   python3 server/kindle_sync_server.py --port 8081 --data ./sync-data --admin-password "pick-a-long-password"
   ```

   On Windows use `py` instead of `python3`.
3. You should see `Reading Sync server v1.0.0 listening on http://0.0.0.0:8081`. Leave the window open.

**Option B: Docker (NAS, home server).**

```sh
docker build -t reading-sync server/
docker run -d --name reading-sync --restart unless-stopped \
  -p 8081:8081 -v reading-sync:/data \
  -e KSYNC_ADMIN_PASSWORD="pick-a-long-password" reading-sync
```

`--restart unless-stopped` brings it back after a reboot.

**Check it works:** on a phone or laptop on the same Wi-Fi, open `http://<computer-ip>:8081` (for example `http://192.168.1.20:8081`) and sign in with your password. You'll see an empty **Books** list.

> Find the computer's IP: Windows `ipconfig`, Mac System Settings → Wi-Fi → Details, Linux `hostname -I`.

> Your progress lives in `sync-data/sync.sqlite3` (or the `reading-sync` Docker volume). Back that one file up now and then.

## Step 2: Make it reachable away from home (free, no domain needed)

Skip this if you only want to sync at home.

1. Install [Tailscale](https://tailscale.com/download) on the server computer and sign in (free personal plan).
2. Run:

   ```sh
   tailscale funnel --bg 8081
   ```

   The first time, it prints a link to turn on HTTPS and Funnel for your account. Open it, approve, then run the command again.
3. It prints your public address, like `https://bookpc.tail1234.ts.net`. Open it in a browser to check you see the sign-in page.

From now on, use this `https://` address instead of the home IP everywhere below. Only the server needs Tailscale; the Kindle and Boox just use the address.

The server locks a client out for 15 minutes after 10 failed sign-ins or pairing codes, but a long password is still your main protection.

## Step 3: Pair your Kindle

1. On the dashboard, tap **Get a pairing code**. A 6-character code appears, valid for 15 minutes.
2. On the Kindle, open KOReader, then **Menu → Tools → KindleOS → Cross-device sync → Pair this device…**
3. Enter the server address (the `https://….ts.net` one, or `192.168.1.20:8081` for home only) and the code.
4. You'll see "This device is now paired". Under **Device name** you can rename it, for example "Kindle".

## Step 4: Install the plugin on your Boox and pair it

1. Connect the Boox to a computer by USB (or use a file manager app on the Boox).
2. Copy the plugin folder (`kindle.koplugin`, from the same zip you used on the Kindle) into `koreader/plugins/` on the Boox's internal storage. The full path is usually `/sdcard/koreader/plugins/kindle.koplugin`.
3. Restart KOReader on the Boox. The menu is still called **KindleOS**; the Kindle-only parts stay idle on a Boox.
4. On the dashboard, tap **New pairing code** (each code works once).
5. On the Boox: **Menu → Tools → KindleOS → Cross-device sync → Pair this device…**, enter the same server address and the new code.
6. Rename it under **Device name**, for example "Boox".

> Don't also turn on KOReader's built-in **Progress sync** on the Kindle or Boox. Both would move the book when it opens.

## Step 5 (optional): Connect the Xteink X4

1. On the X4: **Settings → CrossPoint Sync**.
2. **Sync Server URL**: your server address. **Username**: `reader`. **Password**: your dashboard password. Choose **Authenticate**.
3. Leave **Send Document Metadata** on, so the X4 is matched to the same book on your other devices.
4. In a book, choose **Sync** from the reader menu.

If the X4 refuses the `https://` address, use the home address and it will sync when you're home.

## Step 6: Check that it works

1. Open a book on the Kindle, read a few pages, then close the book (or put the Kindle to sleep).
2. On the dashboard, refresh. The book appears with the Kindle's percentage.
3. Open the same book on the Boox. After a second it jumps there and shows "Continued from Kindle (…%)".

That's it. From now on:

- **Opening a book or waking the device** moves you to the furthest place you reached on any device.
- **Closing the book, sleeping the device, or reading for 5 minutes** uploads your place.
- **No Wi-Fi?** Your place is saved and uploaded when Wi-Fi comes back.
- **Read on two devices without syncing in between?** You're asked where to continue.

You can sync by hand any time with **Cross-device sync → Sync this book now**.

---

## Troubleshooting

| What you see | What to do |
|---|---|
| "That pairing code is wrong or has expired" | Codes last 15 minutes and work once. Get a new one on the dashboard. |
| "This device is no longer paired" | The device was removed on the dashboard. Pair it again with a new code. |
| "Too many failed sign-in attempts" | Wait 15 minutes. Uploads are kept and sent afterwards. |
| Can't reach the server | Check the address (include `https://` for Tailscale), that the server window or container is running, and for home addresses that the device is on the same Wi-Fi. |
| A book doesn't follow between devices | The two copies probably have different titles or authors in their metadata (for example one has a subtitle). Fix the metadata in Calibre, or open the identical file on both devices. |
| Dashboard shows a device you don't recognise | Tap **Remove** next to it. Devices that sign in with the password (X4, stock KOReader) are only locked out by restarting the server with a new `--admin-password`. |
| Moved the server or changed its address | On each device, choose **Pair again with a new code…** with the new address. |
