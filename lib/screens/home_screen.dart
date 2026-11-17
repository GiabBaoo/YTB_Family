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
      '(KHTML, like Gecko) Chrome/131.0.0.0 Mobile Safari/537.36';

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
  PullToRefreshController? _pullToRefreshController;
  late final String _userAgent;
  YtAudioHandler? _audioHandler;
  Map<dynamic, dynamic>? _lastMediaData;
  final ValueNotifier<double> _progress = ValueNotifier<double>(0);
  Timer? _splashFallbackTimer;
  String? _pendingDeepLink;
  bool _pageCommitted = false;
  bool _showSplash = true;
  bool _splashRemoved = false;
  bool _hasNetworkError = false;
  bool _errorInCurrentLoad = false;
  bool _videoPlaying = false;
  bool _isWatchPage = false;
  int _videoWidth = 16;
  int _videoHeight = 9;
  bool _inForeground = true;
  bool _wakelockOn = false;
  bool _isFullscreen = false;
  bool _isInPip = false;
  bool _requestedNotificationPermission = false;
  bool _checkedBatteryOptimization = false;
  bool _audioInitCompleted = false;
  bool _retriedAudioInit = false;
  bool _showLoginPrompt = false;
  bool _loginPromptDismissed = false;
  bool _flushedAfterLogin = false;
  Orientation? _lastOrientation;

  @override
  void initState() {
    super.initState();
    _userAgent = widget.initialUserAgent ?? _defaultUa;
    WidgetsBinding.instance.addObserver(this);

    if (defaultTargetPlatform == TargetPlatform.android) {
      _pullToRefreshController = PullToRefreshController(
        settings: PullToRefreshSettings(
          color: _ytRed,
          backgroundColor: _bgColor,
        ),
        onRefresh: () async {
          if (_isFullscreen || _isInPip) {
            await _pullToRefreshController?.endRefreshing();
            return;
          }
          await _webViewController?.reload();
        },
      );
    }

    _lifecycleChannel.setMethodCallHandler(_handleNativeCall);
    _lifecycleChannel.invokeMethod<String>('getInitialLink').then((link) {
      if (!mounted || link == null || link.isEmpty) return;
      final controller = _webViewController;
      if (controller != null) {
        controller.loadUrl(urlRequest: URLRequest(url: WebUri(link)));
      } else {
        _pendingDeepLink = link;
      }
    }).catchError((_) {});

    _audioHandler = widget.audioHandler;
    _audioHandler?.commandSender = _sendMediaCommand;
    if (_audioHandler != null) {
      _audioInitCompleted = true;
    }
    widget.audioHandlerFuture?.then((handler) {
      _audioInitCompleted = true;
      if (!mounted || handler == null) return;
      _audioHandler = handler;
      handler.commandSender = _sendMediaCommand;
      handler.setBackground(!_inForeground);
      if (_lastMediaData != null) {
        handler.updateFromWeb(_lastMediaData!);
      }
    });

    _splashFallbackTimer = Timer(
      const Duration(milliseconds: 1800),
      _dismissSplash,
    );
  }

  Future<dynamic> _handleNativeCall(MethodCall call) async {
    switch (call.method) {
      case 'onPipChanged':
        final inPip = call.arguments == true;
        _webViewController?.evaluateJavascript(
          source: 'window.__ytbSetPip && window.__ytbSetPip($inPip);',
        );
        if (mounted && _isInPip != inPip) {
          setState(() {
            _isInPip = inPip;
          });
        }
        break;
      case 'onNativeResume':
        final inPip = call.arguments == true;
        _inForeground = true;
        _audioHandler?.setBackground(false);
        _webViewController?.evaluateJavascript(
          source: BackgroundAudioService.setBackgroundJs(false),
        );
        if (!inPip) {
          _webViewController?.evaluateJavascript(
            source: 'window.__ytbSetPip && window.__ytbSetPip(false);',
          );
          if (mounted && _isInPip) {
            setState(() {
              _isInPip = false;
            });
          }
        }
        _webViewController?.resumeTimers();
        _webViewController?.resume();
        _syncWakelock();
        break;
      case 'onDeepLink':
        final url = call.arguments as String?;
        if (url != null && url.isNotEmpty) {
          await _webViewController?.loadUrl(
            urlRequest: URLRequest(url: WebUri(url)),
          );
        }
        break;
      case 'onSystemPause':
        _audioHandler?.markSystemPaused();
        break;
      case 'onNotificationPermissionDenied':
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: const Text(
                'Cần quyền thông báo để hiện điều khiển nhạc trên màn hình khóa.',
              ),
              action: SnackBarAction(
                label: 'Cài đặt',
                onPressed: () {
                  _lifecycleChannel
                      .invokeMethod<void>('openNotificationSettings')
                      .catchError((_) {});
                },
              ),
              duration: const Duration(seconds: 6),
            ),
          );
        }
        break;
    }
    return null;
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
    _lifecycleChannel.setMethodCallHandler(null);
    WidgetsBinding.instance.removeObserver(this);
    _audioHandler?.commandSender = null;
    _progress.dispose();
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);
    WakelockPlus.disable();
    super.dispose();
  }

  @override
  void didChangeMetrics() {
    super.didChangeMetrics();
    if (!mounted || _isInPip || !_inForeground) return;
    final view = WidgetsBinding.instance.platformDispatcher.views.firstOrNull;
    if (view == null) return;
    final size = view.physicalSize;
    final orientation =
        size.width > size.height ? Orientation.landscape : Orientation.portrait;
    if (orientation == _lastOrientation) return;
    _lastOrientation = orientation;

    if (!_isWatchPage || _videoHeight > _videoWidth) return;
    if (orientation == Orientation.landscape && !_isFullscreen) {
      _webViewController?.evaluateJavascript(source: _enterFullscreenJs);
    } else if (orientation == Orientation.portrait && _isFullscreen) {
      _webViewController?.evaluateJavascript(
        source: 'if (document.fullscreenElement) document.exitFullscreen().catch(function(){});',
      );
    }
  }

  static const String _enterFullscreenJs = r'''
(function() {
  if (document.fullscreenElement) return;
  const btn = document.querySelector('#movie_player .fullscreen-icon, button.ytp-fullscreen-button');
  if (btn) { btn.click(); return; }
  const p = document.querySelector('#movie_player');
  if (p && p.requestFullscreen) { p.requestFullscreen().catch(function(){}); }
})();
''';

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final controller = _webViewController;
    if (controller == null) return;

    switch (state) {
      case AppLifecycleState.inactive:
        if (_isInPip) return;
        // Đánh dấu nền sớm để chặn .pause() của Chromium trước khi sang paused.
        _inForeground = false;
        _audioHandler?.setBackground(true);
        controller.evaluateJavascript(
          source: BackgroundAudioService.setBackgroundJs(true),
        );
        break;
      case AppLifecycleState.hidden:
      case AppLifecycleState.paused:
        if (_isInPip) return;
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
        if (!_isInPip) {
          controller.evaluateJavascript(
            source: 'window.__ytbSetPip && window.__ytbSetPip(false);',
          );
        }
        controller.resumeTimers();
        controller.resume();
        _retryAudioInitIfNeeded();
        break;
      case AppLifecycleState.detached:
        break;
    }
    _syncWakelock();
  }

  Future<void> _retryAudioInitIfNeeded() async {
    if (!_audioInitCompleted || _audioHandler != null || _retriedAudioInit) {
      return;
    }
    _retriedAudioInit = true;
    try {
      final handler = await YtAudioHandler.init();
      if (!mounted) return;
      _audioHandler = handler;
      handler.commandSender = _sendMediaCommand;
      handler.setBackground(!_inForeground);
      if (_lastMediaData != null) {
        handler.updateFromWeb(_lastMediaData!);
      }
    } catch (e, st) {
      final msg = 'YtAudioHandler retry failed: $e\n$st';
      // ignore: avoid_print
      print(msg);
      _lifecycleChannel.invokeMethod<void>('logError', msg).catchError((_) {});
    }
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

    final active = data['active'] == true;
    final playing = active && data['playing'] == true;
    final watchPage = active && data['isWatchPage'] == true;
    final vw = (data['videoWidth'] as num?)?.toInt() ?? 16;
    final vh = (data['videoHeight'] as num?)?.toInt() ?? 9;

    if (watchPage != _isWatchPage || vw != _videoWidth || vh != _videoHeight) {
      _isWatchPage = watchPage;
      _videoWidth = vw > 0 ? vw : 16;
      _videoHeight = vh > 0 ? vh : 9;
      _lifecycleChannel.invokeMethod<void>('setWatchState', {
        'isWatchPage': _isWatchPage,
        'width': _videoWidth,
        'height': _videoHeight,
      }).catchError((_) {});

      if (!_isFullscreen) {
        SystemChrome.setPreferredOrientations(
          _isWatchPage
              ? const [
                  DeviceOrientation.portraitUp,
                  DeviceOrientation.landscapeLeft,
                  DeviceOrientation.landscapeRight,
                ]
              : const [DeviceOrientation.portraitUp],
        );
      }
    }

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
      if (playing && !_checkedBatteryOptimization) {
        _checkedBatteryOptimization = true;
        _promptBatteryOptimizationIfNeeded();
      }
    }
    _syncWakelock();
  }

  Future<void> _promptBatteryOptimizationIfNeeded() async {
    if (defaultTargetPlatform != TargetPlatform.android) return;
    try {
      final ignoring = await _lifecycleChannel
          .invokeMethod<bool>('isIgnoringBatteryOptimizations');
      if (ignoring != true && mounted) {
        await showDialog<void>(
          context: context,
          builder: (ctx) => AlertDialog(
            backgroundColor: const Color(0xFF1E1E1E),
            title: const Text(
              'Cho phép chạy nền ổn định',
              style: TextStyle(color: Colors.white, fontSize: 17),
            ),
            content: const Text(
              'Để không bị tắt nhạc khi khóa màn hình, hãy tắt tối ưu pin cho YT Family trong cài đặt hệ thống.',
              style: TextStyle(color: Color(0xFFCCCCCC), fontSize: 14),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(ctx).pop(),
                child: const Text('Để sau', style: TextStyle(color: Colors.grey)),
              ),
              FilledButton(
                style: FilledButton.styleFrom(backgroundColor: _ytRed),
                onPressed: () {
                  Navigator.of(ctx).pop();
                  _lifecycleChannel
                      .invokeMethod<void>('requestIgnoreBatteryOptimizations')
                      .catchError((_) {});
                },
                child: const Text('Mở cài đặt'),
              ),
            ],
          ),
        );
      }
      await _promptSamsungSleepGuideIfNeeded();
    } catch (_) {}
  }

  Future<void> _promptSamsungSleepGuideIfNeeded() async {
    if (!mounted || defaultTargetPlatform != TargetPlatform.android) return;
    try {
      final isSamsung =
          await _lifecycleChannel.invokeMethod<bool>('isSamsungDevice') ?? false;
      if (!isSamsung) return;
      final shown = await _lifecycleChannel
              .invokeMethod<bool>('hasShownSamsungSleepGuide') ??
          true;
      if (shown || !mounted) return;
      await _lifecycleChannel.invokeMethod<void>('markSamsungSleepGuideShown');
      if (!mounted) return;
      await showDialog<void>(
        context: context,
        builder: (ctx) => AlertDialog(
          backgroundColor: const Color(0xFF1E1E1E),
          title: const Text(
            'Thiết lập pin trên Samsung',
            style: TextStyle(color: Colors.white, fontSize: 17),
          ),
          content: const Text(
            'Trên máy Samsung, hãy vào Pin → Giới hạn sử dụng nền → Ứng dụng không bao giờ ngủ và thêm YT Family để không bị tắt điều khiển nhạc ở màn hình khóa.',
            style: TextStyle(color: Color(0xFFCCCCCC), fontSize: 14),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(),
              child: const Text('Đã hiểu', style: TextStyle(color: Colors.grey)),
            ),
            FilledButton(
              style: FilledButton.styleFrom(backgroundColor: _ytRed),
              onPressed: () {
                Navigator.of(ctx).pop();
                _lifecycleChannel
                    .invokeMethod<void>('openBatteryBackgroundSettings')
                    .catchError((_) {});
              },
              child: const Text('Mở cài đặt pin'),
            ),
          ],
        ),
      );
    } catch (_) {}
  }

  Future<void> _loginWithDeviceAccount() async {
    try {
      final email =
          await _lifecycleChannel.invokeMethod<String>('chooseGoogleAccount');
      if (!mounted || email == null || email.isEmpty) return;
      setState(() {
        _showLoginPrompt = false;
      });
      final loginUrl =
          'https://accounts.google.com/ServiceLogin?service=youtube'
          '&continue=${Uri.encodeComponent('https://m.youtube.com/')}'
          '&Email=${Uri.encodeComponent(email)}';
      await _webViewController?.loadUrl(
        urlRequest: URLRequest(url: WebUri(loginUrl)),
      );
    } catch (_) {}
  }

  Future<void> _checkAuthCookiesAndChannel(WebUri? url) async {
    if (url == null) return;
    final host = url.host.toLowerCase();
    if (!host.endsWith('youtube.com')) return;
    try {
      final cookies = await CookieManager.instance()
          .getCookies(url: WebUri('https://m.youtube.com'));
      final hasAuth = cookies.any(
        (c) =>
            (c.name == 'SAPISID' ||
                c.name == 'LOGIN_INFO' ||
                c.name == '__Secure-3PAPISID') &&
            (c.value?.toString().isNotEmpty ?? false),
      );
      if (!mounted) return;
      if (hasAuth) {
        if (_showLoginPrompt) {
          setState(() => _showLoginPrompt = false);
        }
        if (!_flushedAfterLogin) {
          _flushedAfterLogin = true;
          _lifecycleChannel.invokeMethod<void>('flushCookies').catchError((_) {});
        }
      } else {
        _flushedAfterLogin = false;
        if (!_loginPromptDismissed && !_showLoginPrompt) {
          setState(() => _showLoginPrompt = true);
        }
      }
      await _injectChannelHelper();
    } catch (_) {}
  }

  Future<void> _injectChannelHelper() async {
    final controller = _webViewController;
    if (controller == null) return;
    try {
      final savedChannel =
          await _lifecycleChannel.invokeMethod<String>('getSelectedChannel') ??
              '';
      final escaped = savedChannel
          .replaceAll(r'\', r'\\')
          .replaceAll("'", r"\'")
          .replaceAll('\n', ' ');
      await controller.evaluateJavascript(source: '''
(function() {
  if (!window.__ytbChannelListenerAdded) {
    window.__ytbChannelListenerAdded = true;
    document.addEventListener('click', function(e) {
      var item = e.target && e.target.closest ? e.target.closest('ytm-account-item-renderer, ytd-account-item-renderer') : null;
      if (!item) return;
      var text = (item.innerText || '').trim().split('\\n')[0].trim();
      if (text && window.flutter_inappwebview && window.flutter_inappwebview.callHandler) {
        window.flutter_inappwebview.callHandler('ytbSelectedChannel', text);
      }
    }, true);
  }
  var saved = '$escaped';
  if (!saved || window.__ytbChannelAutoClicked) return;
  var items = document.querySelectorAll('ytm-account-item-renderer, ytd-account-item-renderer');
  if (items.length > 1 && location.pathname.indexOf('/signin') !== -1) {
    for (var i = 0; i < items.length; i++) {
      var title = (items[i].innerText || '').trim().split('\\n')[0].trim();
      if (title === saved) {
        window.__ytbChannelAutoClicked = true;
        items[i].click();
        break;
      }
    }
  }
})();
''');
    } catch (_) {}
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
  if (location.pathname.startsWith('/watch')) {
    const minBtn = document.querySelector('.player-minimize-button, button[aria-label="Minimize"]');
    if (minBtn && minBtn.offsetParent !== null) {
      minBtn.click();
      return true;
    }
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
    final useSafeArea = !_isFullscreen && !_isInPip;
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
          top: useSafeArea,
          bottom: useSafeArea,
          left: useSafeArea,
          right: useSafeArea,
          child: Stack(
            children: [
              InAppWebView(
                initialUrlRequest: URLRequest(
                  url: _pendingDeepLink != null
                      ? WebUri(_pendingDeepLink!)
                      : _youtubeUrl,
                ),
                pullToRefreshController: _pullToRefreshController,
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
                  disableLongPressContextMenuOnLinks: true,
                  textZoom: 100,
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
                  algorithmicDarkeningAllowed: false,
                ),
                onWebViewCreated: (controller) {
                  _webViewController = controller;
                  if (_pendingDeepLink != null) {
                    _pendingDeepLink = null;
                  }
                  _lifecycleChannel
                      .invokeMethod<void>('configureWebViewFeatures')
                      .catchError((_) {});
                  controller.addJavaScriptHandler(
                    handlerName: 'ytbSelectedChannel',
                    callback: (args) {
                      if (args.isNotEmpty && args.first is String) {
                        _lifecycleChannel
                            .invokeMethod<void>('setSelectedChannel', args.first)
                            .catchError((_) {});
                      }
                    },
                  );
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
                  controller.addJavaScriptHandler(
                    handlerName: 'ytbContentReady',
                    callback: (_) {
                      _dismissSplash();
                    },
                  );
                  controller.addJavaScriptHandler(
                    handlerName: 'ytbPauseCheck',
                    callback: (_) async {
                      try {
                        return await _lifecycleChannel
                                .invokeMethod<bool>('isOtherAudioActive') ??
                            false;
                      } catch (_) {
                        return false;
                      }
                    },
                  );
                },
                shouldOverrideUrlLoading: (controller, navigationAction) async {
                  final url = navigationAction.request.url;
                  if (AdBlockService.shouldBlockUrl(url)) {
                    return NavigationActionPolicy.CANCEL;
                  }
                  if (_isAllowedUrl(url)) {
                    return NavigationActionPolicy.ALLOW;
                  }
                  if (url != null &&
                      (url.scheme == 'http' || url.scheme == 'https') &&
                      (navigationAction.isForMainFrame)) {
                    _lifecycleChannel
                        .invokeMethod<bool>('openExternalUrl', url.toString())
                        .catchError((_) => false);
                  }
                  return NavigationActionPolicy.CANCEL;
                },
                onLoadStart: (controller, url) {
                  final urlStr = url?.toString() ?? '';
                  if (!urlStr.startsWith('chrome-error:')) {
                    _errorInCurrentLoad = false;
                  }
                },
                onLoadStop: (controller, url) {
                  _pullToRefreshController?.endRefreshing();
                  if (!mounted) return;
                  _progress.value = 1.0;
                  if (!_requestedNotificationPermission) {
                    _requestedNotificationPermission = true;
                    _lifecycleChannel
                        .invokeMethod<void>('requestNotificationPermission')
                        .catchError((_) {});
                  }
                  if (_showSplash || (_hasNetworkError && !_errorInCurrentLoad)) {
                    setState(() {
                      _showSplash = false;
                      if (!_errorInCurrentLoad) {
                        _hasNetworkError = false;
                      }
                    });
                  }
                  _checkAuthCookiesAndChannel(url);
                },
                onReceivedError: (controller, request, error) {
                  _pullToRefreshController?.endRefreshing();
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
                  if (_showSplash && _progress.value >= 0.70) {
                    _dismissSplash();
                  }
                },
                onProgressChanged: (controller, progress) {
                  _pullToRefreshController?.endRefreshing();
                  if (!mounted) return;
                  final normalized = progress / 100.0;
                  _progress.value = normalized;
                  if (_showSplash &&
                      ((_pageCommitted && normalized >= 0.70) ||
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
                  if (_videoHeight > _videoWidth) {
                    await SystemChrome.setPreferredOrientations([
                      DeviceOrientation.portraitUp,
                    ]);
                  } else {
                    await SystemChrome.setPreferredOrientations([
                      DeviceOrientation.landscapeLeft,
                      DeviceOrientation.landscapeRight,
                    ]);
                  }
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
                  await SystemChrome.setPreferredOrientations(
                    _isWatchPage
                        ? const [
                            DeviceOrientation.portraitUp,
                            DeviceOrientation.landscapeLeft,
                            DeviceOrientation.landscapeRight,
                          ]
                        : const [DeviceOrientation.portraitUp],
                  );
                },
              ),
              if (_hasNetworkError) _OfflineRetryOverlay(onRetry: _retryLoad),
              if (_showLoginPrompt &&
                  !_showSplash &&
                  !_hasNetworkError &&
                  !_isFullscreen &&
                  !_isInPip)
                Positioned(
                  left: 16,
                  right: 16,
                  bottom: 16,
                  child: Material(
                    color: const Color(0xFF212121),
                    elevation: 6,
                    borderRadius: BorderRadius.circular(28),
                    child: Padding(
                      padding: const EdgeInsets.only(left: 14, right: 6, top: 6, bottom: 6),
                      child: Row(
                        children: [
                          const Icon(Icons.account_circle_outlined, color: Colors.white, size: 22),
                          const SizedBox(width: 10),
                          Expanded(
                            child: InkWell(
                              onTap: _loginWithDeviceAccount,
                              child: const Padding(
                                padding: EdgeInsets.symmetric(vertical: 6),
                                child: Text(
                                  'Đăng nhập bằng tài khoản trên máy',
                                  style: TextStyle(
                                    color: Colors.white,
                                    fontSize: 13.5,
                                    fontWeight: FontWeight.w500,
                                  ),
                                ),
                              ),
                            ),
                          ),
                          IconButton(
                            icon: const Icon(Icons.close, color: Color(0xFFAAAAAA), size: 18),
                            visualDensity: VisualDensity.compact,
                            onPressed: () {
                              setState(() {
                                _loginPromptDismissed = true;
                                _showLoginPrompt = false;
                              });
                            },
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
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
                            _isFullscreen ||
                            _isInPip) {
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
