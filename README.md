# VeilGrid

Private, **serverless** location sharing. No account, no sign-up, no Matrix
homeserver — your identity is a key pair on the device, and contacts are linked
by QR code. Live locations travel peer-to-peer over [Veilid](https://veilid.com)
private routes.

This is a standalone app, not a store product: a handful of people install it
from GitHub Releases and update it from inside the app.

## What it does

- **Map** with live contact markers, your own trail, and saved places.
- **Contacts** linked by QR / pasted address. Rename them locally, pause
  sharing per contact, view their recorded history (Life360-style).
- **Places** with address search (OpenStreetMap), radius circles on the map,
  "who is here", and movement alerts ("started moving" / "stopped").
- **Settings**: display name, home + auto-pause geofence, units, theme,
  address rotation, in-app update check.

## How linking works

There is no server. Each device owns a Veilid DHT record (its **address**) and
publishes its current private route to that record. A contact scans your QR,
opens your record, imports your route, and pins the record owner's public key.

Location messages are signed with the sender's identity key and verified by the
recipient against the pinned key, so a peer cannot impersonate a contact. The
app only accepts messages from contacts, rejects stale/replayed payloads, and
refuses invalid coordinates.

## Install

1. Open the [latest release](https://github.com/Thalionn/veilgrid/releases/latest).
2. Download `grid-<version>.apk`.
3. Android will ask you to allow installing from your browser (or Files) the
   first time.

## Updates

The app checks GitHub Releases at most once every six hours and offers an
**Update** action in a snackbar; **Settings → Check for updates** does it on
demand. It downloads the APK and hands it to Android's installer — the system
always asks for confirmation, and the first time also asks you to allow
"install unknown apps" for VeilGrid.

Releases are cut locally with the signing key:

```bash
# bump `version: X.Y.Z+N` in pubspec.yaml (N must increase)
tool/release.sh            # build + stage build/dist/{grid-X.Y.Z.apk,latest.json}
tool/release.sh --publish  # also create the GitHub release
```

The updater reads `latest.json` from the latest release:

```json
{"version":"2.2.0","buildNumber":2000,"apk":"https://…/grid-2.2.0.apk","notes":"…"}
```

## Build

```bash
flutter pub get
flutter build apk --debug     # or --release (needs android/local.properties signing)
```

Requires Flutter 3.50+, JDK 21, and the Android SDK/NDK the Gradle project pins.
Veilid is pulled as a git dependency (`veilid-flutter`) and compiled natively.

## Privacy notes

- No accounts, no analytics, no telemetry. Location history is sealed with
  AES-GCM on the device.
- Android cloud backup is disabled for the app.
- One deliberate exception: **place search** sends the text you type to
  OpenStreetMap's Nominatim. Nothing else leaves the device.
- Map tiles are Protomaps PMTiles loaded from `map.mygrid.app` (the original
  project's public tile host). A self-hosted `maps_url` can be configured.

## License and provenance

VeilGrid is a substantially modified version of
[Grid](https://github.com/Rezivure/Grid-Mobile) by Chandler Gach, used under the
**GNU Affero General Public License v3.0**. The Matrix backend, accounts,
groups, and store deployment have been removed; the P2P transport, signing,
history, places, and update mechanism are new. See [NOTICE](NOTICE) for the
list of changes and [LICENSE](LICENSE) for the full license.

Source is available in this repository, as the AGPL requires.
