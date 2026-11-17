import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';

import 'screens/home_screen.dart';
import 'services/media_session_service.dart';

const Color kYouTubeDarkBackground = Color(0xFF0F0F0F);
const MethodChannel _kLifecycleChannel =
    MethodChannel('com.example.ytb_family/lifecycle');

Future<void> _ensureYouTubeDarkPrefCookie() async {
  try {
    final cm = CookieManager.instance();
    final ytUrl = WebUri('https://m.youtube.com');
    final cookies = await cm
        .getCookies(url: ytUrl)
        .timeout(const Duration(milliseconds: 250));
    String existingPref = '';
    for (final c in cookies) {
      if (c.name == 'PREF' && c.value != null) {
        existingPref = c.value.toString();
        break;
      }
    }
    final parts = existingPref
        .split('&')
        .where((p) => p.isNotEmpty && !p.startsWith('f6='))
        .toList();
    parts.add('f6=400');
    final mergedPref = parts.join('&');
    if (mergedPref != existingPref) {
      await cm
          .setCookie(
            url: ytUrl,
            name: 'PREF',
            value: mergedPref,
            domain: '.youtube.com',
            path: '/',
            isSecure: true,
          )
          .timeout(const Duration(milliseconds: 250));
    }
  } catch (e) {
    // ignore: avoid_print
    print('Failed to set PREF dark cookie: $e');
  }
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  SystemChrome.setSystemUIOverlayStyle(
    const SystemUiOverlayStyle(
      statusBarColor: kYouTubeDarkBackground,
      statusBarIconBrightness: Brightness.light,
      systemNavigationBarColor: kYouTubeDarkBackground,
      systemNavigationBarIconBrightness: Brightness.light,
    ),
  );

  // Khởi tạo AudioService song song để không chặn frame đầu tiên của WebView.
  final audioHandlerFuture = YtAudioHandler.init()
      .then<YtAudioHandler?>((handler) => handler)
      .catchError((Object e, StackTrace st) {
    final msg = 'YtAudioHandler.init failed: $e\n$st';
    // ignore: avoid_print
    print(msg);
    _kLifecycleChannel.invokeMethod<void>('logError', msg).catchError((_) {});
    return null;
  });

  await _ensureYouTubeDarkPrefCookie();

  String? initialUserAgent;
  try {
    initialUserAgent = await _kLifecycleChannel
        .invokeMethod<String>('getDefaultUserAgent')
        .timeout(const Duration(milliseconds: 250));
  } catch (_) {}

  runApp(YtFamilyApp(
    initialUserAgent: initialUserAgent,
    audioHandlerFuture: audioHandlerFuture,
  ));
}

class YtFamilyApp extends StatelessWidget {
  const YtFamilyApp({
    super.key,
    this.initialUserAgent,
    this.audioHandler,
    this.audioHandlerFuture,
  });

  final String? initialUserAgent;
  final YtAudioHandler? audioHandler;
  final Future<YtAudioHandler?>? audioHandlerFuture;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'YT Family',
      debugShowCheckedModeBanner: false,
      theme: ThemeData.dark(useMaterial3: true).copyWith(
        scaffoldBackgroundColor: kYouTubeDarkBackground,
        colorScheme: const ColorScheme.dark(
          surface: kYouTubeDarkBackground,
          primary: Color(0xFFFF0033),
        ),
      ),
      home: HomeScreen(
        initialUserAgent: initialUserAgent,
        audioHandler: audioHandler,
        audioHandlerFuture: audioHandlerFuture,
      ),
    );
  }
}
