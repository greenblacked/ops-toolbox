/* rpt-build-stamp: "Build 6a88b2e" in the footer, linked to that commit, and
   a "Preview build" marker on a page served with X-Robots-Tag: noindex.

   overrides/partials/copyright.html carries a hidden .rpt-build element
   with the repository URL (config.repo_url) and the address of version.txt,
   which every deploy writes with the full commit SHA. This script fetches
   that file once (same origin, no cache, no credentials) and fills the
   element. The stage preview is the deploy that answers with
   X-Robots-Tag: noindex, so the same response says whether this is it.

   The body is used only when it is exactly 40 lowercase hex characters, and
   the link only when the repository URL is a plain https://github.com/
   owner/name address, so a tampered file cannot inject markup or an
   off-site link; text goes in through textContent. Anything else (mkdocs
   serve has no version.txt, offline, an unexpected body) leaves the element
   hidden and says nothing.

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

  var REPO = /^https:\/\/github\.com\/[\w.-]+\/[\w.-]+$/;

  /* The commit SHA in a version.txt body, or null. */
  function parseSha(text) {
    var value = String(text == null ? "" : text).replace(/^\s+|\s+$/g, "");
    return /^[0-9a-f]{40}$/.test(value) ? value : null;
  }

  function shortSha(sha) {
    return String(sha).slice(0, 7);
  }

  /* The commit page on GitHub, or null when the repository URL is not a
     plain GitHub repository address or the SHA is not one. */
  function commitUrl(repo, sha) {
    var base = String(repo == null ? "" : repo).replace(/\/$/, "");
    if (!REPO.test(base) || parseSha(sha) === null) {
      return null;
    }
    return base + "/commit/" + sha;
  }

  function isPreview(headerValue) {
    return /(^|[\s,])noindex([\s,]|$)/i.test(String(headerValue == null ? "" : headerValue));
  }

  function install(win) {
    var doc = win.document;
    if (!doc || typeof doc.querySelector !== "function") {
      return;
    }
    /* One request per page load: instant navigation re-renders the footer,
       but the deployed commit does not change between pages. */
    var pending = null;

    function load(src) {
      if (!pending) {
        pending = win.fetch(src, { cache: "no-store", credentials: "omit" })
          .then(function (response) {
            var type = response.headers.get("content-type") || "";
            if (!response.ok || type.indexOf("text/") !== 0) {
              throw new Error("version.txt: unusable response");
            }
            var preview = isPreview(response.headers.get("x-robots-tag"));
            return response.text().then(function (body) {
              var sha = parseSha(body);
              if (sha === null) {
                throw new Error("version.txt: not a commit SHA");
              }
              return { sha: sha, preview: preview };
            });
          });
      }
      return pending;
    }

    function fill(el, build) {
      var repo = el.getAttribute("data-repo");
      el.appendChild(doc.createTextNode("\u00b7 "));
      if (build.preview) {
        var flag = doc.createElement("span");
        flag.className = "rpt-build__flag";
        flag.textContent = "Preview build";
        el.appendChild(flag);
        el.appendChild(doc.createTextNode(" "));
      }
      el.appendChild(doc.createTextNode("Build "));
      var url = commitUrl(repo, build.sha);
      var sha;
      if (url) {
        sha = doc.createElement("a");
        sha.setAttribute("href", url);
        sha.setAttribute("title", "Commit " + build.sha);
      } else {
        sha = doc.createElement("code");
      }
      sha.textContent = shortSha(build.sha);
      el.appendChild(sha);
      el.hidden = false;
    }

    function run() {
      var el = doc.querySelector(".rpt-build");
      if (!el || el.getAttribute("data-rpt-done") !== null) {
        return;
      }
      el.setAttribute("data-rpt-done", "");
      var src = el.getAttribute("data-src");
      if (!src || typeof win.fetch !== "function") {
        return;
      }
      load(src).then(function (build) {
        fill(el, build);
      }, function () {
        /* stay hidden */
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
    parseSha: parseSha,
    shortSha: shortSha,
    commitUrl: commitUrl,
    isPreview: isPreview,
    install: install
  };
}));
