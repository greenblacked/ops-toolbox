/* rpt-table-filter: a live row filter above long tables.

   Any Markdown table (table:not([class]) inside .md-typeset) with at least
   MIN_ROWS body rows gets a labelled search box above it. Typing narrows the
   rows: a row stays when every whitespace-separated term of the query is a
   substring of its text, case-insensitively, so "linux doctor" or "dry run"
   work. Rows are only given the hidden attribute, never removed, so the
   browser's find, copy and print still see them (print shows every row).

   A ?filter=terms query parameter pre-fills the box, so another page can
   link to a filtered view. The query text comes from the address bar, so it
   is treated as untrusted: the DOM is built with createElement and
   textContent only, and the address is never written back.

   ES5 on purpose (old iOS Safari and Android WebViews): no let/const, arrow
   functions or URLSearchParams; Element.closest is feature-detected. No
   network, no storage. Without JavaScript the table is unchanged.

   The pure functions are exported for the unit tests in
   test-env/python/tests/test_docs_site.py; in a browser the file installs
   itself instead. */
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

  var MIN_ROWS = 15;
  var MAX_QUERY = 100;

  /* Lowercase, with every run of whitespace collapsed to one space. */
  function normalize(text) {
    return String(text == null ? "" : text).toLowerCase().replace(/\s+/g, " ").replace(/^ | $/g, "");
  }

  function terms(query) {
    var parts = normalize(query).split(" ");
    var out = [];
    for (var i = 0; i < parts.length; i++) {
      if (parts[i]) {
        out.push(parts[i]);
      }
    }
    return out;
  }

  /* True when every term of the query occurs in the row text. An empty
     query matches every row. */
  function matches(rowText, query) {
    var wanted = terms(query);
    var hay = normalize(rowText);
    for (var i = 0; i < wanted.length; i++) {
      if (hay.indexOf(wanted[i]) === -1) {
        return false;
      }
    }
    return true;
  }

  /* The status line. Empty while no filter is applied, so the live region
     says nothing until the reader types. */
  function countLabel(shown, total, query) {
    var q = normalize(query);
    if (!q) {
      return "";
    }
    if (shown === 0) {
      return "No rows match \"" + q + "\"";
    }
    return "Showing " + shown + " of " + total + (total === 1 ? " row" : " rows");
  }

  /* The filter parameter of a location.search string ("?filter=dry+run"),
     decoded, at most MAX_QUERY characters; "" when absent. A malformed
     percent escape keeps the raw text rather than throwing. */
  function readQuery(search) {
    var text = String(search == null ? "" : search).replace(/^\?/, "");
    if (!text) {
      return "";
    }
    var pairs = text.split("&");
    for (var i = 0; i < pairs.length; i++) {
      var eq = pairs[i].indexOf("=");
      var name = eq === -1 ? pairs[i] : pairs[i].slice(0, eq);
      if (name !== "filter") {
        continue;
      }
      var value = eq === -1 ? "" : pairs[i].slice(eq + 1).replace(/\+/g, " ");
      try {
        value = decodeURIComponent(value);
      } catch (e) {
        /* keep the raw text */
      }
      return value.slice(0, MAX_QUERY);
    }
    return "";
  }

  function closest(el, selector) {
    if (typeof el.closest === "function") {
      return el.closest(selector);
    }
    var match = el.matches || el.msMatchesSelector || el.webkitMatchesSelector;
    for (var node = el; node && node.nodeType === 1; node = node.parentNode) {
      if (match && match.call(node, selector)) {
        return node;
      }
    }
    return null;
  }

  function install(win) {
    var doc = win.document;
    if (!doc || typeof doc.querySelectorAll !== "function") {
      return;
    }
    var counter = 0;

    function enhance(table, initial) {
      if (table.getAttribute("data-rpt-filter") !== null) {
        return;
      }
      var body = table.tBodies && table.tBodies[0];
      if (!body || body.rows.length < MIN_ROWS) {
        return;
      }
      table.setAttribute("data-rpt-filter", "");
      /* Material wraps each table in a scrolling container; the box goes
         before that container, or before the table if it is not wrapped. */
      var anchor = closest(table, ".md-typeset__scrollwrap") || table;
      if (!anchor.parentNode) {
        return;
      }
      counter += 1;
      var id = "rpt-filter-" + counter;

      var box = doc.createElement("div");
      box.className = "rpt-filter";
      var label = doc.createElement("label");
      label.setAttribute("for", id);
      label.textContent = "Filter rows";
      var input = doc.createElement("input");
      input.type = "search";
      input.id = id;
      input.setAttribute("autocomplete", "off");
      input.setAttribute("spellcheck", "false");
      var status = doc.createElement("p");
      status.className = "rpt-filter__count";
      status.setAttribute("role", "status");
      status.setAttribute("aria-live", "polite");
      box.appendChild(label);
      box.appendChild(input);
      box.appendChild(status);
      anchor.parentNode.insertBefore(box, anchor);

      var rows = body.rows;
      var texts = [];
      for (var i = 0; i < rows.length; i++) {
        texts.push(normalize(rows[i].textContent));
      }

      function apply() {
        var shown = 0;
        for (var j = 0; j < rows.length; j++) {
          var keep = matches(texts[j], input.value);
          rows[j].hidden = !keep;
          if (keep) {
            shown += 1;
          }
        }
        status.textContent = countLabel(shown, rows.length, input.value);
      }

      input.addEventListener("input", apply);
      input.addEventListener("keydown", function (event) {
        var key = event.key || "";
        if ((key === "Escape" || key === "Esc") && input.value) {
          input.value = "";
          apply();
          event.preventDefault();
        }
      });
      if (initial) {
        input.value = initial;
        apply();
      }
    }

    function scan() {
      var initial = readQuery(win.location ? win.location.search : "");
      var tables = doc.querySelectorAll(".md-typeset table:not([class])");
      for (var i = 0; i < tables.length; i++) {
        enhance(tables[i], initial);
      }
    }

    /* Material's document$ emits on the first load and after every instant
       navigation; without it, run once when the page is ready. */
    if (win.document$ && typeof win.document$.subscribe === "function") {
      win.document$.subscribe(scan);
    } else if (doc.readyState === "loading") {
      doc.addEventListener("DOMContentLoaded", scan);
    } else {
      scan();
    }
  }

  return {
    MIN_ROWS: MIN_ROWS,
    normalize: normalize,
    matches: matches,
    countLabel: countLabel,
    readQuery: readQuery,
    install: install
  };
}));
