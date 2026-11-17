import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ytb_family/services/ad_block_service.dart';
import 'package:ytb_family/services/background_audio_service.dart';
import 'package:ytb_family/services/media_bridge.dart';
import 'package:ytb_family/services/media_session_service.dart';

void main() {
  group('AdBlockService.shouldBlockUrl', () {
    test('blocks Google ad domains', () {
      expect(
        AdBlockService.shouldBlockUrl(
          WebUri('https://pagead2.googlesyndication.com/pagead/js/adsbygoogle.js'),
        ),
        isTrue,
      );
      expect(
        AdBlockService.shouldBlockUrl(
          WebUri('https://pubads.g.doubleclick.net/gampad/ads'),
        ),
        isTrue,
      );
    });

    test('blocks YouTube ad endpoints and never blocks googlevideo streams', () {
      expect(
        AdBlockService.shouldBlockUrl(
          WebUri('https://m.youtube.com/api/stats/ads?v=123'),
        ),
        isTrue,
      );
      expect(
        AdBlockService.shouldBlockUrl(
          WebUri('https://m.youtube.com/youtubei/v1/player/ad_break'),
        ),
        isTrue,
      );
      expect(
        AdBlockService.shouldBlockUrl(
          WebUri('https://rr1---sn-abc.googlevideo.com/videoplayback?expire=1&oad=1&ctier=L'),
        ),
        isFalse,
      );
    });

    test('allows normal YouTube, videoplayback, and Google Account URLs', () {
      expect(
        AdBlockService.shouldBlockUrl(WebUri('https://m.youtube.com/watch?v=dQw4w9WgXcQ')),
        isFalse,
      );
      expect(
        AdBlockService.shouldBlockUrl(
          WebUri('https://m.youtube.com/youtubei/v1/player'),
        ),
        isFalse,
      );
      expect(
        AdBlockService.shouldBlockUrl(
          WebUri('https://rr1---sn-abc.googlevideo.com/videoplayback?expire=1&itag=140'),
        ),
        isFalse,
      );
      expect(
        AdBlockService.shouldBlockUrl(WebUri('https://accounts.google.com/ServiceLogin')),
        isFalse,
      );
    });
  });

  group('AdBlockService.contentBlockers & initialUserScripts', () {
    test('provides native ContentBlocker rules for ad hosts and endpoints', () {
      final blockers = AdBlockService.contentBlockers;
      expect(blockers, isNotEmpty);
      expect(
        blockers.every((b) => b.action.type == ContentBlockerActionType.BLOCK),
        isTrue,
      );
      expect(
        blockers.any((b) => b.trigger.urlFilter.contains('doubleclick')),
        isTrue,
      );
    });

    test('provides AT_DOCUMENT_START network/JSON pruning, PREF merge & native CSS', () {
      final scripts = AdBlockService.initialUserScripts;
      expect(scripts.length, 2);

      final startScript = scripts[0];
      expect(startScript.injectionTime, UserScriptInjectionTime.AT_DOCUMENT_START);
      expect(startScript.source, contains('ytInitialPlayerResponse'));
      expect(startScript.source, contains('adPlacements'));
      expect(startScript.source, contains('window.fetch'));
      expect(startScript.source, contains('isBlockedBeaconUrl'));
      expect(startScript.source, contains('URLSearchParams'));
      expect(startScript.source, contains("params.set('f6', '400')"));
      expect(startScript.source, contains('/youtubei/v1/browse'));
      expect(startScript.source, contains('/youtubei/v1/search'));
      expect(startScript.source, contains('/youtubei/v1/reel/reel_watch_sequence'));
      expect(startScript.source, contains('doubleclick.net'));
      expect(startScript.source, contains('#0F0F0F'));
      expect(startScript.source, contains('ytm-pivot-bar-renderer'));
      expect(startScript.source, contains('ytb-pip-mode'));

      final domScript = scripts[1];
      expect(domScript.injectionTime, UserScriptInjectionTime.AT_DOCUMENT_END);
      expect(domScript.source, contains('#movie_player'));
      expect(domScript.source, contains('POPUP_THROTTLE_MS'));
      expect(domScript.source, contains('ytm-enforcement-message-view-model'));
      expect(domScript.source, contains('skipShortsAd'));
      expect(domScript.source, contains('sponsor.ajax.sponsorblock.org'));
    });
  });

  group('BackgroundAudioService.userScript', () {
    test('injects at AT_DOCUMENT_START and overrides visibility, focus, pause & system pause APIs', () {
      final script = BackgroundAudioService.userScript;
      expect(script.injectionTime, UserScriptInjectionTime.AT_DOCUMENT_START);
      expect(script.source, contains("'hidden'"));
      expect(script.source, contains("'visibilityState'"));
      expect(script.source, contains("'visibilitychange'"));
      expect(script.source, contains("'pagehide'"));
      expect(script.source, contains("'freeze'"));
      expect(script.source, contains('hasFocus'));
      expect(script.source, contains('__ytbAppInBackground'));
      expect(script.source, contains('__ytbSystemPausedAt'));
      expect(script.source, contains('__ytbSystemPause'));
      expect(script.source, contains('__ytbSystemResume'));
      expect(script.source, contains('ytbPauseCheck'));
      expect(script.source, contains('HTMLMediaElement.prototype.pause'));
      expect(script.source, contains('requestAnimationFrame'));
    });
  });

  group('MediaBridge', () {
    test('provides AT_DOCUMENT_START script and formats control commands', () {
      final script = MediaBridge.userScript;
      expect(script.injectionTime, UserScriptInjectionTime.AT_DOCUMENT_START);
      expect(script.source, contains('ytbMedia'));
      expect(script.source, contains('__ytbControl'));
      expect(script.source, contains('nexttrack'));
      expect(script.source, contains('previoustrack'));
      expect(script.source, contains('maxresdefault.jpg'));
      expect(script.source, contains('isWatchPage'));

      expect(MediaBridge.commandJs('play'), contains('"play"'));
      expect(MediaBridge.commandJs('seek', 42.5), contains('42.5'));
    });
  });

  group('YtAudioHandler', () {
    test('supports sleep timer cycling, rewind/fastForward, and system pause', () async {
      final sent = <String>[];
      final handler = YtAudioHandler()
        ..commandSender = (cmd, [arg]) async {
          sent.add('$cmd:${arg ?? ""}');
        };

      expect(handler.sleepTimerMinutes, 0);
      handler.cycleSleepTimer();
      expect(handler.sleepTimerMinutes, 15);
      handler.cycleSleepTimer();
      expect(handler.sleepTimerMinutes, 30);
      handler.cycleSleepTimer();
      expect(handler.sleepTimerMinutes, 60);
      handler.cycleSleepTimer();
      expect(handler.sleepTimerMinutes, 0);

      handler.updateFromWeb({
        'active': true,
        'id': 'abc',
        'title': 'Test',
        'artist': 'Channel',
        'duration': 120.0,
        'position': 30.0,
        'playing': true,
        'ended': false,
      });
      expect(handler.isPlaying, isTrue);

      await handler.fastForward();
      await handler.rewind();
      expect(sent.length, 2);
      expect(double.parse(sent[0].split(':')[1]), closeTo(40.0, 0.5));
      expect(double.parse(sent[1].split(':')[1]), closeTo(20.0, 0.5));

      handler.markSystemPaused();
      expect(handler.isPlaying, isFalse);
      await handler.stop();
    });
  });
}
