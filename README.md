# YT Family

Ứng dụng YouTube cá nhân không quảng cáo dành cho Android, xây dựng bằng Flutter dựa trên `m.youtube.com` trong `InAppWebView`.

## Tính năng chính

- **Chặn quảng cáo nhiều lớp (`AdBlockService`)**:
  - Chặn request tới các domain quảng cáo/tracking (`doubleclick.net`, `googlesyndication.com`, `googleadservices.com`, `ads.youtube.com`, v.v.) và các đường dẫn quảng cáo (`/pagead/`, `/api/stats/ads`, `/youtubei/v1/player/ad_break`, ...).
  - Content Blocker tích hợp ở tầng WebView và script dọn phần tử quảng cáo trên giao diện.
- **Phát nhạc nền & tắt màn hình**:
  - `BackgroundAudioService` tiêm script giữ trình phát video tiếp tục chạy khi ứng dụng xuống nền hoặc tắt màn hình.
  - `MainActivity.kt` kết hợp `PowerManager.WakeLock`, `WifiManager.WifiLock` và kênh `com.example.ytb_family/lifecycle` để giữ WebView hoạt động ổn định khi phát nền.
- **Điều khiển Media native (`YtAudioHandler` & `MediaBridge`)**:
  - Đồng bộ trạng thái phát từ WebView (`ytbMedia` handler) sang Android `MediaStyle` notification, màn hình khóa và nút điều khiển tai nghe thông qua `audio_service`.
  - Hỗ trợ `play`, `pause`, `next`, `prev`, `seek`.
- **Trải nghiệm tối giản & giữ đăng nhập**:
  - Giao diện toàn màn hình nền tối (`#0F0F0F`), không thanh điều hướng rườm rà.
  - Giữ cookies và local storage để duy trì đăng nhập tài khoản Google.
  - Hỗ trợ `wakelock_plus` tránh tắt màn hình khi đang xem video và `supportsPictureInPicture="true"` trên Android.
- **Không backend trung gian**: Không dùng server riêng hay thư viện trích xuất stream (`yt-dlp`, `youtube_explode`).

## Công nghệ sử dụng

- **Flutter / Dart** (SDK `^3.10.7`)
- [`flutter_inappwebview: ^6.1.5`](https://pub.dev/packages/flutter_inappwebview) — WebView, chặn request mạng, Content Blocker và tiêm JavaScript.
- [`audio_service: ^0.18.18`](https://pub.dev/packages/audio_service) — Foreground Service, MediaStyle notification và điều khiển màn hình khóa.
- [`wakelock_plus: ^1.2.8`](https://pub.dev/packages/wakelock_plus) — Giữ màn hình sáng khi xem video.

## Cấu trúc thư mục

```text
lib/
├── main.dart                           # Entry point, theme tối, khởi tạo YtAudioHandler song song
├── screens/
│   └── home_screen.dart                # Màn hình chính chứa InAppWebView, allowlist domain, lifecycle & fullscreen
└── services/
    ├── ad_block_service.dart           # Chặn domain/path quảng cáo, Content Blocker & script ẩn/skip ads
    ├── background_audio_service.dart   # JS giữ video phát khi app ở nền / tắt màn hình
    ├── media_bridge.dart               # Cầu nối JS <-> Flutter đồng bộ MediaSession
    └── media_session_service.dart      # YtAudioHandler quản lý notification & điều khiển media native

android/app/src/main/
├── AndroidManifest.xml                 # Quyền Foreground Service, WakeLock, Post Notifications, PiP, AudioService
└── kotlin/com/example/ytb_family/
    └── MainActivity.kt                 # AudioServiceActivity, WakeLock/WifiLock, giữ WebView active ở nền
```

## Yêu cầu môi trường

- Flutter SDK (Dart `^3.10.7`)
- Android SDK (compileSdk / targetSdk / minSdk cấu hình theo Flutter Gradle Plugin)
- Java 17

## Cài đặt & chạy ứng dụng

```bash
# 1. Cài đặt dependencies
flutter pub get

# 2. Kiểm tra phân tích tĩnh & test
flutter analyze
flutter test

# 3. Chạy trên thiết bị Android đang kết nối
flutter run

# 4. Build file APK release
flutter build apk --release
```

## Quyền Android sử dụng

- `INTERNET` — Tải `https://m.youtube.com` và nội dung video.
- `FOREGROUND_SERVICE` & `FOREGROUND_SERVICE_MEDIA_PLAYBACK` — Duy trì tiến trình phát âm thanh khi ở nền.
- `WAKE_LOCK` — Giữ CPU/mạng hoạt động ổn định khi phát nhạc tắt màn hình.
- `POST_NOTIFICATIONS` — Hiển thị thông báo điều khiển media trên Android 13+.
