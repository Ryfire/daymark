# IzzyOnDroid App Inclusion Request (pre-answered)

Status: DRAFT — ready to paste into a new issue at
`codeberg.org/IzzyOnDroid/repodata` whenever we decide to submit. No age
gate (policy verified 2026-10-20 during the JotLock prep): the only time
criterion is that apps *stale for 12+ months* get dropped — fresh,
maintained apps are welcome.

Reference: the official template lives in that repo at
`.forgejo/issue_template/app-inclusion-request.yaml`; the policy is at
`izzyondroid.org/docs/general/AppInclusionPolicy`. Submission is an
**issue** (not an MR): create it at
`codeberg.org/IzzyOnDroid/repodata/issues/new` with title exactly:
**[AppRequest] Daymark**

HOW TO USE: fill in the **AI Tools Usage** section honestly first — it is
a *required* dropdown in the template (it asks about AI used to DEVELOP
the app; Daymark was built with AI assistance — say so). Then paste the
sections below into the matching fields and submit. A reviewer
VirusTotal-scans the APK, installs it on a test device with network
monitoring, checks it generally works, and adds the `approved` label.
Daymark DOES hold the INTERNET permission — tell the reviewer up front
how the network behaves (see the disclosure section below): **zero
network activity until an LLM endpoint is configured**. Best test path:
install, import a JotLock backup, read notes — the monitor stays quiet —
then optionally add a LAN endpoint (Ollama/llama.cpp) and watch only that
traffic appear.

---

## Guidelines

- I am the developer of the app. — **Yes** (single maintainer).
- The app complies with the App Inclusion Policy. — **Yes**
  (verified requirement-by-requirement 2026-11-03).
- The app is not already listed in the repo or issue tracker. — **Yes**
  (no `daymark` issues exist in their tracker; re-check at submission).
- The Fastlane folder is available in the app's repo. — **Yes**:
  `fastlane/metadata/android/en-US/` (title, short/full descriptions,
  changelog for versionCode 2014, icon, phone screenshots).

## App meta-data

- **Link to the source code:** `https://github.com/Ryfire/daymark`
- **Link to app in another app store:** none — GitHub Releases is the
  only distribution channel today (mainline F-Droid submission planned
  later; that would be a *separate signing lineage*, not
  install-compatible with these APKs).
- **License used:** MIT
- **Categories:** Office (primary; `Writing` optional secondary — at
  least 1, max 5 allowed)
- **Summary:** Turn JotLock backups into answers and cleaner notes —
  your device, your LLM.
- **Description:** paste `fastlane/metadata/android/en-US/full_description.txt`.

## Network disclosure (reviewer-facing)

Daymark holds the INTERNET permission — declared via the `NonFreeNet`
antifeature. What that means in practice:

- The app ships with **no AI service, no API keys, no default provider,
  no bundled cloud**.
- Network activity happens **only** when the user configures an LLM
  endpoint (Settings: base URL + optional API key) and asks a question or
  runs a rewrite. Import, reading, the library, duplicate triage and TTS
  are fully offline.
- The endpoint can be **fully local**: Ollama, LM Studio, or a llama.cpp
  server on the LAN — cleartext HTTP is allowed precisely so local
  endpoints work.
- Only the text of the notes selected for a question or rewrite is sent;
  nothing else ever leaves the device. No accounts, no analytics.
- The app never writes into JotLock: "Send to JotLock" shares a rewrite
  back as a NEW note, confirmed by the user in JotLock's editor.

## Technical instructions

**Build instructions** (CLI, from a fresh clone):

```
# Requirements: Flutter SDK 3.47.6 (matches the repo .metadata), JDK 17,
# Android SDK (compileSdk 36, minSdk 24)
flutter pub get
flutter build apk --release
# → build/app/outputs/flutter-apk/app-release.apk
```

A fresh clone builds debug-signed (the release keystore is external to
the repo, referenced by gitignored `android/key.properties`). Izzy serves
upstream APKs from GitHub Releases, which are release-keystore signed.
