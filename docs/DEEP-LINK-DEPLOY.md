# Deep-link deployment (NOTIF2 B2 — ntfy notification taps open the APP, not the browser)

## One canonical URL

Every run deep link — ntfy click, browser address bar, notification tap — has
ONE shape, produced by the server (`compat/notification_events.py
run_link()` = `app_compat.notification_events.click_base` + path):

```
https://<entry>/#/chat?session=<sid>&run=<run>&event=<eid>[&request=<id>]
```

`click_base` (server config) and `HERMES_APP_DEEPLINK_URL` (build config)
MUST name the same public entry origin; the APK's intent filters are cut
from the latter. Android matches only the scheme/host/path of that URL (the
`#/chat...` fragment is delivered to the app whole and parsed identically to
the web flow — same `RunLink` parser, same exact-identity navigation).

## Build-time wiring

* `~/.hermes/.env`: `HERMES_APP_DEEPLINK_URL=https://<entry-host>`
  (plus the entry's sub-path if the app is served below root, e.g.
  `https://host/hermes`). Non-secret; a missing/invalid value fails a
  **personal APK** build; a **public APK** never opens the env file and
  ships the inert placeholder host `hermes.invalid`, whose filters match
  nothing.
* `scripts/build_app.py` passes `-Pdeeplink.host=<host>` /
  `-Pdeeplink.path=<path>` to Gradle (everything after `--`); the manifest
  substitutes the `${deepLinkHost}` / `${deepLinkPath}` placeholders. The
  entry's host is NEVER hardcoded into the manifest source.
* Verify the MERGED manifest before shipping
  (`grep -A6 VIEW app/build/app/intermediates/merged_manifest/release/AndroidManifest.xml`
  or `aapt dump badging <apk>`) — the deployed host must appear there
  resolved, once per HTTPS filter.

## Android 12+: a filter alone is not an App Link

Since Android 12 an HTTPS link opens the app WITHOUT a chooser only if the
domain is verified. Verification needs this JSON served by the entry host
itself at `/.well-known/assetlinks.json`:

```json
[{"relation":["delegate_permission/common.handle_all_urls"],
  "target":{"namespace":"android_app",
            "package_name":"dev.hermes.hermes_app",
            "sha256_cert_fingerprints":["<APK signing cert SHA-256>"]}}]
```

Use the certificate the APK is ACTUALLY signed with — the current release
builds still sign with the debug key (see `app/android/app/build.gradle.kts`);
fingerprint it with
`keytool -list -keystore ~/.android/debug.keystore -storepass android`.
A different certificate silently breaks verification.

**Tailnet-only / unverifiable hosts:** the manifest keeps an
`autoVerify`-off twin filter as the honest fallback, but nothing
guarantees automatic routing — the user associates the domain once in
Android Settings → Apps → Hermes → *Open by default* → *Open supported
links*. Acceptance is an **implicit** VIEW tap (`adb shell am start -a
android.intent.action.VIEW -d "https://<entry>/#/chat?session=..."`, no
package flag) AND finally tapping a real ntfy notification — a
package-targeted `am start` only proves the app parses, never that the
OS picks the app.

## Runtime behavior

Cold start: the launch intent arrives on the app_links stream from app
start (well before any widget) and waits in the existing one-spend stash
until the session list is ready; warm: links route immediately through the
same queue. An unresolvable session stays an honest refusal (snackbar), and
an argument-less cold launch (`https://<entry>/` with no `#/chat` link)
changes nothing — it is not a deep link at all.
