Native macOS menu-bar push-to-talk dictation for terminals, editors, and browsers. Hold the shortcut, speak, release — the transcript is inserted at your cursor. Uses the OpenAI transcription API with your own API key; no analytics, no telemetry, nothing stored.

## Install

1. Download the `MacDictate-*.zip` asset below and unzip it.
2. Move `MacDictate.app` to `/Applications`.
3. This build is not notarized, so on first launch right-click the app and choose **Open** (twice), or run:
   ```sh
   xattr -d com.apple.quarantine /Applications/MacDictate.app
   ```
4. Look for the waveform icon in the menu bar → **Settings…** → add your OpenAI API key, then grant Microphone and Accessibility permissions.

Requires macOS 14 Sonoma or newer and an OpenAI API key with access to the Audio Transcriptions API.
