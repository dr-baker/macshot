# Privacy Policy

**Last updated:** October 5, 2026

## Overview

Macshot Pro is a free, open-source screenshot and screen recording tool for macOS. It is designed to run entirely on your device. We do not operate any servers, and we do not collect, store, or have access to any of your data.

## Data collection

- **No telemetry or analytics.** Macshot Pro does not track usage or send analytics to the fork maintainer.
- **No data collection.** We do not collect personal information, usage statistics, crash reports, or any other data.
- **No server-side storage.** We do not operate any servers. All screenshots, recordings, and settings are stored locally on your Mac.
- **No access to your uploads.** When you upload to Google Drive, files go directly to your own Google Drive account. We cannot see, access, or download your files. When you upload to imgbb, files go directly to imgbb's servers under their privacy policy.

## Data stored on your device

Macshot Pro stores the following data locally on your Mac:

- **Screenshots and recordings** — saved to your chosen folder (default: Pictures).
- **Screenshot history** — recent captures stored inside the app's sandbox container under `Data/Library/Application Support/com.sw33tlie.macshot/history/`. You control the history size in Preferences (set to 0 to disable).
- **Preferences** — settings stored in macOS UserDefaults.
- **Google Drive OAuth tokens** — if you sign in to Google Drive, authentication tokens are stored inside the app's sandbox container under `Data/Library/Application Support/com.sw33tlie.macshot/gdrive_tokens.json` with owner-only permissions (0600). Tokens are used solely to upload files to your own Google Drive. You can sign out at any time in Preferences, which deletes the token file.

The containers are `~/Library/Containers/com.drbaker.macshot.pro`,
`com.drbaker.macshot.pro.offline`, and `com.drbaker.macshot.dev`, depending on
the build. Internal storage directory names remain unchanged from Macshot.

## Third-party services

Macshot Pro integrates with the following optional third-party services. Use of these services is entirely opt-in:

### Google Drive
- **Purpose:** Upload screenshots and recordings to your own Google Drive.
- **Scope:** `drive.file` — Macshot Pro can only access files it created in your Drive. It cannot read, list, or modify any other files in your Drive.
- **Data sent:** The image or video file you choose to upload, plus a filename.
- **Authentication:** OAuth 2.0. You sign in via Google's login page in your browser. Macshot Pro stores a refresh token locally (see above) to avoid repeated sign-ins.
- **Revoking access:** You can sign out in Macshot Pro Preferences, or revoke access at any time from [Google Account Permissions](https://myaccount.google.com/permissions).

### S3-compatible storage

Files upload directly to the endpoint you configure, using the credentials you
provide. Your storage provider controls access to those files.

### Translation

When you request a translation, extracted text is sent to Google Translate.
OCR itself uses Apple Vision on your Mac.

### imgbb
- **Purpose:** Upload screenshots to imgbb for shareable image links.
- **Data sent:** The image file you choose to upload.
- **imgbb's privacy policy:** [https://imgbb.com/privacy](https://imgbb.com/privacy)

### Sparkle updates

Source builds and the local development app do not check for updates. A packaged
release can enable Sparkle with this fork's signing key and a variant-specific
feed hosted at `raw.githubusercontent.com/dr-baker/macshot`. Update checks request
release metadata from GitHub. Installing an update requires confirmation.

## Permissions

Macshot Pro requests **Screen Recording** permission from macOS. This permission is required to capture screenshots and record your screen. macOS controls this permission — you can revoke it at any time in System Settings > Privacy & Security > Screen Recording.

Accessibility access enables interface snapping and automated scrolling.
PermissionFlow helps you grant it in System Settings. Microphone, camera,
Input Monitoring, and Speech Recognition permissions are requested only for
the recording features that use them.

## Open source

Macshot Pro is fully open source. You can inspect the complete source code at [https://github.com/dr-baker/macshot](https://github.com/dr-baker/macshot) to verify these claims.

## Contact

If you have questions about this privacy policy, open an issue at [https://github.com/dr-baker/macshot/issues](https://github.com/dr-baker/macshot/issues).
