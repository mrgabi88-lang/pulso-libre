# Pulso Libre for Android

SPDX-License-Identifier: GPL-3.0-only

Pulso Libre is an Android client for discovering events, reserving free tickets, submitting payment receipts and displaying dynamic admission QR codes. Organizer and administrator services run on a separate backend. **powered by pllabs.com.ar** â€” https://pllabs.com.ar/

The application source is distributed under the GNU General Public License version 3 only. See [LICENSE](LICENSE) and [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md). Publishing this repository is separate from acceptance into F-Droid; this source candidate does not claim to be listed there.

## Source and service boundary

This repository contains the Flutter client, Android source/resources and synthetic unit/widget tests. It does not contain the private backend, server data, user records, receipts, signing keys, provider credentials, tokens, photos, marketing captures or music files. The production app uses `https://pllabs.com.ar/api/pulso_libre`; accounts and event services depend on that server. SoundCloud content, if selected by an event organizer, is loaded from SoundCloud at runtime. Paid events use organizer-controlled transfers with manual receipt review. Free QR requests require organizer approval before the server issues a ticket. Open-admission events remain separate and do not require a QR reservation.

## Build from source

The source snapshot uses version **1.0.0+12**, application ID **ar.com.pllabs.pulsolibre**. Verified local toolchain: **Flutter 3.38.4**, revision `66dd93f9a27ffe2a9bfc8297506ce066ff51265f`, **Dart 3.10.3**, Java language level **17**, Android compile SDK **37**, target SDK **36**, minimum SDK **24**, NDK **28.2.13676358**, Gradle **8.14**, Android Gradle Plugin **8.11.1**, Kotlin **2.2.20**. Install the corresponding public SDK/toolchain and accept its applicable licenses. Flutter generates `android/local.properties` and the standard Gradle wrapper JAR locally; do not commit machine paths or generated binaries.

`.flutter-version` pins the Flutter release used by the source and by the F-Droid recipe.

```sh
mkdir -p assets/images
flutter pub get
flutter analyze
flutter test
ORG_GRADLE_PROJECT_fdroidUnsigned=true flutter build apk --release --target lib/main.dart
```

PowerShell equivalent:

```powershell
New-Item -ItemType Directory -Force assets/images | Out-Null
flutter pub get
flutter analyze
flutter test
$env:ORG_GRADLE_PROJECT_fdroidUnsigned = 'true'
try { flutter build apk --release --target lib/main.dart } finally {
  Remove-Item Env:ORG_GRADLE_PROJECT_fdroidUnsigned -ErrorAction SilentlyContinue
}
```

`fdroidUnsigned=true` is an explicit Gradle property, also accepted as `-PfdroidUnsigned=true` with Gradle. This mode keeps the production package and API, skips loading private signing properties, and produces an **unsigned** release artifact; the package must be signed by its distributor before Android can install it. It is incompatible with `PULSO_LOCAL_TEST=true`. Do not use local-test flags for an F-Droid build.

Without this flag, the existing production release continues to require the publisher's private signing configuration (`PULSO_SIGNING_PROPERTIES`, or its default private location). Do not upload that file or key. Builds signed with a different key cannot directly update an existing installation signed by the original publisher. The signing/distribution strategy must be decided before users switch update channels.

## Tests and local development

The included `test/` files use synthetic fixtures and mocked transport/platform adapters. `integration_test/ui_navigation.dart` is a shared widget-navigation helper, not a device workflow. Physical-device, marketing-capture and real-server test scripts are intentionally absent. Running these unit/widget tests does not confirm real mail, payment, camera or admission behavior.

An existing separate local-development flag is available for maintainers with a compatible local backend:

```sh
flutter build apk --debug --dart-define=PULSO_LOCAL_TEST=true
```

That build has the separate application ID `ar.com.pllabs.pulsolibre.flujov2` and loopback-only API settings. No backend database or account is supplied by this repository. Unit/widget tests can run without the backend.

## Contributions

Keep backend authorization authoritative. Uploading a receipt is not proof of payment, and a QR is not accepted until the server confirms admission. Never add credentials, personal data, real tickets or signing keys to an issue or patch. Project code contributions must be compatible with GPL-3.0-only and preserve applicable upstream notices.

## Distribution versions and signatures

The universal website build keeps Android versionCode 12. ABI-specific source builds
use 121 (armeabi-v7a), 122 (arm64-v8a) and 123 (x86_64), derived as base * 10 + ABI.
The source preserves the eight brand assets included in the website candidate.
This does not claim byte-for-byte reproducibility or F-Droid publication.

F-Droid signs its own builds unless a separately verified reproducible-build setup
is configured. A differently signed package cannot update the publisher-signed
website installation. Keep the website update channel for existing installations;
do not uninstall an app merely to force a signature or version-code change.

`assets/images` is an intentionally empty directory declared by the preserved pubspec. Git does not retain empty directories, so the commands above and the F-Droid recipe recreate it without adding an asset or changing app code.
