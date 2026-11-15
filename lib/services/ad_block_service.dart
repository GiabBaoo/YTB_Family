import 'dart:collection';

import 'package:flutter_inappwebview/flutter_inappwebview.dart';

class AdBlockService {
  AdBlockService._();

  static const List<String> _blockedHosts = [
    'doubleclick.net',
    'googlesyndication.com',
    'googleadservices.com',
    'google-analytics.com',
    'googletagmanager.com',
    'googletagservices.com',
    'adservice.google.com',
    '2mdn.net',
    'ads.youtube.com',
  ];

  static const List<String> _blockedPathSegments = [
    '/pagead/',
    '/api/stats/ads',
    '/ptracking',
    '/get_midroll_info',
    '/youtubei/v1/player/ad_break',
    '/ad_data_sync',
  ];

  static const List<String> _contentBlockerHosts = [
    'doubleclick.net',
    'googlesyndication.com',
    'googleadservices.com',
  ];

  static bool shouldBlockUrl(WebUri? uri) {
    if (uri == null) return false;

    final host = uri.host.toLowerCase();
    if (host == 'googlevideo.com' || host.endsWith('.googlevideo.com')) {
      return false;
    }

    for (final blockedHost in _blockedHosts) {
      if (host == blockedHost || host.endsWith('.$blockedHost')) {
        return true;
      }
    }

    final urlString = uri.toString().toLowerCase();
    for (final segment in _blockedPathSegments) {
      if (urlString.contains(segment)) {
        return true;
      }
    }

    return false;
  }

  static List<ContentBlocker> get contentBlockers {
    return _contentBlockerHosts.map((host) {
      final escaped = RegExp.escape(host);
      return ContentBlocker(
        trigger: ContentBlockerTrigger(
          urlFilter: '^https?://([a-z0-9-]+\\.)*$escaped(/|\$)',
        ),
        action: ContentBlockerAction(type: ContentBlockerActionType.BLOCK),
      );
    }).toList(growable: false);
  }

  static UnmodifiableListView<UserScript> get initialUserScripts =>
      UnmodifiableListView<UserScript>([
        UserScript(
          groupName: 'ytb_family_adblock_start',
          source: _adBlockStartJs,
          injectionTime: UserScriptInjectionTime.AT_DOCUMENT_START,
        ),
        UserScript(
          groupName: 'ytb_family_adblock_dom',
          source: _adBlockDomJs,
          injectionTime: UserScriptInjectionTime.AT_DOCUMENT_END,
        ),
      ]);

