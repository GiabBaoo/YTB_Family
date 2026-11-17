import 'package:flutter_inappwebview/flutter_inappwebview.dart';

/// JS giữ video chính phát tiếp khi app ở nền / tắt màn hình.
/// Foreground service + notification do [YtAudioHandler] (audio_service) đảm nhiệm.
class BackgroundAudioService {
  BackgroundAudioService._();

  static final UserScript userScript = UserScript(
    groupName: 'ytb_family_background_audio',
    source: _backgroundPlaybackJs,
    injectionTime: UserScriptInjectionTime.AT_DOCUMENT_START,
  );

  /// JS gọi khi app chuyển nền / quay lại.
  static String setBackgroundJs(bool background) =>
      'window.__ytbSetBackground && window.__ytbSetBackground($background);';

  static const String _backgroundPlaybackJs = r'''
(function() {
  if (window.__ytbFamilyBgAudioActive) return;
  window.__ytbFamilyBgAudioActive = true;
  window.__ytbAppInBackground = false;
  window.__ytbUserCommandAt = 0;
  window.__ytbSystemPausedAt = 0;

  const USER_INTERACTION_WINDOW_MS = 1000;
  const SYSTEM_PAUSE_WINDOW_MS = 2000;
  const RESUME_DELAYS = [150, 300, 600, 1000, 2000];
  const MAX_RESUME_ATTEMPTS = RESUME_DELAYS.length;
  const RESUME_WINDOW_MS = 10000;
  const BACKGROUND_FRAME_STEADY_MS = 250;
  const BACKGROUND_FRAME_TRANSITION_MS = 100;
  const WATCHDOG_INTERVAL_MS = 1000;
  let lastPlayerInteractionAt = 0;
  let wasPlayingBeforeEnded = false;
  let watchdogTimer = null;

  function markUserInteraction(e) {
    if (e && e.isTrusted === false) return;
    if (e && e.type === 'keydown') {
      const k = e.key;
      if (k !== ' ' && k !== 'k' && k !== 'K' &&
          k !== 'MediaPlayPause' && k !== 'MediaPause' && k !== 'MediaStop') {
        return;
      }
    }
    lastPlayerInteractionAt = Date.now();
  }

  function hasRecentUserCommand() {
    return (Date.now() - (window.__ytbUserCommandAt || 0)) < USER_INTERACTION_WINDOW_MS ||
      (Date.now() - (window.__ytbSystemPausedAt || 0)) < SYSTEM_PAUSE_WINDOW_MS;
  }

  function isUserPause() {
    if (hasRecentUserCommand()) return true;
    return (Date.now() - lastPlayerInteractionAt) < USER_INTERACTION_WINDOW_MS;
  }

  function defineVisibleProperty(target, prop, value) {
    try {
      Object.defineProperty(target, prop, {
        configurable: true,
        enumerable: true,
        get: function() { return value; }
      });
    } catch (_) {}
  }

  defineVisibleProperty(Document.prototype, 'hidden', false);
  defineVisibleProperty(Document.prototype, 'webkitHidden', false);
  defineVisibleProperty(Document.prototype, 'visibilityState', 'visible');
  defineVisibleProperty(Document.prototype, 'webkitVisibilityState', 'visible');
  defineVisibleProperty(document, 'hidden', false);
  defineVisibleProperty(document, 'webkitHidden', false);
  defineVisibleProperty(document, 'visibilityState', 'visible');
  defineVisibleProperty(document, 'webkitVisibilityState', 'visible');

  try {
    Document.prototype.hasFocus = function() { return true; };
    document.hasFocus = function() { return true; };
  } catch (_) {}

  for (const prop of ['onvisibilitychange', 'onwebkitvisibilitychange', 'onpagehide', 'onfreeze']) {
    try {
      Object.defineProperty(Document.prototype, prop, {
        configurable: true,
        get: function() { return null; },
        set: function() {}
      });
    } catch (_) {}
  }

  // Chỉ chặn sự kiện ẩn trang. KHÔNG chặn blur/focusout (menu, bottom sheet, ô tìm kiếm cần chúng).
  const blockedEvents = ['visibilitychange', 'webkitvisibilitychange', 'pagehide', 'freeze'];
  function blockEvent(event) {
    event.stopImmediatePropagation();
  }
  for (const evt of blockedEvents) {
    document.addEventListener(evt, blockEvent, true);
    window.addEventListener(evt, blockEvent, true);
  }

  for (const evt of ['pointerdown', 'touchend', 'click', 'keydown']) {
    document.addEventListener(evt, markUserInteraction, { capture: true, passive: true });
  }

  // Chỉ bảo vệ video chính của player; bỏ qua video xem trước (inline preview, luôn muted).
  function isProtectedVideo(v) {
    if (!v || v.tagName !== 'VIDEO' || v.muted) return false;
    return v.classList.contains('html5-main-video') || !!v.closest('#movie_player');
  }

  function tryResume(v) {
    if (v.__ytbResumeTimer) return;
    const now = Date.now();
    if (!v.__ytbResumeWindowStart || now - v.__ytbResumeWindowStart > RESUME_WINDOW_MS) {
      v.__ytbResumeWindowStart = now;
      v.__ytbResumeCount = 0;
    }
    if (v.__ytbResumeCount >= MAX_RESUME_ATTEMPTS) return;
    const delay = RESUME_DELAYS[v.__ytbResumeCount] || 500;
    v.__ytbResumeCount++;
    v.__ytbResumeTimer = setTimeout(function() {
      v.__ytbResumeTimer = null;
      if (!v.paused || v.ended || !v.__ytbShouldPlay ||
          window.__ytbAppInBackground !== true || hasRecentUserCommand()) {
        return;
      }
      v.play().then(function() {
        if (v.paused && !v.ended && v.__ytbShouldPlay &&
            window.__ytbAppInBackground === true && !hasRecentUserCommand()) {
          tryResume(v);
        }
      }).catch(function() {
        if (v.paused && !v.ended && v.__ytbShouldPlay &&
            window.__ytbAppInBackground === true && !hasRecentUserCommand()) {
          tryResume(v);
        }
      });
    }, delay);
  }

  function syncShouldPlay(v) {
    if (isProtectedVideo(v) && !v.paused && !v.ended) {
      v.__ytbShouldPlay = true;
      wasPlayingBeforeEnded = false;
      v.__ytbWasPlayingBeforeEnded = false;
    }
  }

  for (const evt of ['play', 'playing', 'volumechange']) {
    document.addEventListener(evt, function(e) {
      syncShouldPlay(e.target);
    }, true);
  }

  // Hỗ trợ chuyển bài (Autoplay / Playlist) ở nền khi video kế tiếp nạp xong.
  for (const evt of ['loadeddata', 'canplay']) {
    document.addEventListener(evt, function(e) {
      const v = e.target;
      if (!isProtectedVideo(v)) return;
      if (window.__ytbAppInBackground === true &&
          (wasPlayingBeforeEnded || v.__ytbWasPlayingBeforeEnded) &&
          !hasRecentUserCommand()) {
        wasPlayingBeforeEnded = false;
        v.__ytbWasPlayingBeforeEnded = false;
        v.__ytbShouldPlay = true;
        if (v.paused && !v.ended) {
          v.play().catch(function() { tryResume(v); });
        }
      }
    }, true);
  }

  document.addEventListener('ended', function(e) {
    const v = e.target;
    if (v && v.tagName === 'VIDEO') {
      if (window.__ytbAppInBackground === true && v.__ytbShouldPlay && !hasRecentUserCommand()) {
        wasPlayingBeforeEnded = true;
        v.__ytbWasPlayingBeforeEnded = true;
      }
      v.__ytbShouldPlay = false;
    }
  }, true);

  // Pause do Chromium tự gây ra (không qua JS .pause()) khi tắt màn hình hoặc mất audio focus.
  document.addEventListener('pause', function(e) {
    const v = e.target;
    if (!isProtectedVideo(v) || v.ended || !v.__ytbShouldPlay) return;
    if (window.__ytbAppInBackground === true && !isUserPause() && !v.__ytbPausedByCall) {
      const bridge = window.flutter_inappwebview;
      if (bridge && typeof bridge.callHandler === 'function') {
        bridge.callHandler('ytbPauseCheck').then(function(otherActive) {
          if (otherActive === true) {
            window.__ytbSystemPause('focus', false);
          } else {
            tryResume(v);
          }
        }).catch(function() {
          tryResume(v);
        });
      } else {
        tryResume(v);
      }
    }
  }, true);

  const origPause = HTMLMediaElement.prototype.pause;
  HTMLMediaElement.prototype.pause = function() {
    if (window.__ytbAppInBackground !== true) {
      if (this.tagName === 'VIDEO') {
        this.__ytbShouldPlay = false;
        wasPlayingBeforeEnded = false;
        this.__ytbWasPlayingBeforeEnded = false;
      }
      return origPause.apply(this, arguments);
    }
    // Ở nền: chặn pause hệ thống nếu không phải lệnh từ người dùng (Notification/Lockscreen/chạm trực tiếp).
    if (!isUserPause() && isProtectedVideo(this) && !this.ended && this.__ytbShouldPlay) {
      return;
    }
    if (this.tagName === 'VIDEO' && (this.ended || isUserPause())) {
      this.__ytbShouldPlay = false;
      if (isUserPause() || hasRecentUserCommand()) {
        wasPlayingBeforeEnded = false;
        this.__ytbWasPlayingBeforeEnded = false;
      }
    }
    return origPause.apply(this, arguments);
  };

  function hasProtectedPlayback() {
    if (wasPlayingBeforeEnded) return true;
    const videos = document.querySelectorAll('video');
    for (let i = 0; i < videos.length; i++) {
      const v = videos[i];
      if (!isProtectedVideo(v)) continue;
      if (!v.paused || v.__ytbShouldPlay || v.__ytbWasPlayingBeforeEnded) {
        return true;
      }
    }
    return false;
  }

  function runWatchdog() {
    if (window.__ytbAppInBackground !== true) {
      stopWatchdog();
      return;
    }
    if (!hasRecentUserCommand() && !hasProtectedPlayback()) {
      stopWatchdog();
      return;
    }
    if (hasRecentUserCommand()) return;
    document.querySelectorAll('video').forEach(function(v) {
      if (!isProtectedVideo(v) || v.ended) return;
      if ((v.__ytbShouldPlay || wasPlayingBeforeEnded || v.__ytbWasPlayingBeforeEnded) && v.paused) {
        if (wasPlayingBeforeEnded || v.__ytbWasPlayingBeforeEnded) {
          wasPlayingBeforeEnded = false;
          v.__ytbWasPlayingBeforeEnded = false;
          v.__ytbShouldPlay = true;
        }
        v.play().catch(function() { tryResume(v); });
      }
    });
  }

  function startWatchdog() {
    if (watchdogTimer !== null) return;
    watchdogTimer = setInterval(runWatchdog, WATCHDOG_INTERVAL_MS);
  }

  function stopWatchdog() {
    if (watchdogTimer !== null) {
      clearInterval(watchdogTimer);
      watchdogTimer = null;
    }
  }

  window.__ytbSystemPause = function(reason, canResumeLater) {
    window.__ytbSystemPausedAt = Date.now();
    window.__ytbUserCommandAt = Date.now();
    wasPlayingBeforeEnded = false;
    document.querySelectorAll('video').forEach(function(v) {
      if (!isProtectedVideo(v)) return;
      if (v.__ytbResumeTimer) {
        clearTimeout(v.__ytbResumeTimer);
        v.__ytbResumeTimer = null;
      }
      v.__ytbWasPlayingBeforeEnded = false;
      v.__ytbPausedByCall = !!canResumeLater && (!v.paused || v.__ytbShouldPlay);
      v.__ytbShouldPlay = false;
      if (!v.paused) {
        try { origPause.call(v); } catch (_) {}
      }
    });
    if (!canResumeLater) stopWatchdog();
  };

  window.__ytbSystemResume = function(reason) {
    window.__ytbSystemPausedAt = 0;
    document.querySelectorAll('video').forEach(function(v) {
      if (!isProtectedVideo(v) || !v.__ytbPausedByCall) return;
      v.__ytbPausedByCall = false;
      v.__ytbShouldPlay = true;
      if (v.paused && !v.ended) {
        v.play().catch(function() {});
      }
    });
    if (window.__ytbAppInBackground === true && hasProtectedPlayback()) {
      startWatchdog();
    }
  };

  window.__ytbSetBackground = function(background) {
    window.__ytbAppInBackground = background === true;
    if (!window.__ytbAppInBackground) {
      stopWatchdog();
      document.querySelectorAll('video').forEach(function(v) {
        if (v.__ytbResumeTimer) {
          clearTimeout(v.__ytbResumeTimer);
          v.__ytbResumeTimer = null;
        }
      });
      return;
    }
    if (hasProtectedPlayback()) {
      startWatchdog();
    } else {
      stopWatchdog();
    }
    document.querySelectorAll('video').forEach(function(v) {
      if (isProtectedVideo(v) && v.__ytbShouldPlay && v.paused && !v.ended && !hasRecentUserCommand()) {
        tryResume(v);
      }
    });
  };

  // Giả lập IntersectionObserver ở nền để YouTube không tự dừng vì tưởng video khuất khung nhìn.
  const OrigIO = window.IntersectionObserver;
  if (typeof OrigIO === 'function') {
    window.IntersectionObserver = function(callback, options) {
      const wrappedCallback = function(entries, observer) {
        if (window.__ytbAppInBackground === true && Array.isArray(entries)) {
          const patched = entries.map(function(entry) {
            const t = entry && entry.target;
            if (t && (t.tagName === 'VIDEO' || t.id === 'movie_player' ||
                (t.closest && t.closest('#movie_player')))) {
              return {
                target: t,
                boundingClientRect: entry.boundingClientRect,
                intersectionRect: entry.boundingClientRect,
                rootBounds: entry.rootBounds,
                intersectionRatio: 1,
                isIntersecting: true,
                isVisible: true,
                time: entry.time
              };
            }
            return entry;
          });
          return callback.call(this, patched, observer);
        }
        return callback.call(this, entries, observer);
      };
      return new OrigIO(wrappedCallback, options);
    };
    window.IntersectionObserver.prototype = OrigIO.prototype;
  }

  // Ở nền: chạy requestAnimationFrame bằng timer để Autoplay / Playlist vẫn chuyển bài.
  // Dùng dải ID riêng để cancelAnimationFrame không hủy nhầm timer của YouTube.
  const origRAF = window.requestAnimationFrame;
  const origCAF = window.cancelAnimationFrame;
  const shimTimers = new Map();
  let shimSeq = 0;
  if (origRAF && origCAF) {
    window.requestAnimationFrame = function(callback) {
      if (window.__ytbAppInBackground === true && watchdogTimer !== null) {
        const id = 1000000000 + (++shimSeq);
        const frameMs = wasPlayingBeforeEnded
          ? BACKGROUND_FRAME_TRANSITION_MS
          : BACKGROUND_FRAME_STEADY_MS;
        const timer = setTimeout(function() {
          shimTimers.delete(id);
          callback(performance.now());
        }, frameMs);
        shimTimers.set(id, timer);
        return id;
      }
      return origRAF.call(window, callback);
    };
    window.cancelAnimationFrame = function(id) {
      const timer = shimTimers.get(id);
      if (timer !== undefined) {
        clearTimeout(timer);
        shimTimers.delete(id);
        return;
      }
      return origCAF.call(window, id);
    };
  }
})();
''';
}
