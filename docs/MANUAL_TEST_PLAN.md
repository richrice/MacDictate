# MacDictate Manual Test Plan

Run this plan on macOS 14 or newer with a real microphone and a non-production OpenAI project whose usage can be monitored. Record the macOS version, MacDictate commit, target applications and versions, and results. Never paste an API key into this document or a bug report.

Before testing, build and verify automated tests:

```sh
./scripts/bootstrap.sh
./scripts/build.sh
./scripts/test.sh
```

## 1. First launch

1. Remove any older test build from `/Applications`, quit all MacDictate processes, and build with `./scripts/build.sh`.
2. Open `DerivedData/Build/Products/Debug/MacDictate.app`.
3. Verify no normal Dock icon remains and a waveform icon appears in the menu bar.
4. Open its menu. Verify current status, Start Dictation, Cancel Current Dictation, Settings, both permission links, and Quit are present.
5. Verify status is **Ready**, Start is enabled, and Cancel is disabled.

Expected: the app runs only as a menu-bar accessory, no recording begins, and no terminal/editor focus is stolen.

## 2. Microphone permission

1. In System Settings, remove or disable the current MacDictate microphone grant if present.
2. Open **MacDictate → Settings → Permissions** and verify the displayed state.
3. Click **Request Access** and verify the system prompt explains microphone use.
4. Deny once. Hold Option-Space and verify a concise permission error appears and the app returns to Ready.
5. Use **Open Microphone Settings**, enable MacDictate, relaunch it, and verify the status reads Granted.

Expected: denial never starts audio or an API request; granting access enables another attempt without reinstalling.

## 3. Accessibility permission

1. Disable MacDictate under **System Settings → Privacy & Security → Accessibility** and relaunch.
2. Verify Settings reports Denied.
3. Perform a successful dictation in TextEdit or a SwiftUI TextEditor.
4. When prompted, leave access denied. Verify the HUD says **Copied—press ⌘V to paste** and manual Command-V inserts the transcript.
5. Start another dictation and verify MacDictate does not repeatedly raise the standard permission prompt during the same launch.
6. Use MacDictate's Accessibility settings button, enable access, relaunch, and verify Settings reports Granted.

Expected: copy-only behavior is usable when denied; automatic insertion works when granted.

## 4. API-key entry and Keychain

1. Open **Settings → OpenAI** and verify only a secure field is shown; an existing key is represented as `••••••••`, never revealed.
2. Enter a valid test key and click **Save Key**.
3. Quit and relaunch; verify the UI still says Configured but does not populate the field.
4. Replace it with another valid test key and confirm transcription uses the replacement.
5. In Keychain Access, search for service `com.macdictate.app.openai` and account `OpenAI API Key`.
6. Do not delete it until the remaining successful tests finish.

Expected: one generic-password item exists; no key appears in `defaults read com.macdictate.app`, project files, or copied diagnostics.

## 5. Hotkey press and release

1. Focus an empty TextEdit document or SwiftUI TextEditor.
2. Press and hold Option-Space. Verify the target stays focused, the menu icon changes to a microphone, and the non-activating HUD shows a red mic and increasing elapsed time.
3. Continue holding for two seconds; verify key repeat does not restart the timer or create another HUD.
4. Speak a short instruction and release Space while Option remains down.
5. Verify recording stops immediately and the HUD changes to **Transcribing…**.
6. Tap Option-Space for less than 250 ms.

Expected: the release sends one request; the short tap reports cancellation and makes no chargeable transcription request.

## 6. Successful transcription and models

1. Select `gpt-4o-mini-transcribe`, English, and the default vocabulary context.
2. Dictate: “In AppCoordinator dot swift, use R G to find the URL Session call.”
3. Verify a punctuated transcript is inserted and no Return or Enter event follows it.
4. Change to `gpt-4o-transcribe`, repeat, and verify success.
5. Change Language to Automatic, dictate a short non-English phrase if available, and verify the request completes.
6. Edit the context, save by leaving the field, relaunch, and verify the edit persists; then use **Reset to Default**.

Expected: model/language/context changes apply to later requests; the context is not presented as a spelling guarantee.

## 7. Terminal insertion

1. Open Apple Terminal and run `cat` so input can be inspected without shell execution.
2. Put a recognizable non-text item plus the text `CLIPBOARD-SENTINEL` on the clipboard if possible.
3. Dictate “Use git status short before changing the working tree.”
4. Verify text appears at the Terminal cursor, but Terminal does not execute it.
5. Press Control-D to leave `cat`.

Expected: AX insertion or the Command-V fallback inserts exactly once; Return is never synthesized.

## 8. Codex CLI insertion

1. Start Codex CLI in a disposable test repository and leave its prompt editor focused.
2. Hold Option-Space, dictate “Inspect the readme and summarize the build commands,” and release.
3. Verify the text appears in the prompt but is not submitted.
4. Edit it manually, then press Return yourself.

Expected: MacDictate preserves the human review step.

## 9. Claude Code insertion

1. Start Claude Code in a disposable repository and focus its prompt input.
2. Dictate “Find the state machine tests and explain their edge cases.”
3. Verify insertion occurs exactly once and the prompt remains unsubmitted.

Expected: the workflow matches Codex CLI and does not emit Return.

## 10. Other insertion targets

Repeat a short dictation in each available target:

1. iTerm2 running `cat`.
2. VS Code's integrated terminal.
3. A VS Code editor document.
4. Cursor's prompt field.
5. A standard SwiftUI `TextEditor` in a small local test app.
6. Safari or Chrome text area on a non-sensitive blank/test page.

