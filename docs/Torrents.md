# Torrents

Get downloads torrents with its own BitTorrent engine. It downloads pieces in order, so a video can start playing
before it's complete. Get doesn't upload: it never seeds a torrent, during or after the download.

## Open a torrent

- Click **+** in the toolbar, **+** next to the **Downloading** section, or **Open a .torrent File…** on the welcome
  screen, and pick a `.torrent` file.
- Drag a `.torrent` file onto Get's window or its Dock icon.
- In Finder, Control-click the file and choose **Open With ▸ Get**.
- Download a link to a `.torrent` file. See [Link Downloads](Link-Downloads.md).

Opening a torrent that's already running doesn't add it twice. Opening one that finished in an earlier session starts
it again as a new download.

Get first checks what's already on disk (**Checking**), then downloads (**Downloading**).

## The torrent's details

Select a torrent to see its details:

- the state, the number of peers and seeds, and **Swarm** with the tracker's count of seeds and leechers;
- its files. A single-file torrent shows one row with two bars: what has arrived in order, and what has been verified.

A torrent with several files groups them in cards by folder. Files not in a folder are under **Other**, or under
**Files** when the torrent has no folders. Each card shows how many files it has, how much has arrived and the speed,
or **done** and **waiting**.

Files are listed and downloaded in natural name order, so "Episode 2" comes before "Episode 10".

## Pause a torrent, a folder or a file

- **The whole torrent:** click the pause button on its row, in the toolbar, or choose **Pause** from the row's menu.
  Choose **Resume** to continue.
- **A folder:** click the pause button on the folder's card. Every unfinished file in it pauses.
- **One file:** click the pause button on a single-file row, or Control-click a file and choose **Pause File**. Choose
  **Resume File** to continue.

## Set priorities

In a torrent with several files, you can choose which files come first.

1. Select the torrent while it's downloading or paused, and click **Priority** in the toolbar. This clears any earlier
   priorities.
2. Click files to set their priority, from 1 to 4. Files you don't pick say **Click to prioritize**; they download
   after the others.
3. Click a file again to clear its priority.
4. Click **Done**. The files keep their priorities and download first.

## Choose which files to download

Control-click a file in a running torrent:

- **Download ▸ Only This:** removes every other unfinished file. Only this file keeps downloading.
- **Download ▸ Only This and After:** keeps this file and every file after it, in order, and removes the unfinished
  files before it.

Files that have already finished stay either way.

To remove one file, pause it first, then Control-click it and choose **Remove File**. It shows as **Removed**. To get it
back while the torrent runs, choose **Restore File**.

## Open a file

Double-click a downloaded file to open it in its default app. Or Control-click it and use the **Open With** row to pick
an app or show it in Finder. Nothing opens for a file with no data yet.

## When a torrent finishes

Get moves its files from the Downloading folder into Downloads. If an identical copy is already in Downloads, Get keeps
it. If a different file with the same name is there, the torrent stays in the Downloading folder and Get says a
different file with that name already exists in Downloads.

## Cancel a torrent

Select it and click **Cancel** in the toolbar. It stops, and its row stays until you quit. The files stay in the
Downloading folder.

## What other computers see

A torrent connects to trackers and to other computers that share it. They see your IP address and which torrent you're
downloading. See [Privacy and Security](Privacy-and-Security.md).
