/* Reuse Material's search. Keep the shortcut hidden until it can open it. */
(function () {
  "use strict";

  function restoreFocusOnEscape(trigger, toggle) {
    var escapePressed = false;

    function onKeyDown(event) {
      escapePressed = event.key === "Escape";
      if (escapePressed) {
        window.setTimeout(function () { escapePressed = false; }, 0);
      }
    }

    function onSearchChange() {
      if (toggle.checked) {
        return;
      }
      document.removeEventListener("keydown", onKeyDown, true);
      toggle.removeEventListener("change", onSearchChange);
      if (escapePressed) {
        window.setTimeout(function () {
          // Material blurs its query after closing the checkbox.
          if (trigger.isConnected && !toggle.checked && document.activeElement === document.body) {
            trigger.focus();
          }
        }, 0);
      }
    }

    document.addEventListener("keydown", onKeyDown, true);
    toggle.addEventListener("change", onSearchChange);
  }

  function bindSearch() {
    var shortcut = document.querySelector(".rpt-home-search");
    var trigger = shortcut && shortcut.querySelector("[data-rpt-open-search]");
    var toggle = document.getElementById("__search");
    var search = document.querySelector('[data-md-component="search"]');
    var input = search && search.querySelector(".md-search__input");
    if (!trigger || !shortcut.hidden || !toggle || toggle.type !== "checkbox" ||
        !search || search.hidden || !input) {
      return;
    }

    trigger.addEventListener("click", function () {
      if (search.hidden) {
        return;
      }
      if (!toggle.checked) {
        restoreFocusOnEscape(trigger, toggle);
        toggle.click();
      }
      // Focus during the click so mobile Safari can open the software keyboard.
      input.focus();
    });
    shortcut.hidden = false;
  }

  if (window.document$ && typeof window.document$.subscribe === "function") {
    window.document$.subscribe(bindSearch);
  } else {
    bindSearch();
  }
}());
