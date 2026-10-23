/* rpt-checklist: tickable task lists whose state survives a reload.

   A page opts in by writing a Markdown task list ("- [ ] Step text"), which
   pymdownx.tasklist renders as a checkbox per item (clickable_checkbox makes
   them toggle even without this script). This script then:

     - names each checkbox after its step text (the rendered label wraps no
       text, so a screen reader would otherwise announce "checkbox" only);
     - lets a click on the step text toggle the box (a bigger target), but not
       a click on a link, button or form control inside the step;
     - remembers the ticked steps per page in this browser's localStorage,
       under "rpt.checklist.v1:" + the page path, as {itemKey: 1};
     - shows "Checklist: 3 of 7 steps done" above the first task list, in a
       polite live region, with a Reset button that clears the saved state.

   An item's key is its position on the page plus the first 60 characters of
   its text, so editing or inserting a step forgets ticks instead of moving
   them to another step. Nothing is sent anywhere, and the stored text is the
   page's own. Every storage access is guarded: with storage blocked (private
   mode, a strict browser setting) the boxes still toggle, they just do not
   persist. Pages without a task list are left alone.

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

  var PREFIX = "rpt.checklist.v1:";
  var KEY_TEXT = 60;

  function collapse(text) {
    return String(text == null ? "" : text).replace(/\s+/g, " ").replace(/^ | $/g, "");
  }

  function itemKey(index, text) {
    return index + ":" + collapse(text).slice(0, KEY_TEXT);
  }

  /* The stored value, or {} for anything that is not a JSON object. Only
     keys set to 1 are kept. */
  function parseState(raw) {
    if (typeof raw !== "string") {
      return {};
    }
    var value;
    try {
      value = JSON.parse(raw);
    } catch (e) {
      return {};
    }
    var state = {};
    if (!value || typeof value !== "object" || Object.prototype.toString.call(value) !== "[object Object]") {
      return state;
    }
    for (var key in value) {
      if (Object.prototype.hasOwnProperty.call(value, key) && value[key] === 1) {
        state[key] = 1;
      }
    }
    return state;
  }

  /* items: [{key, checked}] -> the JSON stored for the page. */
  function serialize(items) {
    var state = {};
    for (var i = 0; i < items.length; i++) {
      if (items[i].checked) {
        state[items[i].key] = 1;
      }
    }
    return JSON.stringify(state);
  }

  function progressLabel(done, total) {
    return done + " of " + total + (total === 1 ? " step" : " steps") + " done";
  }

  function storageOf(win) {
    try {
      return win.localStorage || null;
    } catch (e) {
      return null;
    }
  }

  function readStored(storage, key) {
    if (!storage) {
      return null;
    }
    try {
      return storage.getItem(key);
    } catch (e) {
      return null;
    }
  }

  function writeStored(storage, key, value) {
    if (!storage) {
      return;
    }
    try {
      if (value === null) {
        storage.removeItem(key);
      } else {
        storage.setItem(key, value);
      }
    } catch (e) {
      /* blocked or full: the boxes keep working without saving */
    }
  }

  /* The item's own text, without the text of a nested list inside it. */
  function ownText(li) {
    var text = "";
    for (var node = li.firstChild; node; node = node.nextSibling) {
      if (node.nodeType === 1 && /^(UL|OL)$/.test(node.nodeName)) {
        continue;
      }
      text += node.textContent || "";
    }
    return collapse(text);
  }

  function isInteractive(el, stop) {
    for (var node = el; node && node !== stop; node = node.parentNode) {
      if (node.nodeType === 1 && /^(A|BUTTON|INPUT|LABEL|SELECT|TEXTAREA|SUMMARY)$/.test(node.nodeName)) {
        return true;
      }
    }
    return false;
  }

  function install(win) {
    var doc = win.document;
    if (!doc || typeof doc.querySelectorAll !== "function") {
      return;
    }

    function setup() {
      var lis = doc.querySelectorAll(".md-content .md-typeset .task-list-item");
      var items = [];
      for (var i = 0; i < lis.length; i++) {
        var input = lis[i].querySelector("input[type=checkbox]");
        /* The item's own box: in the item, or in its label (custom_checkbox),
           not in a nested item. */
        if (input && (input.parentNode === lis[i] || input.parentNode.parentNode === lis[i])) {
          items.push({ li: lis[i], input: input, key: itemKey(items.length, ownText(lis[i])) });
        }
      }
      if (!items.length || items[0].li.getAttribute("data-rpt-checklist") !== null) {
        return;
      }

      var storage = storageOf(win);
      var storageKey = PREFIX + (win.location ? win.location.pathname : "");
      var raw = readStored(storage, storageKey);
      var saved = raw === null ? null : parseState(raw);

      var box = doc.createElement("div");
      box.className = "rpt-progress";
      var status = doc.createElement("p");
      status.className = "rpt-progress__status";
      status.setAttribute("role", "status");
      status.setAttribute("aria-live", "polite");
      var reset = doc.createElement("button");
      reset.type = "button";
      reset.className = "md-button rpt-progress__reset";
      reset.textContent = "Reset checklist";
      box.appendChild(status);
      box.appendChild(reset);

      function refresh() {
        var done = 0;
        for (var j = 0; j < items.length; j++) {
          if (items[j].input.checked) {
            done += 1;
          }
        }
        status.textContent = "Checklist: " + progressLabel(done, items.length);
        reset.disabled = done === 0;
      }

      function save() {
        var list = [];
        for (var j = 0; j < items.length; j++) {
          list.push({ key: items[j].key, checked: items[j].input.checked });
        }
        writeStored(storage, storageKey, serialize(list));
      }

      function bind(item) {
        item.li.setAttribute("data-rpt-checklist", "");
        item.input.setAttribute("aria-label", ownText(item.li));
        if (saved) {
          item.input.checked = saved[item.key] === 1;
        }
        item.input.addEventListener("change", function () {
          save();
          refresh();
        });
        item.li.addEventListener("click", function (event) {
          var target = event.target;
          if (isInteractive(target, item.li)) {
            return;
          }
          /* A nested item handles its own clicks. */
          for (var node = target; node && node !== item.li; node = node.parentNode) {
            if (node.nodeType === 1 && /^(UL|OL)$/.test(node.nodeName)) {
              return;
            }
          }
          /* Selecting text to copy it is not a tick. */
          var selection = win.getSelection ? win.getSelection() : null;
          if (selection && String(selection).length > 0) {
            return;
          }
          item.input.click();
        });
      }

      for (var k = 0; k < items.length; k++) {
        bind(items[k]);
      }

      reset.addEventListener("click", function () {
        for (var j = 0; j < items.length; j++) {
          items[j].input.checked = false;
        }
        writeStored(storage, storageKey, null);
        refresh();
      });

      /* Above the outermost task list that holds the first item. */
      var list = items[0].li.parentNode;
      while (list.parentNode && list.parentNode.nodeType === 1 &&
             /(^| )task-list-item( |$)/.test(list.parentNode.className || "")) {
        list = list.parentNode.parentNode;
      }
      if (list.parentNode) {
        list.parentNode.insertBefore(box, list);
      }
      refresh();
    }

    /* Material's document$ emits on the first load and after every instant
       navigation; without it, run once when the page is ready. */
    if (win.document$ && typeof win.document$.subscribe === "function") {
      win.document$.subscribe(setup);
    } else if (doc.readyState === "loading") {
      doc.addEventListener("DOMContentLoaded", setup);
    } else {
      setup();
    }
  }

  return {
    PREFIX: PREFIX,
    itemKey: itemKey,
    parseState: parseState,
    serialize: serialize,
    progressLabel: progressLabel,
    install: install
  };
}));
