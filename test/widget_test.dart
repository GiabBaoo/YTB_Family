import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ytb_family/services/ad_block_service.dart';
import 'package:ytb_family/services/background_audio_service.dart';
import 'package:ytb_family/services/media_bridge.dart';

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

    test('provides AT_DOCUMENT_START network/JSON pruning & native YouTube CSS', () {
      final scripts = AdBlockService.initialUserScripts;
      expect(scripts.length, 2);

      final startScript = scripts[0];
      expect(startScript.injectionTime, UserScriptInjectionTime.AT_DOCUMENT_START);
      expect(startScript.source, contains('ytInitialPlayerResponse'));
      expect(startScript.source, contains('adPlacements'));
      expect(startScript.source, isNot(contains('window.fetch')));
      expect(startScript.source, contains('PREF=f6=400'));
      expect(startScript.source, contains('#0F0F0F'));
      expect(startScript.source, contains('ytm-pivot-bar-renderer'));

      final domScript = scripts[1];
      expect(domScript.injectionTime, UserScriptInjectionTime.AT_DOCUMENT_END);
      expect(domScript.source, contains('#movie_player'));
      expect(domScript.source, contains('POPUP_THROTTLE_MS'));
    });
  });

  group('BackgroundAudioService.userScript', () {
    test('injects at AT_DOCUMENT_START and overrides visibility, focus & pause APIs', () {
      final script = BackgroundAudioService.userScript;
      expect(script.injectionTime, UserScriptInjectionTime.AT_DOCUMENT_START);
      expect(script.source, contains("'hidden'"));
      expect(script.source, contains("'visibilityState'"));
      expect(script.source, contains("'visibilitychange'"));
      expect(script.source, contains("'pagehide'"));
      expect(script.source, contains("'freeze'"));
      expect(script.source, contains('hasFocus'));
      expect(script.source, contains('__ytbAppInBackground'));
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

      expect(MediaBridge.commandJs('play'), contains('"play"'));
      expect(MediaBridge.commandJs('seek', 42.5), contains('42.5'));
    });
  });
}
