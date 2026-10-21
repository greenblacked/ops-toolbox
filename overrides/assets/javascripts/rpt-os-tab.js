/* rpt-os-tab: open the tab for the visitor's operating system, once.

   Pages such as the Quick start show the same step in content tabs labelled
   "macOS", "Linux" and "Windows", and Material opens the first one. On the
   first page that has such tabs, this script selects the visitor's own OS
   tab by clicking its label, so Material's own handler switches it, syncs
   the tabs linked to it (content.tabs.link) and remembers the choice. It
   then never acts again in that browser:

     - when the flag "rpt.os-tab" is in localStorage, it stops;
     - when Material has already saved a tab choice (a localStorage key
       ending in "__tabs" holding a non-empty list), it sets the flag and
       stops, so a deliberate choice is never overridden;
     - when the OS cannot be told, or is a phone or tablet OS (Android,
       iOS, iPadOS in desktop mode), it sets the flag and stops rather than
       guess: their UA strings claim Linux or Mac;
     - otherwise it waits for a page whose tabs carry an OS label, clicks the
       matching one, and sets the flag.

   Labels are matched by their exact text, so renaming a tab breaks this;
   the tests pin the Quick start's labels. Tab sets labelled anything else
   (Report, Preview, Apply) are ignored. Only public DOM and storage are
   used, nothing internal to Material. With storage blocked it does nothing,
   which is Material's own behaviour. No network, no cookies.

   ES5 on purpose (old iOS Safari and Android WebViews). The pure functions
   are exported for test-env/python/tests/test_docs_site.py; in a browser the
   file installs itself instead. */
(function (root, factory) {
  "use strict";
  var api = factory();
  if (typeof module === "object" && module && module.exports) {
    module.exports = api;
  } else if (root && root.document) {
    api.install(root);
  }
}(typeof window !== "undefined" ? window : this, function () {
  "use strict";

  var FLAG = "rpt.os-tab";
  var NAMES = ["macOS", "Linux", "Windows"];

  function fromPlatform(text) {
    var s = String(text || "");
    if (!s || /android|iphone|ipad|ipod|^ios$/i.test(s)) {
      return null;
    }
    /* \b keeps "Microsoft" from reading as CrOS. */
    if (/\bcros\b|chrome ?os|chromium ?os/i.test(s)) {
      return "Linux";
    }
    if (/^mac|macintosh|mac ?os/i.test(s)) {
      return "macOS";
    }
    if (/^win|windows/i.test(s)) {
      return "Windows";
    }
    if (/linux|x11|freebsd|openbsd/i.test(s)) {
      return "Linux";
    }
    return null;
  }

  /* "macOS", "Linux", "Windows" or null, from a navigator-like object
     {userAgentData, platform, userAgent, maxTouchPoints}. The client hint
     comes first, then the legacy platform string, then the UA string. */
  function detectOs(nav) {
    if (!nav) {
      return null;
    }
    var ua = String(nav.userAgent || "");
    if (/Android|iPhone|iPad|iPod/i.test(ua)) {
      return null;
    }
    /* iPadOS asks for desktop pages with a Macintosh UA; only the touch
       points give it away. */
    if (/Macintosh/i.test(ua) && Number(nav.maxTouchPoints) > 1) {
      return null;
    }
    var hint = nav.userAgentData && nav.userAgentData.platform;
    if (typeof hint === "string" && hint && hint !== "Unknown") {
      return fromPlatform(hint);
    }
    if (nav.platform) {
      return fromPlatform(nav.platform);
    }
    return fromPlatform(ua);
  }

  /* The label whose trimmed text is exactly name, or null. */
  function pickLabel(labels, name) {
    if (!labels) {
      return null;
    }
    for (var i = 0; i < labels.length; i++) {
      var text = String(labels[i].textContent || "").replace(/^\s+|\s+$/g, "");
      if (text === name) {
        return labels[i];
      }
    }
    return null;
  }

  /* True when a Storage-like object holds a saved tab choice. */
  function hasSavedTabChoice(storage) {
    try {
      for (var i = 0; i < storage.length; i++) {
        var key = storage.key(i);
        if (typeof key === "string" && key.slice(-6) === "__tabs") {
          var list = JSON.parse(storage.getItem(key));
          if (Object.prototype.toString.call(list) === "[object Array]" && list.length > 0) {
            return true;
          }
        }
      }
    } catch (e) {
      /* unreadable: treat as no choice */
    }
    return false;
  }

  function storageOf(win) {
    try {
      var storage = win.localStorage;
      storage.getItem(FLAG);
      return storage;
    } catch (e) {
      return null;
    }
  }

  function install(win) {
    var doc = win.document;
    if (!doc || typeof doc.querySelectorAll !== "function") {
      return;
    }

    function done(storage) {
      try {
        storage.setItem(FLAG, "1");
      } catch (e) {
        /* blocked: the next page asks again, which is harmless */
      }
    }

    function run() {
      var storage = storageOf(win);
      if (!storage || storage.getItem(FLAG) !== null) {
        return;
      }
      if (hasSavedTabChoice(storage)) {
        done(storage);
        return;
      }
      var os = detectOs(win.navigator);
      if (!os) {
        done(storage);
        return;
      }
      var sets = doc.querySelectorAll(".md-content .tabbed-set");
      for (var i = 0; i < sets.length; i++) {
        var labels = sets[i].querySelectorAll(".tabbed-labels > label");
        var hasOsTab = false;
        for (var n = 0; n < NAMES.length; n++) {
          if (pickLabel(labels, NAMES[n])) {
            hasOsTab = true;
          }
        }
        if (!hasOsTab) {
          continue;
        }
        var label = pickLabel(labels, os);
        if (label) {
          /* Material scrolls to keep the tab set in place when a tab
             changes; on page load that would move the page, so restore the
             position, now and after Material's own update. */
          var y = win.pageYOffset || 0;
          label.click();
          win.scrollTo(0, y);
          if (typeof win.requestAnimationFrame === "function") {
            win.requestAnimationFrame(function () {
              win.scrollTo(0, y);
            });
          }
          done(storage);
        }
        return;
      }
    }

    if (win.document$ && typeof win.document$.subscribe === "function") {
      win.document$.subscribe(run);
    } else if (doc.readyState === "loading") {
      doc.addEventListener("DOMContentLoaded", run);
    } else {
      run();
    }
  }

  return {
    FLAG: FLAG,
    detectOs: detectOs,
    pickLabel: pickLabel,
    hasSavedTabChoice: hasSavedTabChoice,
    install: install
  };
}));