  static const String _adBlockStartJs = r'''
(function() {
  if (window.__ytbFamilyStartActive) return;
  window.__ytbFamilyStartActive = true;

  // 1. Force YouTube Dark Mode (PREF=f6=400) if not already enabled.
  try {
    if (!document.cookie.includes('f6=400')) {
      document.cookie = 'PREF=f6=400; domain=.youtube.com; path=/; max-age=31536000; SameSite=Lax';
    }
  } catch (_) {}

  // 2. Inject Ad-Block & Native YouTube Look & Feel CSS immediately.
  const STYLE_ID = 'ytb-family-style';
  const COMBINED_CSS = `
    /* Feed, banner & search ads */
    ytm-promoted-sparkles-web-renderer,
    ytm-promoted-sparkles-text-search-renderer,
    ytm-promoted-video-renderer,
    ytm-companion-slot-renderer,
    ytm-ad-slot-renderer,
    ytd-ad-slot-renderer,
    ad-slot-renderer,
    ytm-in-feed-ad-layout-renderer,
    ytm-search-pyv-renderer,
    ytm-brand-video-shelf-renderer,
    ytm-banner-promo-renderer,
    ytm-statement-banner-renderer,
    #masthead-ad,
    .ytp-ad-overlay-container,
    .ytp-ad-image-overlay,
    .ytp-ad-text-overlay,
    /* YouTube Premium upsell & "Open in App" banners */
    ytm-mealbar-promo-renderer,
    ytm-upsell-dialog-renderer,
    yt-upsell-dialog-renderer,
    ytm-promo-renderer,
    ytm-app-banner-renderer,
    ytm-open-app-button,
    a[href^="intent://"],
    ytm-mobile-topbar-renderer .open-in-app-button {
      display: none !important;
      visibility: hidden !important;
      height: 0 !important;
      max-height: 0 !important;
      overflow: hidden !important;
      pointer-events: none !important;
    }

    /* Ẩn triệt để thẻ cha chứa quảng cáo để tránh khoảng trống & layout shift */
    ytm-rich-item-renderer:has(> ytm-ad-slot-renderer, > ytm-promoted-sparkles-web-renderer, > ytm-in-feed-ad-layout-renderer),
    ytm-item-section-renderer > ytm-ad-slot-renderer,
    ytm-item-section-renderer > ytm-promoted-sparkles-web-renderer {
      display: none !important;
      height: 0 !important;
      margin: 0 !important;
      padding: 0 !important;
    }

    /* Native YouTube Dark (#0F0F0F) & Mobile App Feel */
    html, body, ytm-app {
      background-color: #0F0F0F !important;
      overscroll-behavior-x: none;
      -webkit-overflow-scrolling: touch;
      -webkit-tap-highlight-color: transparent !important;
      -webkit-user-select: none !important;
      user-select: none !important;
    }

    html, body {
      touch-action: manipulation;
    }

    input, textarea, [contenteditable="true"] {
      -webkit-user-select: text !important;
      user-select: text !important;
    }

    ::-webkit-scrollbar {
      display: none !important;
      width: 0 !important;
      height: 0 !important;
    }

    /* Clean flat Top Bar & Bottom Pivot Navigation */
    ytm-mobile-topbar-renderer {
      background-color: #0F0F0F !important;
      border-bottom: none !important;
      box-shadow: none !important;
      backdrop-filter: none !important;
      -webkit-backdrop-filter: none !important;
    }

    ytm-pivot-bar-renderer {
      background-color: #0F0F0F !important;
      border-top: 1px solid rgba(255, 255, 255, 0.08) !important;
      box-shadow: none !important;
      backdrop-filter: none !important;
      -webkit-backdrop-filter: none !important;
    }
  `;

  function injectHeadAssets() {
    const target = document.head || document.documentElement;
    if (!target) return;

    if (!document.getElementById(STYLE_ID)) {
      const style = document.createElement('style');
      style.id = STYLE_ID;
      style.textContent = COMBINED_CSS;
      target.appendChild(style);
    }

    if (!document.querySelector('link[data-ytb-preconnect="1"]')) {
      const origins = ['https://i.ytimg.com', 'https://googlevideo.com'];
      for (let i = 0; i < origins.length; i++) {
        const link = document.createElement('link');
        link.rel = 'preconnect';
        link.href = origins[i];
        link.crossOrigin = 'anonymous';
        link.setAttribute('data-ytb-preconnect', '1');
        target.appendChild(link);
      }
    }
  }

  injectHeadAssets();
  if (!document.getElementById(STYLE_ID)) {
    document.addEventListener('DOMContentLoaded', injectHeadAssets, { once: true });
  }

  window.addEventListener('online', function() {
    const bridge = window.flutter_inappwebview;
    if (bridge && typeof bridge.callHandler === 'function') {
      bridge.callHandler('ytbNetwork', true);
    }
  });

  // 3. Player Response Pruning & Beacon Ad Blocking.
  const BLOCKED_HOSTS = [
    'doubleclick.net',
    'googlesyndication.com',
    'googleadservices.com',
    'google-analytics.com',
    'googletagmanager.com',
    'googletagservices.com',
    'adservice.google.com',
    '2mdn.net',
    'ads.youtube.com'
  ];

  const BLOCKED_PATHS = [
    '/pagead/',
    '/api/stats/ads',
    '/ptracking',
    '/get_midroll_info',
    '/youtubei/v1/player/ad_break',
    '/ad_data_sync'
  ];

  function isBlockedBeaconUrl(rawUrl) {
    if (!rawUrl || typeof rawUrl !== 'string') return false;
    const lower = rawUrl.toLowerCase();
    for (let i = 0; i < BLOCKED_PATHS.length; i++) {
      if (lower.includes(BLOCKED_PATHS[i])) return true;
    }
    try {
      const host = new URL(rawUrl, location.origin).hostname.toLowerCase();
      if (host === 'googlevideo.com' || host.endsWith('.googlevideo.com')) {
        return false;
      }
      for (let i = 0; i < BLOCKED_HOSTS.length; i++) {
        const h = BLOCKED_HOSTS[i];
        if (host === h || host.endsWith('.' + h)) return true;
      }
    } catch (_) {}
    return false;
  }

  function prunePlayerAds(data, depth) {
    if (!data || typeof data !== 'object' || (depth || 0) > 4) return data;
    if (Array.isArray(data)) {
      for (let i = 0; i < data.length; i++) {
        prunePlayerAds(data[i], (depth || 0) + 1);
      }
      return data;
    }
    delete data.adPlacements;
    delete data.playerAds;
    delete data.adSlots;
    if (data.playerResponse && typeof data.playerResponse === 'object') {
      prunePlayerAds(data.playerResponse, (depth || 0) + 1);
    }
    return data;
  }

  // Prune ytInitialPlayerResponse as soon as YouTube assigns it.
  let _ytInitialPlayerResponse = prunePlayerAds(window.ytInitialPlayerResponse, 0);
  try {
    Object.defineProperty(window, 'ytInitialPlayerResponse', {
      configurable: true,
      enumerable: true,
      get: function() { return _ytInitialPlayerResponse; },
      set: function(val) { _ytInitialPlayerResponse = prunePlayerAds(val, 0); }
    });
  } catch (_) {}

  function hasAdFields(obj) {
    if (!obj || typeof obj !== 'object') return false;
    if (obj.adPlacements !== undefined || obj.playerAds !== undefined || obj.adSlots !== undefined) {
      return true;
    }
    const pr = obj.playerResponse;
    return !!(pr && typeof pr === 'object' &&
      (pr.adPlacements !== undefined || pr.playerAds !== undefined || pr.adSlots !== undefined));
  }

  // Hook JSON.parse & Response.prototype.json để lọc quảng cáo ngay trong SPA navigation.
  const origJsonParse = JSON.parse;
  JSON.parse = function(text, reviver) {
    const result = origJsonParse.call(this, text, reviver);
    if (typeof text === 'string' && text.length > 200 && result && typeof result === 'object') {
      if (Array.isArray(result)) {
        for (let i = 0; i < result.length && i < 32; i++) {
          if (hasAdFields(result[i])) {
            return prunePlayerAds(result, 0);
          }
        }
      } else if (hasAdFields(result)) {
        return prunePlayerAds(result, 0);
      }
    }
    return result;
  };

  if (typeof Response !== 'undefined' && Response.prototype && Response.prototype.json) {
    const origRespJson = Response.prototype.json;
    Response.prototype.json = function() {
      const url = this.url || '';
      const p = origRespJson.apply(this, arguments);
      if (url.includes('/youtubei/v1/player') || url.includes('/youtubei/v1/next')) {
        return p.then(function(data) { return prunePlayerAds(data, 0); });
      }
      return p;
    };
  }

  // Wrap navigator.sendBeacon & XMLHttpRequest thay cho Android contentBlockers đồng bộ.
  if (navigator.sendBeacon) {
    const origSendBeacon = navigator.sendBeacon.bind(navigator);
    navigator.sendBeacon = function(url, data) {
      if (isBlockedBeaconUrl(url)) return true;
      return origSendBeacon(url, data);
    };
  }

  if (typeof XMLHttpRequest !== 'undefined' && XMLHttpRequest.prototype) {
    const origXhrOpen = XMLHttpRequest.prototype.open;
    const origXhrSetHeader = XMLHttpRequest.prototype.setRequestHeader;
    const origXhrSend = XMLHttpRequest.prototype.send;
    const blockedXhrs = new WeakSet();
    XMLHttpRequest.prototype.open = function(method, url) {
      const urlStr = typeof url === 'string' ? url : (url ? String(url) : '');
      if (urlStr && isBlockedBeaconUrl(urlStr)) {
        blockedXhrs.add(this);
        return;
      }
      blockedXhrs.delete(this);
      return origXhrOpen.apply(this, arguments);
    };
    XMLHttpRequest.prototype.setRequestHeader = function() {
      if (blockedXhrs.has(this)) return;
      return origXhrSetHeader.apply(this, arguments);
    };
    XMLHttpRequest.prototype.send = function() {
      if (blockedXhrs.has(this)) {
        const xhr = this;
        queueMicrotask(function() {
          try {
            Object.defineProperty(xhr, 'readyState', { configurable: true, value: 4 });
            Object.defineProperty(xhr, 'status', { configurable: true, value: 204 });
            Object.defineProperty(xhr, 'responseText', { configurable: true, value: '' });
            Object.defineProperty(xhr, 'response', { configurable: true, value: '' });
          } catch (_) {}
          try { xhr.dispatchEvent(new Event('readystatechange')); } catch (_) {}
          try { xhr.dispatchEvent(new ProgressEvent('load')); } catch (_) {}
          try { xhr.dispatchEvent(new ProgressEvent('loadend')); } catch (_) {}
        });
        return;
      }
      return origXhrSend.apply(this, arguments);
    };
  }
})();
''';

