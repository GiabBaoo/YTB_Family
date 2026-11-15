import 'dart:async';

import 'package:audio_service/audio_service.dart';

typedef MediaCommandSender = Future<void> Function(String command, [double? arg]);

/// MediaSession native: notification MediaStyle + màn hình khóa + nút tai nghe.
/// Âm thanh vẫn do WebView m.youtube phát; handler chỉ phản chiếu trạng thái và chuyển lệnh.
class YtAudioHandler extends BaseAudioHandler {
  YtAudioHandler();

  static const Duration _pauseDebounce = Duration(milliseconds: 1500);
  static const Duration _endedDebounce = Duration(seconds: 4);
  static const Duration _idleDebounce = Duration(seconds: 3);
  static const Duration _backgroundIdleDebounce = Duration(seconds: 20);
  static const Duration _userCommandWindow = Duration(seconds: 2);

  MediaCommandSender? commandSender;

  Timer? _pauseTimer;
  Timer? _idleTimer;
  DateTime _lastUserPauseAt = DateTime.fromMillisecondsSinceEpoch(0);
  bool _inBackground = false;

  bool get isPlaying => playbackState.value.playing;

  void setBackground(bool inBackground) {
    _inBackground = inBackground;
  }

  static Future<YtAudioHandler> init() {
    return AudioService.init(
      builder: YtAudioHandler.new,
      config: const AudioServiceConfig(
        androidNotificationChannelId: 'com.example.ytb_family.playback',
        androidNotificationChannelName: 'Phát nhạc YT Family',
        androidNotificationChannelDescription:
            'Điều khiển phát/tạm dừng/chuyển bài trên thông báo và màn hình khóa',
        androidNotificationIcon: 'drawable/ic_stat_ytb',
        androidStopForegroundOnPause: false,
      ),
    );
  }

  /// Nhận trạng thái từ JS bridge (`window.flutter_inappwebview.callHandler('ytbMedia', ...)`).
  void updateFromWeb(Map<dynamic, dynamic> data) {
    if (data['active'] != true) {
      _pauseTimer?.cancel();
      if (_inBackground && isPlaying && mediaItem.value != null) {
        // Giữ Foreground Service ở trạng thái buffering khi đang chuyển bài ở nền.
        _pushState(
          playing: true,
          position: playbackState.value.position,
          rate: playbackState.value.speed,
          processingState: AudioProcessingState.buffering,
        );
        _idleTimer ??= Timer(_backgroundIdleDebounce, _goIdle);
      } else {
        _idleTimer ??= Timer(_idleDebounce, _goIdle);
      }
      return;
    }
    _idleTimer?.cancel();
    _idleTimer = null;

    final id = (data['id'] as String?) ?? '';
    final title = (data['title'] as String?) ?? '';
    final artist = (data['artist'] as String?) ?? '';
    final art = (data['art'] as String?) ?? '';
    final duration = _seconds(data['duration']);
    final position = _seconds(data['position']) ?? Duration.zero;
    final rate = (data['rate'] as num?)?.toDouble() ?? 1.0;
    final playing = data['playing'] == true;
    final ended = data['ended'] == true;

    final current = mediaItem.value;
    if (current == null ||
        current.id != (id.isEmpty ? 'ytb_family' : id) ||
        current.title != title ||
        current.artist != artist ||
        current.duration != duration ||
        current.artUri?.toString() != art) {
      mediaItem.add(MediaItem(
        id: id.isEmpty ? 'ytb_family' : id,
        title: title.isEmpty ? 'YouTube' : title,
        artist: artist,
        artUri: art.isEmpty ? null : Uri.tryParse(art),
        duration: duration,
      ));
    }

    if (playing) {
      _pauseTimer?.cancel();
      _pushState(playing: true, position: position, rate: rate);
      return;
    }

    final userPaused =
        DateTime.now().difference(_lastUserPauseAt) < _userCommandWindow;
    if (!isPlaying || userPaused) {
      _pauseTimer?.cancel();
      _pushState(playing: false, position: position, rate: rate);
      return;
    }

    // Chờ một chút: lúc chuyển bài (autoplay/playlist) video tạm ở trạng thái paused/ended.
    if (ended && _inBackground) {
      _pushState(
        playing: true,
        position: position,
        rate: rate,
        processingState: AudioProcessingState.buffering,
      );
    }
    _pauseTimer?.cancel();
    _pauseTimer = Timer(ended ? _endedDebounce : _pauseDebounce, () {
      _pushState(playing: false, position: position, rate: rate);
    });
  }

  void _pushState({
    required bool playing,
    required Duration position,
    required double rate,
    AudioProcessingState processingState = AudioProcessingState.ready,
  }) {
    playbackState.add(playbackState.value.copyWith(
      controls: [
        MediaControl.skipToPrevious,
        playing ? MediaControl.pause : MediaControl.play,
        MediaControl.skipToNext,
      ],
      systemActions: const {MediaAction.seek},
      androidCompactActionIndices: const [0, 1, 2],
      processingState: processingState,
      playing: playing,
      updatePosition: position,
      speed: rate,
    ));
  }

  void _goIdle() {
    _idleTimer = null;
    _pauseTimer?.cancel();
    playbackState.add(playbackState.value.copyWith(
      playing: false,
      processingState: AudioProcessingState.idle,
    ));
  }

  static Duration? _seconds(Object? value) {
    if (value is! num || !value.isFinite || value < 0) return null;
    return Duration(milliseconds: (value * 1000).round());
  }

  Future<void> _send(String command, [double? arg]) async {
    final sender = commandSender;
    if (sender != null) await sender(command, arg);
  }

  @override
  Future<void> play() => _send('play');

  @override
  Future<void> pause() {
    _lastUserPauseAt = DateTime.now();
    return _send('pause');
  }

  @override
  Future<void> skipToNext() => _send('next');

  @override
  Future<void> skipToPrevious() => _send('prev');

  @override
  Future<void> seek(Duration position) =>
      _send('seek', position.inMilliseconds / 1000.0);

  @override
  Future<void> stop() async {
    await pause();
    _goIdle();
    await super.stop();
  }

  @override
  Future<void> onTaskRemoved() => stop();
}
