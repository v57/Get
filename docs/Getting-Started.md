# Getting Started

## The window

Get has one window with a sidebar on the left and the selected download on the right.

- The sidebar lists your downloads in two sections: **Downloading** and **Downloaded**.
- The toolbar's title shows how many downloads you have, how many are active and the overall progress. With a
  download selected, it shows that download's name, speed, progress and time left.
- The icon next to the title shows progress as a ring: gray while paused, green when done, red when it failed.
- To hide the sidebar, click the sidebar button in the toolbar. Click it again to bring the sidebar back.

## The welcome screen

With nothing selected, Get shows its welcome screen. It has two actions:

- **Open a .torrent File…**: its files download on this Mac.
- **Download a Link…**: any http or https file, on this Mac or on another device.

Below them, **Finished Downloads** lists what has finished, newest first. Click one to open its details. With nothing
finished yet, it says **No Finished Downloads**.

## Start your first download

To download a link:

1. Copy the link.
2. Click the link button in the toolbar, or **Download a Link** at the bottom of the sidebar.
3. Get fills in the **URL** field from the clipboard. Check it, and click **Download**.

To download a torrent, click **+** in the toolbar and pick a `.torrent` file. You can also:

- drag a `.torrent` file onto the window (it shows **Drop to download**);
- drag a link from Safari onto the window;
- in Finder, Control-click a `.torrent` file and choose **Open With ▸ Get**, or drop it onto Get's icon in the Dock.

If a download can't start, Get shows **Couldn't Start Download** with the reason.

## Where files go

While a download runs, its files are in a **Downloading** folder inside your Downloads folder. When it finishes, Get
moves the files into Downloads itself and removes the empty Downloading folder. If a file with the same name is
already there, a link download is saved under a numbered name instead.

## Time left

Get learns from your earlier downloads from the same server and of the same file type. The more you download, the
sooner and closer the time-left estimate gets. A checksum check shows as its own stage, **Checking**.

## Keyboard

- **⌘N** opens a new window, and **⌘,** opens Settings.
- In the **Download a Link** sheet, **Return** downloads and **Esc** cancels.

## Settings and updates

**Get ▸ Settings…** has one pane, **Privacy**, with the **Use iCloud** switch. See
[Privacy and Security](Privacy-and-Security.md).

To update Get, choose **Get ▸ Check for Updates…**. Get checks on its own only if you turn on
**Get ▸ Check for Updates Automatically**, which is off when you install it.
