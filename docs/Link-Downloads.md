# Link Downloads

Get downloads any http or https link. It uses up to four connections at once when the server allows it, and it can
continue a download after an interruption.

## Download a link

1. Click the link button in the toolbar, **Download a Link** at the bottom of the sidebar, or **Download a Link…** on
   the welcome screen.
2. In **URL**, paste or type the link. If the clipboard holds a link, Get fills it in for you.
3. Optionally, paste a checksum in **Checksum**.
4. Click **Download**.

The sheet's footer shows the name the file will get, or **Paste or type a link** while the field is empty. **Download**
stays off until the link is valid. A link that isn't http or https shows **Not an http(s) or magnet link**.

**Download on** appears when you have other devices. Leave it on **This Mac** to download here. See
[Download on Another Device](Download-on-Another-Device.md).

### Magnet links

The sheet accepts a magnet link, but Get can't download one yet. It says **Magnet links aren't supported yet. Open the
.torrent file instead.** Download the `.torrent` file and open that.

### A link to a .torrent file

If the link points to a `.torrent` file, Get fetches it and starts the torrent. See [Torrents](Torrents.md).

## Check the file with a checksum

If the site lists a checksum for the file, paste it in **Checksum**. Get accepts SHA-256, SHA-512, SHA-1 and MD5. Text
that isn't one of them shows **Not a SHA-256, SHA-512, SHA-1 or MD5 checksum**, and **Download** stays off.

- While the file downloads, its details say the checksum is checked when it finishes.
- When it's done, Get checks the file. Its details then show the checksum as **verified**.
- If the file doesn't match, the download fails with a red **Download failed** banner.

When you give no checksum and the server sends a digest of the file, Get checks the file against that.

## Follow a download

Select the download in the sidebar to see its details:

- **Transfer:** the state, the number of connections, the speed and how much has arrived.
- **Source:** the link and, with a checksum, its state.

## Pause and resume

Click the pause button on the download's row, in the toolbar, or Control-click the row and choose **Pause**. Click
**Resume** to continue.

Whether a download can continue from where it stopped depends on the server:

- **Continues after interruptions:** the server lets Get continue where it left off.
- **The server can't resume; restarts:** the download starts over after a pause.

## Connection trouble and Retry

If the connection drops, Get shows an orange **Connection trouble** banner and tries again on its own. When the server
answers again, the download continues and the banner goes away.

If the download fails for good, it shows a red **Download failed** banner. Click **Retry** on the banner, in the
toolbar, on the row, or in the row's menu. Get continues from where it stopped.

## Cancel

Select an active download and click **Cancel** in the toolbar. It stops, and its row stays until you quit. The part
already downloaded stays in the Downloading folder.

## Open a file while it downloads

Control-click an active single-file download and choose an app from its **Open With** row. The app opens the part that
has arrived so far. A video can play in [Player](https://github.com/v57/Player/blob/main/docs/README.md) while it
downloads.
