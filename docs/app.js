/* slang docs — progressive enhancement only.
 *
 * Every word of every page is in the HTML. This file adds the theme
 * toggle, client-side search, a table of contents, copy buttons, the
 * scroll reveal and the hero animation. With JavaScript disabled or
 * unavailable -- which is the normal case for a crawler or an agent
 * fetching the page -- nothing here is load-bearing. */

(function () {
  "use strict";

  var root = document.documentElement;

  /* ---- theme ------------------------------------------------------ */
  var saved = null;
  try { saved = localStorage.getItem("slang-theme"); } catch (e) {}
  if (saved === "dark" || saved === "light") root.dataset.theme = saved;

  var themeBtn = document.getElementById("theme");
  if (themeBtn) {
    themeBtn.addEventListener("click", function () {
      var dark = root.dataset.theme
        ? root.dataset.theme === "dark"
        : matchMedia("(prefers-color-scheme: dark)").matches;
      var next = dark ? "light" : "dark";
      root.dataset.theme = next;
      try { localStorage.setItem("slang-theme", next); } catch (e) {}
    });
  }

  /* ---- mobile nav --------------------------------------------------
   * Below 64rem (style.css) .mainnav starts collapsed; this just
   * toggles the .open class and mirrors it into aria-expanded and the
   * tap-outside scrim. Without JS the panel stays collapsed and the
   * links are still there in the HTML, just not reachable through the
   * toggle -- a real loss on a phone, but every page is also on its
   * own line in the footer-less nav of the Markdown twin, so nothing
   * is unreachable, only less convenient. */
  var navToggle = document.getElementById("navtoggle");
  var mainNav = document.getElementById("mainnav");
  var navScrim = document.getElementById("navscrim");
  if (navToggle && mainNav && navScrim) {
    var closeNav = function () {
      mainNav.classList.remove("open");
      navToggle.setAttribute("aria-expanded", "false");
      navScrim.hidden = true;
    };
    var openNav = function () {
      mainNav.classList.add("open");
      navToggle.setAttribute("aria-expanded", "true");
      navScrim.hidden = false;
    };
    navToggle.addEventListener("click", function () {
      if (mainNav.classList.contains("open")) closeNav(); else openNav();
    });
    navScrim.addEventListener("click", closeNav);
    mainNav.addEventListener("click", function (e) {
      if (e.target.tagName === "A") closeNav();
    });
    document.addEventListener("keydown", function (e) {
      if (e.key === "Escape" && mainNav.classList.contains("open")) {
        closeNav(); navToggle.focus();
      }
    });
  }

  /* ---- copy buttons ----------------------------------------------- */
  document.querySelectorAll(".code .copy").forEach(function (btn) {
    btn.addEventListener("click", function () {
      var code = btn.parentElement.querySelector("code");
      if (!code) return;
      var done = function () {
        btn.textContent = "Copied";
        btn.classList.add("ok");
        setTimeout(function () {
          btn.textContent = "Copy";
          btn.classList.remove("ok");
        }, 1400);
      };
      if (navigator.clipboard && navigator.clipboard.writeText) {
        navigator.clipboard.writeText(code.innerText).then(done, function () {});
      }
    });
  });

  /* ---- table of contents ------------------------------------------ */
  var tocBox = document.getElementById("toc");
  var heads = [].slice.call(
    document.querySelectorAll(".content h2[id], .content h3[id]"));
  if (tocBox && heads.length > 1) {
    heads.forEach(function (h) {
      var a = document.createElement("a");
      a.href = "#" + h.id;
      a.textContent = h.textContent.replace(/#$/, "").trim();
      if (h.tagName === "H3") a.className = "h3";
      tocBox.appendChild(a);
    });
    var links = [].slice.call(tocBox.querySelectorAll("a"));
    if ("IntersectionObserver" in window) {
      var seen = new Map();
      var io = new IntersectionObserver(function (entries) {
        entries.forEach(function (e) { seen.set(e.target.id, e.isIntersecting); });
        for (var i = 0; i < heads.length; i++) {
          if (seen.get(heads[i].id)) {
            links.forEach(function (l) { l.classList.remove("active"); });
            var m = links.filter(function (l) {
              return l.getAttribute("href") === "#" + heads[i].id;
            })[0];
            if (m) m.classList.add("active");
            break;
          }
        }
      }, { rootMargin: "-80px 0px -70% 0px" });
      heads.forEach(function (h) { io.observe(h); });
    }
  }

  /* ---- search ------------------------------------------------------ */
  var input = document.getElementById("search");
  var results = document.getElementById("results");
  var index = null;
  var rootPath = (document.querySelector('link[rel=stylesheet]')
    .getAttribute("href") || "").replace(/style\.css$/, "");

  function load() {
    if (index) return Promise.resolve(index);
    return fetch(rootPath + "search.json")
      .then(function (r) { return r.json(); })
      .then(function (j) { index = j; return j; })
      .catch(function () { index = []; return index; });
  }

  function render(items, q) {
    if (!items.length) {
      results.innerHTML = '<p class="empty">No matches for “'
        + q.replace(/[<>&]/g, "") + '”.</p>';
    } else {
      results.innerHTML = items.map(function (it) {
        return '<a href="' + rootPath + it.url + '">'
          + '<span class="r-t">' + it.title + "</span><br>"
          + '<span class="r-s">' + it.tagline + "</span></a>";
      }).join("");
    }
    results.hidden = false;
  }

  function search(q) {
    var needle = q.toLowerCase().trim();
    if (needle.length < 2) { results.hidden = true; return; }
    load().then(function (idx) {
      var scored = [];
      idx.forEach(function (it) {
        var t = it.title.toLowerCase();
        var body = (it.text || "").toLowerCase();
        var score = 0;
        if (t === needle) score = 100;
        else if (t.indexOf(needle) === 0) score = 60;
        else if (t.indexOf(needle) > -1) score = 40;
        else if ((it.tagline || "").toLowerCase().indexOf(needle) > -1) score = 20;
        else if (body.indexOf(needle) > -1) score = 10;
        if (score) scored.push({ it: it, score: score });
      });
      scored.sort(function (a, b) { return b.score - a.score; });
      render(scored.slice(0, 12).map(function (s) { return s.it; }), q);
    });
  }

  if (input && results) {
    input.addEventListener("input", function () { search(input.value); });
    input.addEventListener("focus", function () {
      if (input.value.trim().length > 1) search(input.value);
    });
    document.addEventListener("click", function (e) {
      if (!results.contains(e.target) && e.target !== input) results.hidden = true;
    });
    document.addEventListener("keydown", function (e) {
      if (e.key === "/" && document.activeElement !== input) {
        e.preventDefault(); input.focus();
      } else if (e.key === "Escape") {
        results.hidden = true; input.blur();
      }
    });
  }

  /* ---- reveal on scroll -------------------------------------------- */
  var reduce = matchMedia("(prefers-reduced-motion: reduce)").matches;
  if (!reduce && "IntersectionObserver" in window) {
    var targets = document.querySelectorAll(
      ".features article, .pkg-card, .content h2, .code");
    var ro = new IntersectionObserver(function (entries, obs) {
      entries.forEach(function (e) {
        if (e.isIntersecting) { e.target.classList.add("in"); obs.unobserve(e.target); }
      });
    }, { rootMargin: "0px 0px -8% 0px" });
    targets.forEach(function (t) {
      if (t.getBoundingClientRect().top < window.innerHeight) return;
      t.classList.add("reveal");
      ro.observe(t);
    });
  }

  /* ---- the hero demo ------------------------------------------------
   * Six 300ms requests on one connection. Run them multiplexed and they
   * finish together in a bit over 300ms; run them one after another and
   * it is 1.8s. That contrast is the whole argument for the scheduler,
   * so the landing page shows it rather than asserting it. The numbers
   * are a real measurement from tests/http2_flow, not invented. */
  var lanes = document.getElementById("lanes");
  var runBtn = document.getElementById("run-demo");
  var readout = document.getElementById("readout");
  if (lanes && runBtn && readout) {
    var N = 6, TASK_MS = 300, fills = [];
    for (var i = 0; i < N; i++) {
      var lane = document.createElement("div");
      lane.className = "lane";
      lane.innerHTML = '<span class="lane-label">stream ' + (i + 1)
        + '</span><span class="track"><span class="fill"></span></span>';
      lanes.appendChild(lane);
      fills.push(lane.querySelector(".fill"));
    }

    var running = false;
    function reset() { fills.forEach(function (f) { f.style.width = "0%"; }); }

    function run(concurrent) {
      if (running) return;
      running = true;
      reset();
      readout.classList.remove("done");
      var start = performance.now();
      var scale = 6;                       /* wall-clock speed-up */
      var total = concurrent ? TASK_MS : TASK_MS * N;

      function frame(now) {
        var t = (now - start) * scale;
        for (var k = 0; k < N; k++) {
          var began = concurrent ? 0 : k * TASK_MS;
          var p = Math.max(0, Math.min(1, (t - began) / TASK_MS));
          fills[k].style.width = (p * 100).toFixed(1) + "%";
          fills[k].classList.toggle("waiting", !concurrent && p > 0 && p < 1);
        }
        readout.textContent = Math.min(total, Math.round(t)) + "ms";
        if (t < total) {
          requestAnimationFrame(frame);
        } else {
          readout.textContent = total + "ms "
            + (concurrent ? "— multiplexed" : "— serialised");
          readout.classList.add("done");
          running = false;
          runBtn.textContent = concurrent ? "Run serialised" : "Run multiplexed";
          runBtn.dataset.next = concurrent ? "serial" : "concurrent";
        }
      }
      requestAnimationFrame(frame);
    }

    runBtn.dataset.next = "concurrent";
    runBtn.addEventListener("click", function () {
      run(runBtn.dataset.next !== "serial");
    });
    if (!reduce) setTimeout(function () { run(true); }, 600);
  }
})();