  static const String _adBlockDomJs = r'''
(function() {
  if (window.__ytbFamilyDomActive) return;
  window.__ytbFamilyDomActive = true;

  let lastPopupCheck = 0;
  const POPUP_THROTTLE_MS = 300;
  let lastTimeUpdateCheck = 0;
  const TIMEUPDATE_THROTTLE_MS = 200;
  let observedPlayer = null;
  let playerObserver = null;
  let timeUpdateVideo = null;

  function onAdTimeUpdate(e) {
    if (!e.target || e.target.tagName !== 'VIDEO') return;
    const now = Date.now();
    if (now - lastTimeUpdateCheck < TIMEUPDATE_THROTTLE_MS) return;
    lastTimeUpdateCheck = now;
    handleInStreamAds();
  }

  function syncTimeUpdateListener(video, active) {
    if (active) {
      if (timeUpdateVideo === video) return;
      if (timeUpdateVideo) {
        timeUpdateVideo.removeEventListener('timeupdate', onAdTimeUpdate);
      }
      timeUpdateVideo = video;
      if (timeUpdateVideo) {
        timeUpdateVideo.addEventListener('timeupdate', onAdTimeUpdate);
      }
    } else if (timeUpdateVideo) {
      timeUpdateVideo.removeEventListener('timeupdate', onAdTimeUpdate);
      timeUpdateVideo = null;
    }
  }

  function dismissPremiumPopups() {
    const now = Date.now();
    if (now - lastPopupCheck < POPUP_THROTTLE_MS) return;
    lastPopupCheck = now;

    const dismissSelectors = [
      'ytm-mealbar-promo-renderer .dismiss-button button',
      'ytm-mealbar-promo-renderer button[aria-label]',
      'ytm-upsell-dialog-renderer #dismiss-button button',
      'ytm-upsell-dialog-renderer button[aria-label="No thanks"]',
      'ytm-upsell-dialog-renderer button[aria-label="Close"]'
    ];
    for (let i = 0; i < dismissSelectors.length; i++) {
      const btn = document.querySelector(dismissSelectors[i]);
      if (btn) btn.click();
    }

    const dialogs = document.querySelectorAll(
      'tp-yt-paper-dialog, ytm-mealbar-promo-renderer, ytm-upsell-dialog-renderer'
    );
    for (let i = 0; i < dialogs.length; i++) {
      const el = dialogs[i];
      if (el.querySelector('[href*="premium"], ytm-mealbar-promo-renderer, ytm-upsell-dialog-renderer')) {
        el.style.display = 'none';
        el.remove();
        const backdrop = document.querySelector('tp-yt-iron-overlay-backdrop');
        if (backdrop) backdrop.remove();
      }
    }
  }

  function clickSkipButton() {
    const skipSelectors = [
      '.ytp-ad-skip-button',
      '.ytp-ad-skip-button-modern',
      '.ytp-skip-ad-button',
      'button.ytp-ad-skip-button-modern',
      '[class*="ytp-ad-skip-button"]'
    ];
    for (let i = 0; i < skipSelectors.length; i++) {
      const skipBtn = document.querySelector(skipSelectors[i]);
      if (skipBtn && skipBtn.offsetParent !== null) {
        skipBtn.click();
        return true;
      }
    }
    return false;
  }

  function handleInStreamAds() {
    const player = document.querySelector('#movie_player, .html5-video-player');
    const isAdShowing = player && (
      player.classList.contains('ad-showing') ||
      player.classList.contains('ad-interrupting')
    );

    if (isAdShowing) {
      clickSkipButton();
    }

    const video = (player && player.querySelector('video')) || document.querySelector('video');
    if (!video) {
      syncTimeUpdateListener(null, false);
      return;
    }

    if (isAdShowing) {
      syncTimeUpdateListener(video, true);
      if (!window.__ytbFamilyAdMuted) {
        window.__ytbFamilyWasMuted = video.muted;
        window.__ytbFamilyAdMuted = true;
      }
      video.muted = true;
      try {
        video.playbackRate = 16;
      } catch (_) {
        try { video.playbackRate = 8; } catch (_) {}
      }
      if (isFinite(video.duration) && video.duration > 0) {
        const targetTime = Math.max(0, video.duration - 0.1);
        if (video.currentTime < targetTime) {
          video.currentTime = targetTime;
        }
      }
    } else {
      syncTimeUpdateListener(null, false);
      if (window.__ytbFamilyAdMuted) {
        video.muted = Boolean(window.__ytbFamilyWasMuted);
        try { video.playbackRate = 1; } catch (_) {}
        window.__ytbFamilyAdMuted = false;
      }
    }
  }

  function attachPlayerObserver() {
    const player = document.querySelector('#movie_player, .html5-video-player');
    if (!player || player === observedPlayer) return;

    if (playerObserver) {
      playerObserver.disconnect();
    }
    observedPlayer = player;
    playerObserver = new MutationObserver(handleInStreamAds);
    playerObserver.observe(player, {
      attributes: true,
      attributeFilter: ['class']
    });
    handleInStreamAds();
  }

  function onPageOrNavigation() {
    dismissPremiumPopups();
    attachPlayerObserver();
  }

  onPageOrNavigation();

  window.addEventListener('yt-navigate-finish', onPageOrNavigation);
  window.addEventListener('yt-page-data-updated', onPageOrNavigation);

  for (const evt of ['loadedmetadata', 'durationchange', 'play']) {
    document.addEventListener(evt, function(e) {
      const t = e.target;
      if (!t || t.tagName !== 'VIDEO') return;
      if (t.muted && !t.classList.contains('html5-main-video') &&
          !(t.closest && t.closest('#movie_player'))) {
        return;
      }
      attachPlayerObserver();
      handleInStreamAds();
    }, true);
  }
})();
''';
}
