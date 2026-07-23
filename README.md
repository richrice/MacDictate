# MacDictate

MacDictate is a native macOS menu-bar push-to-talk dictation utility for writing natural-language prompts in Terminal, iTerm2, VS Code, Cursor, Codex CLI, Claude Code, browser text areas, and other editable controls.

Hold **Option-Space**, speak, and release. MacDictate records only while the shortcut is held, sends the temporary WAV recording to the OpenAI transcription API, and inserts the returned text at the cursor in the application that was focused when recording began. It never presses Return or submits the prompt.

## Install from a release (no build required)

1. Download `MacDictate-<version>.zip` from the [latest release](https://github.com/richrice/MacDictate/releases/latest) and unzip it.
2. Move `MacDictate.app` into `/Applications`.
3. First launch: release builds are development-signed, not notarized, so macOS will refuse a normal double-click with "Apple cannot check it for malicious software." Either right-click the app and choose **Open**, then **Open** again in the dialog, or run:

   ```sh
   xattr -d com.apple.quarantine /Applications/MacDictate.app
   ```

4. Continue with [First-time setup](#first-time-setup) below: add your OpenAI API key and grant Microphone and Accessibility permissions.

If you prefer to audit what you run—reasonable for an app with microphone and Accessibility access—build it from source instead using the steps below.

## Requirements

- macOS 14 Sonoma or newer
- Xcode 16 or newer with Command Line Tools selected
- [XcodeGen](https://github.com/yonaskolb/XcodeGen) 2.44 or newer
- An OpenAI API key with access to the Audio Transcriptions API
- Microphone permission; Accessibility permission is needed for automatic insertion

MacDictate uses Swift, SwiftUI, AppKit, AVFoundation, Security, Carbon, ServiceManagement, and XCTest. It has no runtime third-party dependencies. XcodeGen is a build-time project generator only; `MacDictate.xcodeproj` is also checked in.

## Bootstrap, build, test, and run

From the repository root:

```sh
./scripts/bootstrap.sh
./scripts/build.sh
./scripts/test.sh
./scripts/run.sh
```

If XcodeGen is missing, install it and retry:

```sh
brew install xcodegen
./scripts/bootstrap.sh
```

The Debug app is produced at:

```text
DerivedData/Build/Products/Debug/MacDictate.app
```

To work in Xcode:

```sh
open MacDictate.xcodeproj
```

Select the `MacDictate` scheme and the **My Mac** destination. Builds are signed with the development team configured in `project.yml` (`DEVELOPMENT_TEAM`), which keeps Microphone and Accessibility grants stable across rebuilds. Set your own team ID there (or clear it and pass `CODE_SIGNING_ALLOWED=NO` for unsigned builds). Distribution outside your own machines requires Developer ID signing configured in Xcode.

## Releasing

Tag a version and push it; GitHub Actions tests, builds, packages, and publishes the release automatically:

```sh
git tag v1.1.0
git push origin v1.1.0
```

The app version comes from the tag (the `MARKETING_VERSION` in `project.yml` is overridden at build time), and the release notes combine a fixed install header with GitHub's generated changelog. CI builds are unsigned, so the quarantine step in the install section applies to downloads. Run the workflow manually from the Actions tab for a dry run that uploads the zip as an artifact without publishing.

## First-time setup

1. Run MacDictate. It is an accessory application: look for the waveform icon in the menu bar rather than the Dock.
2. Choose **Settings…** from the menu-bar menu.
3. In **OpenAI**, enter the API key and choose **Save Key**. MacDictate stores it only as a generic password in macOS Keychain.
4. In **Permissions**, request Microphone access.
5. Grant Accessibility access when automatic insertion is first used, or open **System Settings → Privacy & Security → Accessibility** from MacDictate.
6. Focus an editable control, hold Option-Space for at least 250 ms, speak, and release.

The default model is `gpt-4o-transcribe`. `gpt-4o-mini-transcribe` is available in the OpenAI settings. Language can be English (`en`) or Automatic. The editable developer-vocabulary prompt is context supplied to the model; it does not guarantee spelling.

## How it works

The explicit workflow states are `idle`, `preparing`, `recording`, `transcribing`, `inserting`, `completed`, `cancelled`, and `failed`. A second recording cannot start while transcription or insertion is active, but pressing the shortcut during the brief completion or error display starts a new dictation immediately. Errors stay on screen for three seconds; other terminal states clear after about a second. The menu can also start a recording; **Stop and Transcribe** finishes a menu-started recording deliberately.

- A Carbon global hotkey provides both key-down and key-up events and consumes the shortcut before the foreground app receives it. Auto-repeat is ignored. Settings provides several modifier/Space alternatives and reports registration conflicts.
- AVAudioEngine captures the input chosen in MacDictate, using its persistent Core Audio device ID without changing the system-wide input. The previous MacDictate input is remembered and used if the active microphone disconnects. AVAudioConverter writes mono 16 kHz, 16-bit linear PCM in a temporary WAV file. A five-minute ceiling keeps the largest default upload near 9.6 MB before WAV overhead.
- URLSession posts binary-safe multipart form data to `https://api.openai.com/v1/audio/transcriptions`. HTTP 429 and transient 5xx responses receive at most one delayed retry, honoring a numeric `Retry-After` header up to five seconds; authentication and other permanent 4xx failures are not retried.
- The app first tries the Accessibility selected-text attribute, then verifies that the exact expected value remains present rather than trusting the setter's return code. If that control rejects direct insertion, MacDictate sends Unicode keyboard events directly to the captured application and applies the same verification.
- The Codex desktop composer and iTerm2 use paste-first delivery because their editors do not expose a reliably verifiable Accessibility value. Codex uses a focused global Command-V event matching its proven physical-paste path. Other targets use paste only after earlier attempts are observably absent.
- Every automatic paste snapshots all pasteboard item representations, temporarily writes the transcript, and restores the snapshot after the verification window if no newer pasteboard generation appeared. Temporary transcript writes are marked with `org.nspasteboard.TransientType` so clipboard managers skip them.
- Automatic delivery is never considered successful merely because an API call or event post returned successfully. If the result cannot be verified, MacDictate stops before risking a duplicate fallback and restores the pre-dictation clipboard. Codex and iTerm2 report **Paste sent** when the paste event is dispatched but their editor state is not Accessibility-verifiable; other ambiguous outcomes report **Insertion unconfirmed**.
- If Accessibility access is unavailable, the transcript stays on the clipboard and the HUD says to press Command-V manually.

MacDictate never synthesizes Return or Enter.

### Application-specific notes

- **Apple Terminal:** its text view may reject the Accessibility selected-text attribute. Unicode keyboard insertion or the verified Command-V fallback is expected.
- **iTerm2:** MacDictate uses paste-first delivery and reports **Paste sent** when a terminal UI redraw prevents Accessibility verification.
- **Codex desktop composer:** MacDictate uses the global focused paste route that matches a physical Command-V and keeps the transcript available long enough for the browser editor to consume it.
- **VS Code, Cursor, and browser editors:** Electron/browser accessibility trees vary by version and editor. Direct insertion may work; otherwise MacDictate uses verified keyboard or paste delivery.
- **SwiftUI TextEditor and standard AppKit text controls:** direct Accessibility insertion normally works.
- **Password/secure fields:** macOS may intentionally refuse insertion.
- **Remote desktop, keyboard-remapping, and clipboard-manager tools:** these can reserve the hotkey or change the clipboard before restoration. Select another shortcut or let the newer clipboard remain.
- **Microphone choice:** Choose **System Default** or a specific microphone from MacDictate's menu or General settings. The choice applies only to MacDictate. The recording HUD shows the active microphone and a live input-level meter.

## Settings

- **General:** launch at login, HUD, sounds, app-local microphone choice, automatic insertion, optional persistent transcript copy, and recording limit.
- **Hotkey:** modifier/Space presets, default restoration, and live registration/conflict status.
- **OpenAI:** save/replace/delete the Keychain credential, model, language, context prompt, and prompt reset.
- **Permissions:** live Microphone and Accessibility states with links to the correct System Settings panes.
- **Diagnostics:** version/build, redacted diagnostics, unified-log folder, and content-free debug metadata logging.

Launch at login uses `SMAppService`. It works reliably after placing a signed build in `/Applications`; a development build may report that approval or installation is required.

## Privacy and security

- Audio is sent directly to the configured OpenAI API for transcription. Review OpenAI's data and retention terms for your account.
- Temporary recordings are deleted after success, cancellation, and terminal failure. MacDictate keeps no audio or transcription history.
- The API key is stored in macOS Keychain under service `com.macdictate.app.openai` and account `OpenAI API Key`.
- MacDictate has no analytics, telemetry, crash-reporting SDK, or background recording.
- Logs and copied diagnostics exclude API keys, authorization headers, transcript content, clipboard content, and raw audio. Debug logging records only values such as durations, lengths, and state.
- The user is responsible for OpenAI API charges and API-key security.

**Never put an API key in source, `project.yml`, a plist, shell history, a test fixture, or a Git commit.**

## Troubleshooting

### The menu-bar icon does not appear

Check whether another MacDictate process is running, then relaunch the built app:

```sh
pkill -x MacDictate 2>/dev/null || true
open DerivedData/Build/Products/Debug/MacDictate.app
```

### Option-Space does nothing

Open **Settings → Hotkey**. If a conflict is shown, choose another preset. Some keyboard managers, launchers, and input methods reserve Option-Space.

### Microphone access is denied

Use the menu's **Open Microphone Settings**, enable MacDictate, quit it, and reopen it. Team-signed builds keep their permission grants across rebuilds; unsigned builds (`CODE_SIGNING_ALLOWED=NO`) are treated as a new binary on every rebuild and re-prompt each time.

### Text is copied but not inserted

Enable MacDictate in **System Settings → Privacy & Security → Accessibility**, then relaunch it. Copy-only mode is intentional when permission is denied. If the HUD says **Insertion unconfirmed**, MacDictate attempted automatic insertion but could not verify the focused control changed, so it deliberately did not claim success or risk a duplicate fallback. The prior clipboard is preserved unless **Leave transcription on clipboard** is enabled.

### The old clipboard was not restored

MacDictate restores only if its temporary transcript is still the current pasteboard generation. If a clipboard manager, another application, or the user writes a newer value during paste, that newer value wins by design.

### API errors

- HTTP 401/403: replace the API key in Settings.
- Quota/billing errors: check the OpenAI project's billing and limits.
- HTTP 429: MacDictate retries once, then reports rate limiting.
- DNS, TLS, or offline failures: restore network access and try a new dictation.
- Presses shorter than 250 ms are cancelled without an API request. Silent recordings and empty transcription responses end with a quiet "No speech detected" message rather than an error.

The menu exposes **Copy Last Error Details** after an error. The copied detail is redacted.

## Remove credentials and uninstall

Delete the key with **Settings → OpenAI → Delete Key**, or run:

```sh
security delete-generic-password -s com.macdictate.app.openai -a 'OpenAI API Key'
```

Disable launch at login before uninstalling. Then quit MacDictate and remove the installed app:

```sh
pkill -x MacDictate 2>/dev/null || true
osascript -e 'tell application "Finder" to delete POSIX file "/Applications/MacDictate.app"' 2>/dev/null || true
```

To remove preferences as well:

```sh
defaults delete com.macdictate.app 2>/dev/null || true
```

The Keychain item is independent of the app bundle; delete it explicitly with one of the credential-removal methods above.

## Validation and architecture

Automated coverage includes the state machine, short-press policy, off-main audio tap execution, multipart fields and binary content, authorization construction, plain text and JSON error parsing, retry policy and in-flight cancellation through URLProtocol, `Retry-After` parsing, a mock credential store, pasteboard restoration races, the transient clipboard marker, Unicode chunk integrity, verified/unverified insertion fallback order, temporary-file cleanup, and secret redaction. A coordinator suite drives the full dictation workflow against mocks, including truthful unverified-insertion messaging.

Hardware, global input, permission prompts, and application-specific Accessibility behavior require manual testing. Follow [docs/MANUAL_TEST_PLAN.md](docs/MANUAL_TEST_PLAN.md).
