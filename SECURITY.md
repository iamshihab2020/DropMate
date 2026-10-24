# Security policy

DropMate receives files from other devices on the network, so security reports matter.

## Supported versions

Only the latest release gets security fixes.

## Reporting a vulnerability

Please do not open a public issue. Report it privately instead:

1. Open the **Security** tab of this repository.
2. Choose **Report a vulnerability**.

Include what you found, the steps to reproduce it, and what an attacker could do with it. You will get a reply within 7 days.

## How DropMate protects you

- Pairing shows the same four emojis on both screens, derived from both devices' certificates, so a device in the middle would be noticed. A pairing code works once and expires.
- Each device has its own Ed25519 signing key and TLS certificate. Clients pin the certificate they paired with, and every request is signed and checked for freshness and replay.
- Only the pairing route accepts unknown devices. Everything else answers only to devices in a paired person's signed roster.
- Received file names are sanitized, files never overwrite existing ones, and every 4 MiB chunk is checked with SHA-256 before the file is saved.
- Apps and scripts always ask before they are accepted, even when auto-accept is on. On Windows, received files get the Mark of the Web, so SmartScreen and Office treat them as downloaded.
- DropMate makes no connections outside the local network and sends no telemetry.
