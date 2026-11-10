# Klang Player

A small macOS menu bar app that plays an [Emby](https://emby.media) music library on a
**Loewe klang** speaker (and other speakers built on Frontier Silicon modules).

## Why

These speakers have a UPnP renderer, but it doesn't work with Emby or other DLNA apps:

- The device description (`dd.xml`) lists no services, so control points can't find
  `AVTransport` ("Unable to find avCommands" in Emby).
- Over the network the speaker only accepts **MP3 and AAC**, not FLAC.
- AAC plays only as a complete `.m4a` file with the `moov` atom at the start, not as a live
  stream.

Klang Player works around all of that:

1. Browses the library from Emby: albums, artists, folders, search.
2. Downloads the original track and converts it to **AAC 320 kbps** with Apple's encoder
   (`afconvert`, about 2–3 seconds per track). Hi-res files are resampled to 44.1/48 kHz.
3. Serves the file from a built-in HTTP server and sends it to the speaker over UPnP using
   the control URLs directly (`/AVTransport/control` on port 8080).
4. Prepares the next track while the current one plays and queues it with
   `SetNextAVTransportURI`, so tracks switch without a gap.

If a track can't be converted locally, it falls back to a live MP3 320 stream from Emby.

## Features

- Albums grid, artists, folder browser (play any folder recursively), search
- Queue: play next, add to queue, remove, jump
- Speaker volume, seek, pause, previous/next
- Speaker discovery over SSDP
- Emby login with username and password
- Converted tracks are cached in `~/Library/Caches/KlangPlayer` (up to 3 GB)
- Keeps the Mac awake while music is playing

The UI is in Russian.

## Requirements

- macOS 14 or later
- Xcode command line tools (Swift 5.10+)
- Emby server and the speaker on the same network as the Mac

## Build

```sh
./build.sh
```

This builds a release binary and puts `KlangPlayer.app` into `~/Applications`
(ad-hoc signed). Open it, then click the speaker icon in the menu bar. On first launch
the app asks for the Emby server, your login and the speaker; macOS also asks for local
network access — allow it.

## Notes

- The Mac has to stay on while music is playing: the speaker fetches files from it.
- Tested with Loewe klang s3 (firmware `ir-cui-FS2340-0000-0181_V4.5.21`).
- Speaker control uses the Frontier Silicon `fsapi` with the default PIN `1234`.

## Debug flags

```sh
KlangPlayer --discover                    # list UPnP renderers on the network
KLANG_ALBUM="Name" KlangPlayer --selftest # play 3 tracks of an album briefly at low volume
KlangPlayer --window [x y] [--preview]    # show the UI in a regular window
```

## License

MIT
