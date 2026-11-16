# Get user guide

Get is a download manager for the Mac. It downloads torrents with its own BitTorrent engine, written in Swift, and
plain http and https links with up to four connections, resume and checksums. With **Download on**, a link can also
download on another of your devices, such as a home server or another Mac.

## Platforms

- **Mac:** macOS 14 or later, on Apple silicon.
- **iPhone and iPad:** no app. Get runs on the Mac only.
- **Linux and Windows:** Get builds for both on v57's own SwiftUI, but these builds aren't released yet. They have no
  Settings window, and iCloud isn't available there.

## Pages

- [Getting Started](Getting-Started.md): the window, the welcome screen and your first download.
- [Link Downloads](Link-Downloads.md): http and https links, checksums, pausing and resuming.
- [Torrents](Torrents.md): .torrent files, folders, per-file choices and priorities.
- [Download on Another Device](Download-on-Another-Device.md): a link that downloads on another of your devices.
- [Managing Downloads](Managing-Downloads.md): the sidebar, search, the Trash and what Get keeps between launches.
- [Settings](Settings.md): iCloud, and where the update checks are.
- [Keyboard Shortcuts](Keyboard-Shortcuts.md): the few keys Get has.
- [Privacy and Security](Privacy-and-Security.md): what Get sends over the network, quarantine, keys and iCloud.

## Libraries

Get's engine is three Swift libraries other apps can use:

- [GetKit](GetKit.md): progress, speed and time left for a download.
- [Torrent](Torrent.md): the BitTorrent engine.
- [URLDownload](URLDownload.md): http and https downloads with several connections, resume and checksums.

## Works with other v57 apps

- [Vault](https://github.com/v57/Vault/blob/main/docs/README.md) keeps the list of your devices. **Download on** lists
  the devices your vault knows: your Hub devices and the Macs that let your devices in. Get signs in to them with its
  own key, which you allow per Mac in **Vault ▸ Settings ▸ Remote**.
- [Hub](https://github.com/v57/hub-app/blob/main/docs/README.md) devices can be download targets. Get reaches them over
  SSH through your Hub.
- [Player](https://github.com/v57/Player/blob/main/docs/README.md) can play a video while Get is still downloading
  it. Get downloads a torrent's pieces in order, so the start of the file arrives first.

## Network

Get contacts a server only for a download you started, an update check you asked for, and iCloud sync while iCloud is
on. Torrents that were running when you quit continue at the next launch. See
[Privacy and Security](Privacy-and-Security.md) for the full list.
