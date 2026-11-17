import 'dart:convert';

import 'package:flutter_inappwebview/flutter_inappwebview.dart';

/// Cầu nối giữa video của m.youtube và MediaSession native (notification / màn hình khóa).
class MediaBridge {
  MediaBridge._();

  static const String handlerName = 'ytbMedia';

  static final UserScript userScript = UserScript(
    groupName: 'ytb_family_media_bridge',
    source: _mediaBridgeJs,
    injectionTime: UserScriptInjectionTime.AT_DOCUMENT_START,
  );

  /// Lệnh: play | pause | next | prev | seek (arg = giây).
  static String commandJs(String command, [double? arg]) =>
      'window.__ytbControl && window.__ytbControl(${jsonEncode(command)}, ${jsonEncode(arg)});';

  static const String _mediaBridgeJs = r'''
(function() {
  if (window.__ytbMediaBridgeActive) return;
  window.__ytbMediaBridgeActive = true;

  const handlers = {};
  let sendTimer = null;
  let forceNext = false;
  let lastState = null;
  let pending = null;
  let cachedUrlId = '';
  let cachedDocTitle = '';
  let cachedMeta = null;
  const artCache = new Map();

  function resolveArtwork(id) {
    if (!id) return '';
    const cached = artCache.get(id);
    if (cached) return cached;
    const hq = 'https://i.ytimg.com/vi/' + id + '/hqdefault.jpg';
    const maxres = 'https://i.ytimg.com/vi/' + id + '/maxresdefault.jpg';
    artCache.set(id, hq);
    try {
      const img = new Image();
      img.onload = function() {
        if (img.naturalWidth > 120) {
          artCache.set(id, maxres);
          schedule(true);
        }
      };
      img.src = maxres;
    } catch (_) {}
    return hq;
  }

  const ms = navigator.mediaSession;
  if (ms && typeof ms.setActionHandler === 'function') {
    const origSetActionHandler = ms.setActionHandler;
    ms.setActionHandler = function(action, handler) {
      handlers[action] = typeof handler === 'function' ? handler : null;
      try { return origSetActionHandler.call(ms, action, handler); } catch (_) {}
    };
  }

  function mainVideo() {
    return document.querySelector('#movie_player video.html5-main-video') ||
      document.querySelector('.html5-video-player video') ||
      document.querySelector('#shorts-player video, ytm-shorts-player video') ||
      document.querySelector('video.html5-main-video') ||
      Array.from(document.querySelectorAll('video')).find(function(v) {
        return !v.muted && (v.currentSrc || v.src) && v.duration > 0;
      }) ||
      null;
  }

  function player() {
    return document.querySelector('#movie_player');
  }

  function videoIdFromUrl() {
    try {
      const u = new URL(location.href);
      const v = u.searchParams.get('v');
      if (v) return v;
      const m = u.pathname.match(/^\/shorts\/([\w-]+)/);
      return m ? m[1] : '';
    } catch (_) {
      return '';
    }
  }

  function post(state) {
    const bridge = window.flutter_inappwebview;
    if (bridge && typeof bridge.callHandler === 'function') {
      pending = null;
      bridge.callHandler('ytbMedia', state);
    } else {
      pending = state;
    }
  }

  window.addEventListener('flutterInAppWebViewPlatformReady', function() {
    if (pending) post(pending);
  });

  function collect() {
    const v = mainVideo();
    if (!v || !(v.currentSrc || v.src) || !(v.duration > 0) || !isFinite(v.duration)) {
      return { active: false };
    }
    const p = player();
    if (p && (p.classList.contains('ad-showing') || p.classList.contains('ad-interrupting'))) {
      return null;
    }
    const urlId = videoIdFromUrl();
    const docTitle = document.title;
    let id, title, artist;
    if (cachedMeta && urlId === cachedUrlId && docTitle === cachedDocTitle && cachedMeta.title) {
      id = cachedMeta.id;
      title = cachedMeta.title;
      artist = cachedMeta.artist;
    } else {
      let data = null;
      try { data = p && typeof p.getVideoData === 'function' ? p.getVideoData() : null; } catch (_) {}
      const meta = ms ? ms.metadata : null;
      id = (data && data.video_id) || urlId;
      title = (data && data.title) || (meta && meta.title) ||
        docTitle.replace(/\s*-\s*YouTube\s*$/, '');
      artist = (data && data.author) || (meta && meta.artist) || '';
      cachedUrlId = urlId;
      cachedDocTitle = docTitle;
      cachedMeta = { id: id, title: title, artist: artist };
    }
    const meta = ms ? ms.metadata : null;
    let art = resolveArtwork(id);
    if (!art && meta && meta.artwork && meta.artwork.length) {
      art = meta.artwork[meta.artwork.length - 1].src || '';
    }
    const isWatchPage = location.pathname.startsWith('/watch') ||
      location.pathname.startsWith('/shorts');
    return {
      active: true,
      id: id,
      title: title,
      artist: artist,
      art: art,
      duration: v.duration,
      position: v.currentTime,
      rate: v.playbackRate || 1,
      playing: !v.paused && !v.ended,
      ended: v.ended,
      isWatchPage: isWatchPage,
      videoWidth: v.videoWidth || 16,
      videoHeight: v.videoHeight || 9
    };
  }

  function isSameState(a, b) {
    if (!a || !b) return false;
    return a.active === b.active &&
      a.id === b.id &&
      a.playing === b.playing &&
      a.ended === b.ended &&
      a.rate === b.rate &&
      a.duration === b.duration &&
      a.title === b.title;
  }

  function send() {
    sendTimer = null;
    const force = forceNext;
    forceNext = false;
    const state = collect();
    if (!state) return;
    if (lastState && ((!force && isSameState(state, lastState)) || (!lastState.active && !state.active))) {
      return;
    }
    lastState = state;
    post(state);
  }

  function schedule(force, immediate) {
    if (force) forceNext = true;
    if (immediate) {
      if (sendTimer) {
        clearTimeout(sendTimer);
        sendTimer = null;
      }
      send();
      return;
    }
    if (sendTimer) return;
    sendTimer = setTimeout(send, 250);
  }

  const immediateEvents = { play: true, playing: true, loadedmetadata: true };
  const forceEvents = ['play', 'playing', 'pause', 'ended', 'seeked', 'ratechange', 'durationchange', 'loadedmetadata', 'emptied'];
  for (const evt of forceEvents) {
    document.addEventListener(evt, function(e) {
      const t = e.target;
      if (!t || t.tagName !== 'VIDEO') return;
      if (t.muted && !t.classList.contains('html5-main-video') && !(t.closest && t.closest('#movie_player'))) {
        return;
      }
      schedule(true, !!immediateEvents[evt]);
    }, true);
  }
  window.addEventListener('yt-navigate-finish', function() { schedule(false, true); });

  setInterval(function() {
    const v = mainVideo();
    if (!v) return;
    const isPlaying = !v.paused && !v.ended && (v.duration > 0) && isFinite(v.duration);
    if (isPlaying && (!lastState || !lastState.active || !lastState.playing)) {
      schedule(true, true);
    }
  }, 2000);

  function callYtHandler(action) {
    const h = handlers[action];
    if (typeof h !== 'function') return false;
    try {
      h({ action: action });
      return true;
    } catch (_) {
      return false;
    }
  }

  function next() {
    if (callYtHandler('nexttrack')) return;
    const p = player();
    if (p && typeof p.nextVideo === 'function') {
      try { p.nextVideo(); return; } catch (_) {}
    }
    const btn = document.querySelector('.player-controls-next-button, .ytp-next-button');
    if (btn) { btn.click(); return; }
    const link = document.querySelector(
      'ytm-playlist-panel-video-renderer[selected] + ytm-playlist-panel-video-renderer a, ' +
      'ytm-compact-autoplay-renderer a[href*="/watch"], ' +
      'ytm-video-with-context-renderer a[href*="/watch"], ' +
      'ytm-compact-video-renderer a[href*="/watch"]'
    );
    if (link) link.click();
  }

  function prev() {
    const v = mainVideo();
    if (v && v.currentTime > 3) {
      v.currentTime = 0;
      return;
    }
    if (callYtHandler('previoustrack')) return;
    history.back();
  }

  window.__ytbControl = function(cmd, arg) {
    window.__ytbUserCommandAt = Date.now();
    const v = mainVideo();
    switch (cmd) {
      case 'play':
        if (v) {
          v.__ytbShouldPlay = true;
          v.play().catch(function() {});
        }
        break;
      case 'pause':
        if (v) v.pause();
        break;
      case 'seek':
        if (v && typeof arg === 'number' && isFinite(arg)) {
          v.currentTime = Math.max(0, Math.min(arg, v.duration || arg));
        }
        break;
      case 'next':
        next();
        break;
      case 'prev':
        prev();
        break;
    }
    schedule(true);
  };
})();
''';
}

