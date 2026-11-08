# Privacy and Security

## What Get sends over the network

Get sends nothing to v57. There's no server of ours, no analytics and no crash reporter. Get contacts these, and only
for these reasons:

| Who | When | What they see |
|---|---|---|
| The server a link names | You download a link, and at launch for a link download that was running when you quit | Your IP address and the link |
| The trackers a torrent names | You open a torrent, and at launch for a torrent that was running when you quit; then again at the tracker's interval while it runs | Your IP address, which torrent, the port Get listens on, and how much you've downloaded |
| The BitTorrent DHT, a public network of torrent clients | While a torrent runs | Your IP address and which torrent you're looking for |
| Other computers sharing the torrent | While a torrent runs | Your IP address, which torrent and which pieces you have |
| Your other devices, over SSH | You pick a device in **Download on** | A sign-in with Get's own key, and the link to download |
| GitHub | You choose **Get ▸ Check for Updates…**, or daily if you turned on **Check for Updates Automatically** | Your IP address |
| Apple's iCloud | While **Use iCloud** is on | Your vault's records (your devices and hosts), encrypted on this Mac first |

### Torrents are public

A torrent works by connecting to other computers. While a torrent runs, Get listens for other clients on port 6881,
connects to the peers that trackers and the DHT name, and exchanges peer lists with them. Anyone in the same swarm sees
your IP address and which torrent you're downloading.

Get never uploads pieces. It doesn't seed, during or after a download. It doesn't use UPnP, NAT-PMP or local peer
discovery.

### Downloads continue at launch

A torrent or link download that was running when you quit continues when you open Get again, without a click. That
continues the download you started; Get starts nothing new on its own. A download you paused stays paused. To stop one
from continuing, pause, cancel or trash it before you quit.

### Update checks

Get checks for updates only when you ask, with **Get ▸ Check for Updates…**. **Check for Updates Automatically** is off
when you install Get. An update downloads only when you say so.

## Downloaded files are quarantined

Every file Get downloads carries the macOS quarantine mark, as files from Safari do. The first time you open a
downloaded app, installer or script, macOS checks it and asks before it runs.

## Keys and passwords

- **Download on** signs in with Get's own key, kept in this Mac's Secure Enclave. You allow it per Mac in
  **Vault ▸ Settings ▸ Remote ▸ Apps on Your Devices**, with **Can Sign In**. It can only run a command there: no
  terminal and no tunnels.
- Get can't read your saved passwords or your device's key. A host that takes a password says so instead.
- The first time Get connects to a device, it shows the device's key and asks **Trust this server's key?**. Nothing is
  sent to the device before you click **Trust and Connect**.

## iCloud

**Get ▸ Settings… ▸ Privacy** has the **Use iCloud** switch. It's the same switch in every v57 app on this Mac. Get
uses iCloud for one thing: the list of your devices for **Download on**.

To turn it off, switch **Use iCloud** off and confirm **Turn Off iCloud?**. Every v57 app on this Mac stops syncing
through iCloud and iCloud Keychain. What's already in iCloud stays, and your other devices keep it. Turn it back on to
sync again.

## What Get keeps on this Mac

- Downloads in progress in the Downloading folder inside Downloads, then in Downloads.
- What it needs to continue downloads after a relaunch, the list of finished downloads, and the history of earlier
  transfers it uses for time-left estimates. These are in Get's own folder in your Library.
