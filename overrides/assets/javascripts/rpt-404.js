/* rpt-404: "did you mean" links on the 404 page, from the site's own search
   index.

   overrides/404.html carries a hidden .rpt-404__suggest container with two
   data attributes, both resolved from the site root by the url filter: the
   search index (search/search_index.json, which Material's search already
   fetches on every page) and the home page. This script turns the missing
   path into search terms ("/runbooks/linux-low-disk-old/" gives runbooks,
   linux, low, disk, old), ranks the index's pages by those terms (a term in
   the title counts three, in the address one), and shows the best three as
   links, plus a link that opens the search pre-filled with the terms
   (Material reads ?q= on any page). Nobody has to keep a redirect list.

   The path is attacker-controlled text, so the DOM is built with
   createElement and textContent only, and a link is made only from an
   index location that is a plain relative path (no scheme, no leading
   slash or backslash). The one request is a same-origin GET without
   credentials. Any failure leaves the page as it was: without JavaScript
   the container stays hidden, and if the index cannot be read only the
   search link is shown.

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

  var MAX_TERMS = 8;
  var MAX_LINKS = 3;

  function has(object, key) {
    return Object.prototype.hasOwnProperty.call(object, key);
  }

  /* Search terms from a request path: decoded, split into segments and then
     into words at "-", "_" and ".", lowercased, at least two characters,
     each once, at most MAX_TERMS. A trailing index page and a .html or .md
     extension are dropped. */
  function termsFromPath(pathname) {
    var raw = String(pathname == null ? "" : pathname);
    try {
      raw = decodeURIComponent(raw);
    } catch (e) {
      /* keep the raw text */
    }
    var segments = [];
    var parts = raw.split("/");
    for (var i = 0; i < parts.length; i++) {
      if (parts[i]) {
        segments.push(parts[i]);
      }
    }
    if (segments.length) {
      var last = segments[segments.length - 1];
      if (/^index\.(html?|md)$/i.test(last)) {
        segments.pop();
      } else {
        segments[segments.length - 1] = last.replace(/\.(html?|md)$/i, "");
      }
    }
    var terms = [];
    var seen = {};
    for (var s = 0; s < segments.length; s++) {
      var words = segments[s].toLowerCase().split(/[-_.\s]+/);
      for (var w = 0; w < words.length; w++) {
        var word = words[w];
        if (word.length < 2 || has(seen, word)) {
          continue;
        }
        seen[word] = true;
        terms.push(word);
        if (terms.length === MAX_TERMS) {
          return terms;
        }
      }
    }
    return terms;
  }

  /* An index location usable as a relative link, or null. Material's
     locations look like "runbooks/linux-low-disk/" ("" is the home page). */
  function safeLocation(loc) {
    if (typeof loc !== "string") {
      return null;
    }
    if (loc.indexOf(":") !== -1 || loc.indexOf("\\") !== -1 || loc.charAt(0) === "/" ||
        /[\u0000-\u001f\u007f]/.test(loc)) {
      return null;
    }
    return loc;
  }

  function stripTags(text) {
    return String(text == null ? "" : text).replace(/<[^>]*>/g, "").replace(/\s+/g, " ").replace(/^ | $/g, "");
  }

  /* The best pages for the terms: page entries only (no "#section"), each
     page once, scored 3 per term in the title and 1 per term in the
     location, highest first, then by title. Returns [{title, location}]. */
  function rank(docs, terms, limit) {
    var max = typeof limit === "number" ? limit : MAX_LINKS;
    var scored = [];
    var seen = {};
    if (!docs || !terms || !terms.length) {
      return [];
    }
    for (var i = 0; i < docs.length; i++) {
      var doc = docs[i];
      if (!doc || typeof doc.location !== "string" || doc.location.indexOf("#") !== -1) {
        continue;
      }
      var loc = safeLocation(doc.location);
      if (loc === null || has(seen, loc)) {
        continue;
      }
      var title = stripTags(doc.title);
      if (!title) {
        continue;
      }
      var lowTitle = title.toLowerCase();
      var lowLoc = loc.toLowerCase();
      var score = 0;
      for (var t = 0; t < terms.length; t++) {
        if (lowTitle.indexOf(terms[t]) !== -1) {
          score += 3;
        }
        if (lowLoc.indexOf(terms[t]) !== -1) {
          score += 1;
        }
      }
      if (score > 0) {
        seen[loc] = true;
        scored.push({ title: title, location: loc, score: score });
      }
    }
    scored.sort(function (a, b) {
      if (a.score !== b.score) {
        return b.score - a.score;
      }
      return a.title < b.title ? -1 : (a.title > b.title ? 1 : 0);
    });
    var out = [];
    for (var k = 0; k < scored.length && k < max; k++) {
      out.push({ title: scored[k].title, location: scored[k].location });
    }
    return out;
  }

  function install(win) {
    var doc = win.document;
    if (!doc || typeof doc.querySelector !== "function") {
      return;
    }

    function render(box, base, terms, pages) {
      var heading = doc.createElement("h2");
      heading.textContent = "Did you mean";
      box.appendChild(heading);
      if (pages.length) {
        var list = doc.createElement("ul");
        for (var i = 0; i < pages.length; i++) {
          var item = doc.createElement("li");
          var link = doc.createElement("a");
          link.setAttribute("href", base + pages[i].location);
          link.textContent = pages[i].title;
          item.appendChild(link);
          list.appendChild(item);
        }
        box.appendChild(list);
      }
      var para = doc.createElement("p");
      var search = doc.createElement("a");
      search.setAttribute("href", base + "?q=" + encodeURIComponent(terms.join(" ")));
      search.textContent = (pages.length ? "Or search for \u201c" : "Search for \u201c") +
        terms.join(" ") + "\u201d";
      para.appendChild(search);
      box.appendChild(para);
      box.hidden = false;
    }

    function run() {
      var box = doc.querySelector(".rpt-404__suggest");
      if (!box || box.getAttribute("data-rpt-done") !== null) {
        return;
      }
      box.setAttribute("data-rpt-done", "");
      var terms = termsFromPath(win.location ? win.location.pathname : "");
      if (!terms.length) {
        return;
      }
      /* The home address, made absolute and normalised by the browser
         ("/." becomes "https://host/"), with a trailing slash. */
      var anchor = doc.createElement("a");
      anchor.setAttribute("href", box.getAttribute("data-home") || ".");
      var base = anchor.href.replace(/[?#].*$/, "");
      if (base.charAt(base.length - 1) !== "/") {
        base += "/";
      }
      var index = box.getAttribute("data-index");
      if (!index || typeof win.fetch !== "function") {
        render(box, base, terms, []);
        return;
      }
      win.fetch(index, { credentials: "omit" })
        .then(function (response) {
          if (!response.ok) {
            throw new Error("search index: HTTP " + response.status);
          }
          return response.json();
        })
        .then(function (data) {
          render(box, base, terms, rank(data && data.docs, terms, MAX_LINKS));
        }, function () {
          render(box, base, terms, []);
        });
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
    termsFromPath: termsFromPath,
    safeLocation: safeLocation,
    rank: rank,
    install: install
  };
}));