Expected: each uses direct AX insertion or the paste fallback; unsupported/secure fields fail safely or use copy-only mode. Record which route appears to be used and each app version.

## 11. Clipboard preservation

1. Copy rich text containing styled text and an image from a local document.
2. Force a paste-fallback target such as Terminal, dictate, and release.
3. After insertion finishes, paste into a rich-text document and verify the original text/image representations return.
4. Repeat, but copy `NEWER-VALUE` from another app immediately after the MacDictate HUD changes to inserting.
5. Paste and verify `NEWER-VALUE` remains; MacDictate must not restore the older snapshot over it.
6. Enable **Leave transcription on clipboard**, repeat, and verify the transcript intentionally remains instead.

Expected: unchanged clipboard snapshots are restored; any later pasteboard generation wins.

## 12. Rejected API key and quota

1. Save a deliberately invalid value such as `sk-invalid-for-manual-test`.
2. Record a normal two-second phrase.
3. Verify the app reports an authentication error, exposes redacted **Copy Last Error Details**, deletes the recording, and returns to Ready.
4. Restore the valid key and immediately complete another dictation.
5. If a safe test project with zero quota is available, repeat with that key and verify the message identifies quota/balance rather than generic authentication.

Expected: permanent 4xx errors are not retried and do not leave the app stuck.

## 13. No network, DNS, and TLS failures

1. With a valid key configured, disable Wi-Fi and disconnect other network interfaces.
2. Record and release a phrase.
3. Verify a useful network error appears within the request timeout and the app returns to Ready.
4. Restore connectivity and complete another dictation.
5. If an approved network test proxy is available, simulate DNS and TLS failures separately; verify technical details remain redacted.

Expected: the audio file is deleted on each failure and recovery does not require relaunch.

## 14. Rate limiting and server retry

The URLProtocol tests deterministically validate one retry for HTTP 429/5xx and no retry for authentication:

```sh
xcodebuild -project MacDictate.xcodeproj -scheme MacDictate -derivedDataPath DerivedData -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO test -only-testing:MacDictateTests/MultipartAndTranscriptionTests/testURLProtocolSuccessAndOneRetry -only-testing:MacDictateTests/MultipartAndTranscriptionTests/testAuthenticationFailureIsNotRetried
```

For an end-to-end manual check, use only an organization-approved TLS test proxy or a dedicated OpenAI project known to return HTTP 429:

1. Arrange a 429 response for the transcription endpoint without exposing the API key to an untrusted proxy.
2. Record and release once.
3. Verify exactly two HTTP requests (initial plus one retry), followed by a rate-limit error.
4. Arrange an HTTP 500 and verify the same two-request ceiling.
5. Restore normal routing and verify the next dictation succeeds.

Expected: never more than one automatic retry and no persistent failure state.

## 15. Cancellation and rapid input

1. Begin recording and choose **Cancel Current Dictation** before release.
2. Verify the mic and HUD stop and no request is sent.
3. Begin recording, release, and choose Cancel while **Transcribing…** is visible.
4. Verify the URLSession task cancels and the app returns to Ready.
5. Press/release Option-Space rapidly ten times, including presses during transcribing and inserting.
6. Finish with one normal dictation.

Expected: no overlap, crash, duplicate transcript, retained temporary file, or restart requirement.

## 16. Recording limit, silence, and microphone disconnection

1. Set Maximum duration to 10 seconds.
2. Hold the shortcut longer than 10 seconds and verify recording automatically stops and transcribes once.
3. Hold for one second in silence and verify a friendly silent/empty recording error with no API request where the audio threshold is met.
4. Start with a removable USB/Bluetooth microphone selected in macOS Sound settings.
5. Begin recording, disconnect or power off the microphone, and verify an interruption/device error.
6. Select a working input in System Settings and complete another recording.

Expected: taps and engine resources are released and the app recovers without relaunch.

## 17. Relaunch and privacy residue

1. Complete a dictation, quit, and relaunch.
2. Verify the model, language, prompt, hotkey, and UI preferences persist, while no transcript/history UI exists.
3. Verify the API key remains configured through Keychain.
4. Before and after several success/cancel/failure cases, inspect the temporary directory for `MacDictate-*.wav` files:

   ```sh
   find "$(getconf DARWIN_USER_TEMP_DIR)" -maxdepth 2 -name 'MacDictate-*.wav' -print
   ```

5. Copy redacted diagnostics and search them for a known substring of the test key and spoken transcript.

Expected: no temporary WAV remains and neither secret nor transcript appears in diagnostics.

## 18. Launch at login

1. Create a normally signed build and copy `MacDictate.app` to `/Applications`.
2. Launch that installed copy and enable **Launch MacDictate at login**.
3. Verify macOS Login Items shows MacDictate enabled or requiring explicit approval; approve if requested.
4. Log out and back in (or use a disposable macOS test account) and verify one menu-bar instance starts.
5. Disable the option, log out/in again, and verify MacDictate no longer starts automatically.

Expected: `SMAppService` status matches Settings and no duplicate instances launch.

## Completion record

Record:

- Build and all 17 automated tests: pass/fail
- First launch and both permission paths: pass/fail
- Apple Terminal, Codex CLI, Claude Code, VS Code, SwiftUI TextEditor, browser text area: pass/fail with versions
- Clipboard unchanged and externally changed cases: pass/fail
- Authentication, offline, 429, cancellation, rapid input, and microphone disconnect recovery: pass/fail
- Relaunch, residue scan, and launch at login: pass/fail
- Any limitation, exact reproduction steps, and redacted diagnostics

