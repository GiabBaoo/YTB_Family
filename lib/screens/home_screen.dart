import 'dart:async';
import 'dart:collection';

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import '../services/ad_block_service.dart';
import '../services/background_audio_service.dart';
import '../services/media_bridge.dart';
import '../services/media_session_service.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({
    super.key,
    this.initialUserAgent,
    this.audioHandler,
    this.audioHandlerFuture,
  });

  final String? initialUserAgent;
  final YtAudioHandler? audioHandler;
  final Future<YtAudioHandler?>? audioHandlerFuture;

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> with WidgetsBindingObserver {
  static const Color _bgColor = Color(0xFF0F0F0F);
  static const Color _ytRed = Color(0xFFFF0033);
  static const MethodChannel _lifecycleChannel =
      MethodChannel('com.example.ytb_family/lifecycle');
  static const String _defaultUa =
      'Mozilla/5.0 (Linux; Android 14; Pixel 8) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/124.0.0.0 Mobile Safari/537.36';

  static final WebUri _youtubeUrl = WebUri('https://m.youtube.com');
  static const List<String> _allowedDomains = [
    'youtube.com',
    'youtu.be',
    'youtube-nocookie.com',
    'googlevideo.com',
    'ytimg.com',
    'ggpht.com',
    'google.com',
    'gstatic.com',
    'googleapis.com',
    'googleusercontent.com',
  ];

  InAppWebViewController? _webViewController;
  late final String _userAgent;
  YtAudioHandler? _audioHandler;
  Map<dynamic, dynamic>? _lastMediaData;
  final ValueNotifier<double> _progress = ValueNotifier<double>(0);
  Timer? _splashFallbackTimer;
  bool _pageCommitted = false;
  bool _showSplash = true;
  bool _splashRemoved = false;
  bool _hasNetworkError = false;
  bool _errorInCurrentLoad = false;
  bool _videoPlaying = false;
  bool _inForeground = true;
  bool _wakelockOn = false;
  bool _isFullscreen = false;
  bool _requestedNotificationPermission = false;

  @override
  void initState() {
    super.initState();
    _userAgent = widget.initialUserAgent ?? _defaultUa;
    WidgetsBinding.instance.addObserver(this);
    _audioHandler = widget.audioHandler;
    _audioHandler?.commandSender = _sendMediaCommand;
    widget.audioHandlerFuture?.then((handler) {
      if (!mounted || handler == null) return;
      _audioHandler = handler;
      handler.commandSender = _sendMediaCommand;
      handler.setBackground(!_inForeground);
      if (_lastMediaData != null) {
        handler.updateFromWeb(_lastMediaData!);
      }
    });
    _splashFallbackTimer = Timer(
      const Duration(milliseconds: 2800),
      _dismissSplash,
    );
  }

  void _dismissSplash() {
    _splashFallbackTimer?.cancel();
    if (!mounted || !_showSplash) return;
    setState(() {
      _showSplash = false;
    });
  }

  @override
  void dispose() {
    _splashFallbackTimer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    _audioHandler?.commandSender = null;
    _progress.dispose();
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);
    WakelockPlus.disable();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final controller = _webViewController;
    if (controller == null) return;

    switch (state) {
      case AppLifecycleState.inactive:
        // Đánh dấu nền sớm để chặn .pause() của Chromium trước khi sang paused.
        _inForeground = false;
        _audioHandler?.setBackground(true);
        controller.evaluateJavascript(
          source: BackgroundAudioService.setBackgroundJs(true),
        );
        break;
      case AppLifecycleState.hidden:
      case AppLifecycleState.paused:
        _inForeground = false;
        _audioHandler?.setBackground(true);
        controller.evaluateJavascript(
          source: BackgroundAudioService.setBackgroundJs(true),
        );
        controller.resumeTimers();
        controller.resume();
        break;
      case AppLifecycleState.resumed:
        _inForeground = true;
        _audioHandler?.setBackground(false);
        controller.evaluateJavascript(
          source: BackgroundAudioService.setBackgroundJs(false),
        );
        controller.resumeTimers();
        break;
      case AppLifecycleState.detached:
        break;
    }
    _syncWakelock();
  }

  Future<void> _sendMediaCommand(String command, [double? arg]) async {
    await _webViewController?.evaluateJavascript(
      source: MediaBridge.commandJs(command, arg),
    );
  }

  void _onMediaState(List<dynamic> args) {
    if (args.isEmpty || args.first is! Map) return;
    final data = args.first as Map<dynamic, dynamic>;
    _lastMediaData = data;
    _audioHandler?.updateFromWeb(data);
    final playing = data['active'] == true && data['playing'] == true;
    if (playing != _videoPlaying) {
      _videoPlaying = playing;
      _lifecycleChannel
          .invokeMethod<void>('setMediaPlaying', playing)
          .catchError((_) {});
      if (playing && !_inForeground) {
        _webViewController?.evaluateJavascript(
          source: BackgroundAudioService.setBackgroundJs(true),
        );
      }
      if (playing && !_requestedNotificationPermission) {
        _requestedNotificationPermission = true;
        _lifecycleChannel
            .invokeMethod<void>('requestNotificationPermission')
            .catchError((_) {});
      }
    }
    _syncWakelock();
  }

  /// Chỉ giữ sáng màn hình khi đang xem video ở foreground.
  void _syncWakelock() {
    final shouldOn = _videoPlaying && _inForeground;
    if (shouldOn == _wakelockOn) return;
    _wakelockOn = shouldOn;
    shouldOn ? WakelockPlus.enable() : WakelockPlus.disable();
  }

  bool _isAllowedUrl(WebUri? url) {
    if (url == null) return false;
    if (url.scheme == 'about') return true;
    if (url.scheme != 'http' && url.scheme != 'https') return false;
    final host = url.host.toLowerCase();
    return _allowedDomains.any(
      (domain) => host == domain || host.endsWith('.$domain'),
    );
  }

  static const String _closeOverlayJs = r'''
(function() {
  if (document.fullscreenElement) {
    try { document.exitFullscreen(); } catch (_) {}
    return true;
  }
  const closeSelectors = [
    'ytm-engagement-panel-section-list-renderer[visibility="ENGAGEMENT_PANEL_VISIBILITY_EXPANDED"] .engagement-panel-close-button button',
    'ytm-engagement-panel-section-list-renderer[visibility="ENGAGEMENT_PANEL_VISIBILITY_EXPANDED"] button[aria-label="Close"]',
    'ytm-bottom-sheet-renderer button[aria-label="Close"]',
    'tp-yt-paper-dialog:not([aria-hidden="true"]) button[aria-label="Close"]',
    'ytm-searchbox-overlay .topbar-back-button',
    '.mobile-topbar-header-content[data-mode="searching"] .topbar-back-button'
  ];
  for (let i = 0; i < closeSelectors.length; i++) {
    const btn = document.querySelector(closeSelectors[i]);
    if (btn && btn.offsetParent !== null) {
      btn.click();
      return true;
    }
  }
  const openOverlay = document.querySelector(
    'ytm-bottom-sheet-renderer, ytm-menu-popup-renderer, tp-yt-paper-dialog:not([aria-hidden="true"]), ' +
    'ytm-engagement-panel-section-list-renderer[visibility="ENGAGEMENT_PANEL_VISIBILITY_EXPANDED"]'
  );
  if (openOverlay && openOverlay.offsetParent !== null) {
    document.dispatchEvent(new KeyboardEvent('keydown', { key: 'Escape', keyCode: 27, bubbles: true }));
    return true;
  }
  return false;
})();
''';

  Future<void> _handleBackNavigation() async {
    final controller = _webViewController;
    if (controller != null) {
      try {
        final closedOverlay =
            await controller.evaluateJavascript(source: _closeOverlayJs);
        if (closedOverlay == true) return;
      } catch (_) {}

      if (await controller.canGoBack()) {
        await controller.goBack();
        return;
      }
    }

    try {
      await _lifecycleChannel.invokeMethod('moveTaskToBack');
    } catch (_) {
      await SystemNavigator.pop();
    }
  }

  Future<void> _retryLoad() async {
    setState(() {
      _hasNetworkError = false;
      _errorInCurrentLoad = false;
    });
    _progress.value = 0.05;
    final controller = _webViewController;
    if (controller == null) return;
    final currentUrl = await controller.getUrl();
    if (currentUrl == null ||
        currentUrl.toString().startsWith('about:') ||
        currentUrl.toString().startsWith('chrome-error:')) {
      await controller.loadUrl(urlRequest: URLRequest(url: _youtubeUrl));
    } else {
      await controller.reload();
    }
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) {
          _handleBackNavigation();
        }
      },
      child: Scaffold(
        backgroundColor: _bgColor,
        body: SafeArea(
          child: Stack(
            children: [
              InAppWebView(
                initialUrlRequest: URLRequest(url: _youtubeUrl),
                gestureRecognizers:
                    defaultTargetPlatform == TargetPlatform.android
                    ? <Factory<OneSequenceGestureRecognizer>>{
                        Factory<OneSequenceGestureRecognizer>(
                          () => EagerGestureRecognizer(),
                        ),
                      }
                    : null,
                initialUserScripts: UnmodifiableListView<UserScript>([
                  BackgroundAudioService.userScript,
                  MediaBridge.userScript,
                  ...AdBlockService.initialUserScripts,
                ]),
                initialSettings: InAppWebViewSettings(
                  userAgent: _userAgent,
                  javaScriptEnabled: true,
                  domStorageEnabled: true,
                  databaseEnabled: true,
                  thirdPartyCookiesEnabled: true,
                  mediaPlaybackRequiresUserGesture: false,
                  allowsInlineMediaPlayback: true,
                  allowsBackForwardNavigationGestures: true,
                  useShouldInterceptRequest: false,
                  useShouldOverrideUrlLoading: true,
                  contentBlockers:
                      defaultTargetPlatform == TargetPlatform.android
                      ? null
                      : AdBlockService.contentBlockers,
                  safeBrowsingEnabled: false,
                  cacheEnabled: true,
                  cacheMode: CacheMode.LOAD_DEFAULT,
                  hardwareAcceleration: true,
                  useHybridComposition: false,
                  offscreenPreRaster: true,
                  verticalScrollBarEnabled: false,
                  horizontalScrollBarEnabled: false,
                  overScrollMode: OverScrollMode.IF_CONTENT_SCROLLS,
                  allowBackgroundAudioPlaying: true,
                  rendererPriorityPolicy: RendererPriorityPolicy(
                    rendererRequestedPriority:
                        RendererPriority.RENDERER_PRIORITY_IMPORTANT,
                    waivedWhenNotVisible: false,
                  ),
                  iframeAllowFullscreen: true,
                  supportZoom: false,
                  builtInZoomControls: false,
                  displayZoomControls: false,
                  mixedContentMode:
                      MixedContentMode.MIXED_CONTENT_COMPATIBILITY_MODE,
                ),
                onWebViewCreated: (controller) {
                  _webViewController = controller;
                  controller.addJavaScriptHandler(
                    handlerName: MediaBridge.handlerName,
                    callback: _onMediaState,
                  );
                  controller.addJavaScriptHandler(
                    handlerName: 'ytbNetwork',
                    callback: (_) {
                      if (mounted && _hasNetworkError) {
                        _retryLoad();
                      }
                    },
                  );
                },
                shouldOverrideUrlLoading: (controller, navigationAction) async {
                  final url = navigationAction.request.url;
                  return _isAllowedUrl(url)
                      ? NavigationActionPolicy.ALLOW
                      : NavigationActionPolicy.CANCEL;
                },
                onLoadStart: (controller, url) {
                  final urlStr = url?.toString() ?? '';
                  if (!urlStr.startsWith('chrome-error:')) {
                    _errorInCurrentLoad = false;
                  }
                },
                onLoadStop: (controller, url) {
                  if (!mounted) return;
                  _progress.value = 1.0;
                  if (_showSplash || (_hasNetworkError && !_errorInCurrentLoad)) {
                    setState(() {
                      _showSplash = false;
                      if (!_errorInCurrentLoad) {
                        _hasNetworkError = false;
                      }
                    });
                  }
                },
                onReceivedError: (controller, request, error) {
                  if (request.isForMainFrame ?? true) {
                    if (!mounted) return;
                    _splashFallbackTimer?.cancel();
                    setState(() {
                      _errorInCurrentLoad = true;
                      _hasNetworkError = true;
                      _showSplash = false;
                    });
                  }
                },
                onPageCommitVisible: (controller, url) {
                  if (!mounted) return;
                  _pageCommitted = true;
                  if (_showSplash && _progress.value >= 0.75) {
                    _dismissSplash();
                  }
                },
                onProgressChanged: (controller, progress) {
                  if (!mounted) return;
                  final normalized = progress / 100.0;
                  _progress.value = normalized;
                  if (_showSplash &&
                      ((_pageCommitted && normalized >= 0.75) ||
                          normalized >= 0.90)) {
                    _dismissSplash();
                  }
                },
                onEnterFullscreen: (controller) async {
                  if (mounted) {
                    setState(() {
                      _isFullscreen = true;
                    });
                  }
                  await SystemChrome.setEnabledSystemUIMode(
                    SystemUiMode.immersiveSticky,
                  );
                  await SystemChrome.setPreferredOrientations([
                    DeviceOrientation.landscapeLeft,
                    DeviceOrientation.landscapeRight,
                  ]);
                },
                onExitFullscreen: (controller) async {
                  if (mounted) {
                    setState(() {
                      _isFullscreen = false;
                    });
                  }
                  await SystemChrome.setEnabledSystemUIMode(
                    SystemUiMode.edgeToEdge,
                  );
                  await SystemChrome.setPreferredOrientations([
                    DeviceOrientation.portraitUp,
                  ]);
                },
              ),
              if (_hasNetworkError) _OfflineRetryOverlay(onRetry: _retryLoad),
              if (!_splashRemoved)
                IgnorePointer(
                  ignoring: !_showSplash,
                  child: AnimatedOpacity(
                    opacity: _showSplash ? 1.0 : 0.0,
                    duration: const Duration(milliseconds: 150),
                    curve: Curves.easeOut,
                    onEnd: () {
                      if (!_showSplash && mounted) {
                        setState(() {
                          _splashRemoved = true;
                        });
                      }
                    },
                    child: const _YouTubeSplashOverlay(),
                  ),
                ),
              Positioned(
                top: 0,
                left: 0,
                right: 0,
                child: IgnorePointer(
                  child: RepaintBoundary(
                    child: ValueListenableBuilder<double>(
                      valueListenable: _progress,
                      builder: (context, value, _) {
                        if (value <= 0 ||
                            value >= 1.0 ||
                            _hasNetworkError ||
                            _isFullscreen) {
                          return const SizedBox.shrink();
                        }
                        return LinearProgressIndicator(
                          value: value,
                          minHeight: 1.5,
                          backgroundColor: Colors.transparent,
                          valueColor: const AlwaysStoppedAnimation<Color>(_ytRed),
                        );
                      },
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _YouTubeSplashOverlay extends StatelessWidget {
  const _YouTubeSplashOverlay();

  @override
  Widget build(BuildContext context) {
    return Container(
      color: const Color(0xFF0F0F0F),
      alignment: Alignment.center,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 76,
            height: 54,
            decoration: BoxDecoration(
              color: const Color(0xFFFF0033),
              borderRadius: BorderRadius.circular(14),
            ),
            child: const Icon(
              Icons.play_arrow_rounded,
              color: Colors.white,
              size: 40,
            ),
          ),
          const SizedBox(height: 16),
          const Text(
            'YT Family',
            style: TextStyle(
              color: Colors.white,
              fontSize: 20,
              fontWeight: FontWeight.w600,
              letterSpacing: 0.3,
            ),
          ),
        ],
      ),
    );
  }
}

class _OfflineRetryOverlay extends StatelessWidget {
  const _OfflineRetryOverlay({required this.onRetry});

  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Container(
      color: const Color(0xFF0F0F0F),
      padding: const EdgeInsets.symmetric(horizontal: 32),
      alignment: Alignment.center,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(
            Icons.wifi_off_rounded,
            color: Color(0xFFAAAAAA),
            size: 64,
          ),
          const SizedBox(height: 20),
          const Text(
            'Không có kết nối mạng',
            textAlign: TextAlign.center,
            style: TextStyle(
              color: Colors.white,
              fontSize: 18,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 8),
          const Text(
            'Vui lòng kiểm tra Wi-Fi hoặc dữ liệu di động và thử lại.',
            textAlign: TextAlign.center,
            style: TextStyle(
              color: Color(0xFFAAAAAA),
              fontSize: 14,
            ),
          ),
          const SizedBox(height: 24),
          FilledButton.icon(
            onPressed: onRetry,
            style: FilledButton.styleFrom(
              backgroundColor: const Color(0xFFFF0033),
              foregroundColor: Colors.white,
              padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(24),
              ),
            ),
            icon: const Icon(Icons.refresh_rounded, size: 20),
            label: const Text(
              'Thử lại',
              style: TextStyle(fontWeight: FontWeight.w600),
            ),
          ),
        ],
      ),
    );
  }
}
