import 'dart:collection';
import 'dart:convert';

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
          source: _buildAdBlockStartJs(),
          injectionTime: UserScriptInjectionTime.AT_DOCUMENT_START,
        ),
        UserScript(
          groupName: 'ytb_family_adblock_dom',
          source: _adBlockDomJs,
          injectionTime: UserScriptInjectionTime.AT_DOCUMENT_END,
        ),
      ]);

  static String _buildAdBlockStartJs() {
    final hostsJson = jsonEncode(_blockedHosts);
    final pathsJson = jsonEncode(_blockedPathSegments);
    return _adBlockStartJsTemplate
        .replaceFirst('__BLOCKED_HOSTS_JSON__', hostsJson)
        .replaceFirst('__BLOCKED_PATHS_JSON__', pathsJson);
  }

  static const String _adBlockStartJsTemplate = r'''
(function() {
  if (window.__ytbFamilyStartActive) return;
  window.__ytbFamilyStartActive = true;

  // 1. Merge Dark Mode (f6=400) vào cookie PREF hiện có để không mất f5/hl/tz.
  try {
    const m = document.cookie.match(/(?:^|;\s*)PREF=([^;]*)/);
    const raw = m ? decodeURIComponent(m[1]) : '';
    const params = new URLSearchParams(raw);
    if (params.get('f6') !== '400') {
      params.set('f6', '400');
      document.cookie = 'PREF=' + params.toString() +
        '; domain=.youtube.com; path=/; max-age=31536000; SameSite=Lax';
    }
  } catch (_) {}

  // 2. Inject Ad-Block & Native YouTube Look & Feel CSS immediately.
  const STYLE_ID = 'ytb-family-style';
  const COMBINED_CSS = `
    /* Feed, banner, search & merch ads */
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
    ytm-merch-shelf-renderer,
    ytm-product-carousel-renderer,
    ytm-shopping-carousel-renderer,
    ytm-enforcement-message-view-model,
    ytd-enforcement-message-view-model,
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
    ytm-rich-item-renderer:has(> ytm-ad-slot-renderer, > ytm-promoted-sparkles-web-renderer, > ytm-in-feed-ad-layout-renderer, > ytm-promoted-video-renderer),
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

    /* PiP full-viewport player */
    html.ytb-pip-mode ytm-mobile-topbar-renderer,
    html.ytb-pip-mode ytm-pivot-bar-renderer,
    html.ytb-pip-mode ytm-watch-metadata,
    html.ytb-pip-mode ytm-item-section-renderer {
      display: none !important;
    }
    html.ytb-pip-mode #movie_player,
    html.ytb-pip-mode .html5-video-player {
      position: fixed !important;
      inset: 0 !important;
      width: 100vw !important;
      height: 100vh !important;
      z-index: 999998 !important;
      background: transparent !important;
    }
    html.ytb-pip-mode video.html5-main-video,
    html.ytb-pip-mode #movie_player video {
      position: fixed !important;
      inset: 0 !important;
      width: 100vw !important;
      height: 100vh !important;
      z-index: 999999 !important;
      background: transparent !important;
      object-fit: contain !important;
    }
    html.ytb-pip-mode .player-controls-content,
    html.ytb-pip-mode .ytp-chrome-top,
    html.ytb-pip-mode .ytp-chrome-bottom,
    html.ytb-pip-mode .ytp-gradient-top,
    html.ytb-pip-mode .ytp-gradient-bottom,
    html.ytb-pip-mode .ytp-cued-thumbnail-overlay,
    html.ytb-pip-mode .ytp-pause-overlay,
    html.ytb-pip-mode .ytp-spinner,
    html.ytb-pip-mode .ytp-bezel,
    html.ytb-pip-mode ytm-mobile-topbar-renderer {
      display: none !important;
    }
  `;

  window.__ytbSetPip = function(enabled) {
    try {
      document.documentElement.classList.toggle('ytb-pip-mode', enabled === true);
    } catch (_) {}
  };

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

  // 3. Single-source blocklist & Network/JSON Pruning.
  const BLOCKED_HOSTS = __BLOCKED_HOSTS_JSON__;
  const BLOCKED_PATHS = __BLOCKED_PATHS_JSON__;

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

  const FEED_AD_KEYS = [
    'adSlotRenderer',
    'promotedSparklesWebRenderer',
    'promotedSparklesTextSearchRenderer',
    'inFeedAdLayoutRenderer',
    'promotedVideoRenderer',
    'searchPyvRenderer',
    'brandVideoShelfRenderer',
    'bannerPromoRenderer',
    'statementBannerRenderer',
    'merchandiseShelfRenderer',
    'productCarouselRenderer'
  ];

  function isAdRenderer(obj) {
    if (!obj || typeof obj !== 'object') return false;
    for (let i = 0; i < FEED_AD_KEYS.length; i++) {
      if (obj[FEED_AD_KEYS[i]] !== undefined) return true;
    }
    const ep = obj.engagementPanelSectionListRenderer;
    if (ep && typeof ep.panelIdentifier === 'string') {
      const id = ep.panelIdentifier.toLowerCase();
      if (id.includes('ads') || id.includes('shopping')) return true;
    }
    return false;
  }

  function prunePlayerAds(data, depth) {
    if (!data || typeof data !== 'object' || (depth || 0) > 6) return data;
    if (Array.isArray(data)) {
      for (let i = data.length - 1; i >= 0; i--) {
        if (isAdRenderer(data[i])) {
          data.splice(i, 1);
        } else {
          prunePlayerAds(data[i], (depth || 0) + 1);
        }
      }
      return data;
    }
    delete data.adPlacements;
    delete data.playerAds;
    delete data.adSlots;
    delete data.adBreakHeartbeatParams;
    if (data.playerResponse && typeof data.playerResponse === 'object') {
      prunePlayerAds(data.playerResponse, (depth || 0) + 1);
    }
    if (Array.isArray(data.engagementPanels)) {
      prunePlayerAds(data.engagementPanels, (depth || 0) + 1);
    }
    return data;
  }

  function pruneFeedAds(data, depth) {
    const d = depth || 0;
    if (!data || typeof data !== 'object' || d > 12) return data;
    if (Array.isArray(data)) {
      for (let i = data.length - 1; i >= 0; i--) {
        const item = data[i];
        if (isAdRenderer(item)) {
          data.splice(i, 1);
        } else {
          pruneFeedAds(item, d + 1);
        }
      }
      return data;
    }
    delete data.adPlacements;
    delete data.playerAds;
    delete data.adSlots;
    delete data.adBreakHeartbeatParams;
    const keys = Object.keys(data);
    for (let i = 0; i < keys.length; i++) {
      const k = keys[i];
      const v = data[k];
      if (v && typeof v === 'object') {
        if (isAdRenderer(v)) {
          delete data[k];
        } else {
          pruneFeedAds(v, d + 1);
        }
      }
    }
    return data;
  }

  // Prune ytInitialPlayerResponse & ytInitialData as soon as YouTube assigns them.
  let _ytInitialPlayerResponse = prunePlayerAds(window.ytInitialPlayerResponse, 0);
  try {
    Object.defineProperty(window, 'ytInitialPlayerResponse', {
      configurable: true,
      enumerable: true,
      get: function() { return _ytInitialPlayerResponse; },
      set: function(val) { _ytInitialPlayerResponse = prunePlayerAds(val, 0); }
    });
  } catch (_) {}

  let _ytInitialData = pruneFeedAds(window.ytInitialData, 0);
  try {
    Object.defineProperty(window, 'ytInitialData', {
      configurable: true,
      enumerable: true,
      get: function() { return _ytInitialData; },
      set: function(val) { _ytInitialData = pruneFeedAds(val, 0); }
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
      if (url.includes('/youtubei/v1/browse') ||
          url.includes('/youtubei/v1/search') ||
          url.includes('/youtubei/v1/reel/reel_watch_sequence') ||
          url.includes('/youtubei/v1/guide')) {
        return p.then(function(data) { return pruneFeedAds(data, 0); });
      }
      return p;
    };
  }

  // Hook window.fetch chỉ cho URL nằm trong blocklist.
  if (typeof window.fetch === 'function') {
    const origFetch = window.fetch.bind(window);
    window.fetch = function(input, init) {
      const url = typeof input === 'string' ? input : (input && input.url ? input.url : '');
      if (url && isBlockedBeaconUrl(url)) {
        return Promise.resolve(new Response(null, { status: 204 }));
      }
      return origFetch(input, init);
    };
  }

  // Chặn <img> tracking pixel thuộc blocklist.
  try {
    const imgDesc = Object.getOwnPropertyDescriptor(HTMLImageElement.prototype, 'src');
    if (imgDesc && imgDesc.set) {
      Object.defineProperty(HTMLImageElement.prototype, 'src', {
        configurable: true,
        enumerable: imgDesc.enumerable,
        get: imgDesc.get,
        set: function(val) {
          if (typeof val === 'string' && isBlockedBeaconUrl(val)) {
            return imgDesc.set.call(
              this,
              'data:image/gif;base64,R0lGODlhAQABAIAAAAAAAP///yH5BAEAAAAALAAAAAABAAEAAAIBRAA7'
            );
          }
          return imgDesc.set.call(this, val);
        }
      });
    }
  } catch (_) {}

  // Wrap navigator.sendBeacon & XMLHttpRequest.
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
  let contentReadySent = false;
  let lastShortsSkipAt = 0;

  // SponsorBlock cache & active segments
  const sbCache = new Map();
  let sbCurrentId = '';
  let sbSegments = [];
  let sbLastSkipped = -1;

  function currentVideoId() {
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

  function loadSponsorSegments(videoId) {
    if (!videoId || videoId === sbCurrentId) return;
    sbCurrentId = videoId;
    sbLastSkipped = -1;
    if (sbCache.has(videoId)) {
      sbSegments = sbCache.get(videoId) || [];
      return;
    }
    sbSegments = [];
    const ctrl = typeof AbortController === 'function' ? new AbortController() : null;
    const timer = ctrl ? setTimeout(function() { ctrl.abort(); }, 3000) : null;
    fetch(
      'https://sponsor.ajax.sponsorblock.org/api/skipSegments?videoID=' +
        encodeURIComponent(videoId) +
        '&categories=["sponsor","selfpromo","interaction"]',
      ctrl ? { signal: ctrl.signal } : undefined
    ).then(function(r) {
      return r.ok ? r.json() : [];
    }).then(function(list) {
      if (timer) clearTimeout(timer);
      const segs = Array.isArray(list)
        ? list.map(function(s) { return s.segment; }).filter(function(s) {
            return Array.isArray(s) && s.length === 2 && s[1] > s[0];
          })
        : [];
      sbCache.set(videoId, segs);
      if (sbCurrentId === videoId) sbSegments = segs;
    }).catch(function() {
      if (timer) clearTimeout(timer);
      sbCache.set(videoId, []);
    });
  }

  function checkSponsorSkip(video) {
    if (!video || !sbSegments.length || video.paused) return;
    const t = video.currentTime;
    for (let i = 0; i < sbSegments.length; i++) {
      const seg = sbSegments[i];
      if (t >= seg[0] && t < seg[1] - 0.5 && sbLastSkipped !== seg[0]) {
        sbLastSkipped = seg[0];
        video.currentTime = seg[1];
        break;
      }
    }
  }

  function notifyContentReady() {
    if (contentReadySent) return;
    if (document.querySelector('ytm-rich-item-renderer, ytm-video-with-context-renderer, #movie_player')) {
      contentReadySent = true;
      const bridge = window.flutter_inappwebview;
      if (bridge && typeof bridge.callHandler === 'function') {
        bridge.callHandler('ytbContentReady', true);
      }
    }
  }

  function onAdTimeUpdate(e) {
    if (!e.target || e.target.tagName !== 'VIDEO') return;
    const now = Date.now();
    if (now - lastTimeUpdateCheck < TIMEUPDATE_THROTTLE_MS) return;
    lastTimeUpdateCheck = now;
    handleInStreamAds();
    checkSponsorSkip(e.target);
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

    // Xử lý cảnh báo anti-adblock (enforcement-message) & dialog upsell
    const enforcement = document.querySelectorAll(
      'ytm-enforcement-message-view-model, ytd-enforcement-message-view-model'
    );
    if (enforcement.length > 0) {
      for (let i = 0; i < enforcement.length; i++) {
        const dialog = enforcement[i].closest('tp-yt-paper-dialog') || enforcement[i];
        dialog.style.display = 'none';
        dialog.remove();
      }
      const backdrop = document.querySelector('tp-yt-iron-overlay-backdrop');
      if (backdrop) backdrop.remove();
      const v = document.querySelector('#movie_player video.html5-main-video, video');
      if (v && v.paused && !v.ended) {
        v.play().catch(function() {});
      }
    }

    const dialogs = document.querySelectorAll(
      'tp-yt-paper-dialog, ytm-mealbar-promo-renderer, ytm-upsell-dialog-renderer'
    );
    for (let i = 0; i < dialogs.length; i++) {
      const el = dialogs[i];
      if (el.querySelector('[href*="premium"], ytm-mealbar-promo-renderer, ytm-upsell-dialog-renderer, ytm-enforcement-message-view-model')) {
        el.style.display = 'none';
        el.remove();
        const backdrop = document.querySelector('tp-yt-iron-overlay-backdrop');
        if (backdrop) backdrop.remove();
      }
    }
  }

  function skipShortsAd() {
    if (!location.pathname.startsWith('/shorts')) return;
    const now = Date.now();
    if (now - lastShortsSkipAt < 800) return;
    const activeReel = document.querySelector('ytm-reel-video-renderer[is-active], ytm-reel-video-renderer');
    if (!activeReel) return;
    const hasAd = activeReel.querySelector(
      'ytm-ad-slot-renderer, ytm-in-feed-ad-layout-renderer, [data-ad-slot], .ytm-reel-ad-badge'
    );
    if (hasAd) {
      lastShortsSkipAt = now;
      const nextBtn = document.querySelector('.reel-next-button button, button[aria-label="Next video"]');
      if (nextBtn) {
        nextBtn.click();
      } else {
        document.dispatchEvent(new KeyboardEvent('keydown', { key: 'ArrowDown', keyCode: 40, bubbles: true }));
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
    const ssaiOverlay = player && player.querySelector('.ytp-ad-player-overlay, .ytp-ad-preview-container');
    const isAdShowing = (player && (
      player.classList.contains('ad-showing') ||
      player.classList.contains('ad-interrupting')
    )) || (ssaiOverlay && ssaiOverlay.offsetParent !== null);

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
      syncTimeUpdateListener(video, sbSegments.length > 0);
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
    notifyContentReady();
    dismissPremiumPopups();
    skipShortsAd();
    attachPlayerObserver();
    const vid = currentVideoId();
    if (vid) loadSponsorSegments(vid);
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
      notifyContentReady();
      attachPlayerObserver();
      handleInStreamAds();
      const vid = currentVideoId();
      if (vid) loadSponsorSegments(vid);
    }, true);
  }
})();
''';
}
