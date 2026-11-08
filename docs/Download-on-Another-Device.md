# Download on Another Device

**Download on** starts a link download on another of your devices: a Hub device, such as a home server, or another
Mac. The file downloads there, straight from the server, into that device's Downloads folder. Get shows its progress
on this Mac.

Only http and https links download on another device. Torrents run on this Mac.

## Before you start

- The device must be in your vault. [Vault](https://github.com/v57/Vault/blob/main/docs/README.md) lists your Hub
  devices and the Macs that let your devices in. A Mac lets your devices in with **Vault ▸ Settings ▸ Remote ▸ Let Your
  Devices In**, which needs Remote Login on.
- The device needs `curl` or `wget`. Macs have curl. On a Linux device without either, the download fails with
  **Neither curl nor wget is installed there.**
- Get signs in with its own key, not your device's key. The first time you download on a Mac, Get adds its key to your
  vault. On that Mac, open **Vault ▸ Settings ▸ Remote**. Under **Apps on Your Devices**, find Get on this Mac and turn
  on **Can Sign In**. Until you do, the download fails with a sign-in error. After you allow it, click **Retry**.

## Download a link on a device

1. Open **Download a Link** and paste the link.
2. In **Download on**, pick the device. **This Mac** downloads here.
3. If you have more than one vault account, pick the account first. Each account lists its own devices.
4. Click **Download**.

The row in the sidebar shows the progress and the device's name. The details show where the file is saved, such as
**Downloads on** the device, and that it goes over SSH through your Hub. They show how much is done, not byte counts.

When it's done, the details say where it was saved. If the name was taken, the file gets a numbered name. The finished
download stays in **Downloaded**, marked with the device's name. **Show in Finder** isn't offered, since the file isn't
on this Mac.

## The first connection to a device

The first time Get connects to a device whose key it doesn't know, it asks **Trust this server's key?** with the
device's name and address. Click **Trust and Connect** to go on. Vault remembers the key. Click **Cancel** to stop; the
download fails.

If your Mac's key needs you to confirm, macOS asks for Touch ID or your password when Get signs in. If you decline, the
download fails.

## A device that takes a password

Get never reads a saved password. If the host is set to sign in with a password, the download fails and says so:
allow Get on that Mac in **Vault ▸ Settings ▸ Remote** and set the host to sign in with a key.

## Checksums

A checksum works the same as on this Mac, but the device computes it. If the file doesn't match, the download fails and
says the file on that device doesn't match the checksum.

## Stop, retry and trash

- **Cancel** stops the download on the device. The partial file stays there.
- **Retry** on a failed download continues the partial file.
- **Move to Trash** takes the download off the list. Its file stays on the device.

If the device is unreachable, Get tries its other addresses first, then fails with the connection error. If the device
was removed from your vault, Retry says **The device is no longer on your Hub.**

## After you quit

A download on another device that hasn't finished isn't listed after you relaunch Get. Finished ones are.
