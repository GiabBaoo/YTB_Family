# Project: YT Family (Personal Ad-Free YouTube Client for Android)

## Tech Stack & Packages
- Flutter (Dart), target platform: Android (minSdk 24, targetSdk 36).
- `flutter_inappwebview: ^6.1.5` (Core browser, network ad-blocking, JS injection).
- `audio_service: ^0.18.18` (Keep audio alive + MediaStyle notification & lockscreen controls).
- `wakelock_plus: ^1.2.8` (Prevent screen timeout while watching video).

## Core Principles
1. Zero backend server, zero YouTube stream extraction libraries (no yt-dlp/youtube_explode).
2. Rely strictly on `https://m.youtube.com` inside InAppWebView.
3. Keep UI distraction-free (full-screen WebView, no bottom navigation bar cluttering the screen).
4. Always preserve cookies and local storage so Google Account login persists permanently.

## Tooling & Sandbox Rules (Windows)
- Always run `flutter` and `dart` CLI commands (e.g., `flutter analyze`, `flutter test`, `flutter pub`, `flutter build`, `dart analyze`) with `BypassSandbox: true` directly on the first attempt.
- Never run `flutter` or `dart` inside the standard sandbox (`BypassSandbox: false`): `C:\flutter\bin\internal\shared.bat` spins in an infinite loop on `C:\flutter\bin\cache\flutter.bat.lock` (`Access is denied` suppressed by `2>NUL`), and `dart analyze` fails accessing `%LOCALAPPDATA%\.dartServer` and `%LOCALAPPDATA%\Pub\Cache`.