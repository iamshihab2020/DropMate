# Contributing to DropMate

Thanks for helping. Bug reports, ideas and pull requests are all welcome.

## Before you start

- **Bugs:** open an issue with the Bug report form. Include your DropMate version, Windows version, and the phone model and Android version.
- **Features:** open an issue first so we can agree on the idea before you write code.
- **Questions:** use Discussions.

## Set up

You need [Flutter](https://flutter.dev) (stable), the Android SDK, and Visual Studio 2022 with **Desktop development with C++** (including the ATL component).

```
git clone https://github.com/<your-account>/DropMate.git
cd DropMate
flutter pub get
flutter run -d windows
```

To try two devices on one PC, run the end-to-end tests: they start three DropMate engines that pair and send files to each other over loopback.

## Making a change

1. Fork the repository and create a branch from `main`.
2. Keep the change focused on one thing.
3. Add or update tests for what you changed. Logic belongs in `lib/core/` or `lib/services/`, where it can be tested without a UI.
4. Run the checks before you push:
   ```
   flutter analyze
   flutter test
   ```
5. Open a pull request and fill in the template.

Keep these working:

- **No internet.** DropMate must never make a connection outside the local network.
- **No unpaired access.** Every route except pairing requires a signed request from a known device.
- **Older peers.** A new message type or route must fail quietly against a device that doesn't know it yet.
- **Both languages.** New text goes through `tr()` with a Bangla entry in `lib/ui/i18n.dart`.
- **The design rules** in [docs/DESIGN.md](docs/DESIGN.md), including reduced motion.

## Review and merging

Every pull request is reviewed by the maintainer, [@iamshihab2020](https://github.com/iamshihab2020), who is the only person who can merge into `main`. A pull request may be asked to change, or may be closed if it does not fit the project.

## Licence

By contributing, you agree that your contribution is licensed under the [Apache License 2.0](LICENSE), the same as the rest of the project.

## Releases

The maintainer publishes releases. Raise `version` in `pubspec.yaml` and `AppVersion` in `installer/dropmate.iss`, add a `## <version>` section to `CHANGELOG.md`, then build:

```
flutter test
flutter build apk --release --split-per-abi
flutter build windows --release
iscc installer\dropmate.iss
```

Release APKs are signed with the maintainer's upload key (`android/key.properties`, not in git). Builds without it fall back to the debug key, and Android won't install those over the official app.

Publish the arm64 APK as `DropMate-<version>-android.apk`, the armeabi-v7a APK as `DropMate-<version>-android-older-phones.apk` and the installer as `DropMate-<version>-windows-setup.exe`, with a `SHA256SUMS.txt`, on a `v<version>` tag.
