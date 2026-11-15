import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'screens/home_screen.dart';
import 'services/media_session_service.dart';

const Color kYouTubeDarkBackground = Color(0xFF0F0F0F);

void main() {
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
    debugPrint('YtAudioHandler.init failed: $e\n$st');
    return null;
  });

  runApp(YtFamilyApp(audioHandlerFuture: audioHandlerFuture));
}

class YtFamilyApp extends StatelessWidget {
  const YtFamilyApp({
    super.key,
    this.audioHandler,
    this.audioHandlerFuture,
  });

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
        audioHandler: audioHandler,
        audioHandlerFuture: audioHandlerFuture,
      ),
    );
  }
}
