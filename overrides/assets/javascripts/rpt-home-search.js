/* Open Material's own search from the homepage; no duplicate search index. */
(function () {
  "use strict";
  document.addEventListener("click", function (event) {
    var trigger = event.target.closest("[data-rpt-open-search]");
    if (!trigger) return;

    var toggle = document.getElementById("__search");
    var input = document.querySelector(".md-search__input");

    if (toggle && toggle.type === "checkbox") {
      toggle.checked = true;
      toggle.dispatchEvent(new Event("change", { bubbles: true }));
    }

    if (input) {
      window.requestAnimationFrame(function () { input.focus(); });
    } else if (toggle) {
      toggle.focus();
    }
  });
}());
