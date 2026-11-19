/* slang docs: progressive enhancement only.
 *
 * Every word of every page is in the HTML. This file adds the theme
 * toggle, the menus, copy buttons, the on-page contents and the search
 * palette. With JavaScript off -- the normal case for a crawler or an
 * agent fetching a page -- nothing here is load-bearing: the sidebar,
 * header links and previous/next links all work as plain links. */

(function () {
  "use strict";

  var root = document.documentElement;
  var $ = function (s, el) { return (el || document).querySelector(s); };
  var $$ = function (s, el) { return [].slice.call((el || document).querySelectorAll(s)); };

  /* Where the site root is, from this page: the stylesheet is always
   * linked as <root>style.css. */
  var styleLink = $('link[rel=stylesheet][href$="style.css"]');
  var rootPath = styleLink ? (styleLink.getAttribute("href") || "").replace(/style\.css$/, "") : "";

  /* ---- theme ---------------------------------------------------------- */
  function isDark() {
    var t = root.dataset.theme;
    if (t === "dark") return true;
    if (t === "light") return false;
    return !matchMedia("(prefers-color-scheme: light)").matches;
  }
  function syncThemeLabel(btn) {
    btn.setAttribute("aria-label", isDark() ? "Switch to light theme" : "Switch to dark theme");
  }
  $$("[data-theme-toggle]").forEach(function (btn) {
    syncThemeLabel(btn);
    btn.addEventListener("click", function () {
      var next = isDark() ? "light" : "dark";
      root.dataset.theme = next;
      try { localStorage.setItem("slang-theme", next); } catch (e) {}
      syncThemeLabel(btn);
    });
  });

  /* ---- header menu (below the width the links fit) ---------------------- */
  var menuBtn = $("[data-menu]");
  var sheet = $("#nav-sheet");
  if (menuBtn && sheet) {
    menuBtn.addEventListener("click", function () {
      var open = sheet.hidden;
      sheet.hidden = !open;
      menuBtn.setAttribute("aria-expanded", String(open));
    });
  }

  /* ---- docs drawer (phones and tablets) ---------------------------------- */
  var drawerBtn = $("[data-drawer]");
  var sidebar = $("#sidebar");
  var scrim = $("[data-scrim]");
  function closeDrawer() {
    if (!sidebar) return;
    sidebar.classList.remove("open");
    if (scrim) scrim.hidden = true;
    if (drawerBtn) drawerBtn.setAttribute("aria-expanded", "false");
    document.body.style.overflow = "";
  }
  function openDrawer() {
    sidebar.classList.add("open");
    if (scrim) scrim.hidden = false;
    drawerBtn.setAttribute("aria-expanded", "true");
    document.body.style.overflow = "hidden";
    var here = $('[aria-current="page"]', sidebar);
    (here || $("a", sidebar)).focus({ preventScroll: true });
    if (here) here.scrollIntoView({ block: "center" });
  }
  if (drawerBtn && sidebar) {
    drawerBtn.addEventListener("click", function () {
      if (sidebar.classList.contains("open")) closeDrawer(); else openDrawer();
    });
    if (scrim) scrim.addEventListener("click", closeDrawer);
    sidebar.addEventListener("click", function (e) {
      if (e.target.closest("a")) closeDrawer();
    });
  }

  /* Keep the current page in view in a long sidebar (the package list). */
  if (sidebar && matchMedia("(min-width: 1025px)").matches) {
    var cur = $('[aria-current="page"]', sidebar);
    if (cur) {
      var r = cur.getBoundingClientRect();
      if (r.bottom > window.innerHeight - 40) sidebar.scrollTop += r.top - window.innerHeight / 2;
    }
  }

  /* ---- copy buttons ------------------------------------------------------- */
  $$(".code .copy").forEach(function (btn) {
    btn.addEventListener("click", function () {
      var code = btn.closest(".code").querySelector("pre code");
      if (!code || !navigator.clipboard) return;
      navigator.clipboard.writeText(code.innerText).then(function () {
        btn.textContent = "Copied";
        btn.classList.add("ok");
        setTimeout(function () { btn.textContent = "Copy"; btn.classList.remove("ok"); }, 1400);
      }, function () {});
    });
  });

  /* ---- on this page --------------------------------------------------------- */
  /* Headings, and on a package page every API item under its "API"
   * heading: there the contents list is the index of the package's
   * functions. */
  var tocBox = $("#toc");
  var heads = $$(".content h2[id], .content h3[id], .content .api-item[id]");
  function tocLabel(h) {
    if (h.classList.contains("api-item")) {
      var m = (h.querySelector(".api-sig code") || h).textContent
        .match(/(?:fn|struct|let|enum)\s+([A-Za-z_][A-Za-z0-9_.]*)/);
      return m ? m[1] : h.id;
    }
    return h.textContent.replace(/#\s*$/, "").trim();
  }
  if (tocBox && heads.length > 1) {
    heads.forEach(function (h) {
      var a = document.createElement("a");
      a.href = "#" + h.id;
      a.textContent = tocLabel(h);
      if (h.tagName === "H3" || h.classList.contains("api-item")) a.className = "h3";
      if (h.classList.contains("api-item")) a.classList.add("api");
      tocBox.appendChild(a);
    });
    var links = $$("a", tocBox);
    if ("IntersectionObserver" in window) {
      var visible = {};
      var io = new IntersectionObserver(function (entries) {
        entries.forEach(function (e) { visible[e.target.id] = e.isIntersecting; });
        var first = null;
        for (var i = 0; i < heads.length; i++) if (visible[heads[i].id]) { first = heads[i].id; break; }
        if (!first) return;
        links.forEach(function (l) { l.classList.toggle("active", l.getAttribute("href") === "#" + first); });
      }, { rootMargin: "-90px 0px -65% 0px" });
      heads.forEach(function (h) { io.observe(h); });
    }
  }

  /* ---- search palette -------------------------------------------------------- */
  var palette = $("#palette");
  var input = $("#palette-input");
  var list = $("#palette-list");
  var index = null;
  var items = [];
  var sel = 0;
  var lastFocus = null;

  function esc(s) {
    return String(s).replace(/[&<>"]/g, function (c) {
      return { "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;" }[c];
    });
  }
  function mark(text, words) {
    var out = esc(text);
    words.forEach(function (w) {
      if (!w) return;
      var re = new RegExp("(" + w.replace(/[.*+?^${}()|[\]\\]/g, "\\$&") + ")", "ig");
      out = out.replace(re, "<mark>$1</mark>");
    });
    return out;
  }

  function load() {
    if (index) return Promise.resolve(index);
    return fetch(rootPath + "search.json")
      .then(function (r) { return r.json(); })
      .then(function (j) {
        index = j.map(function (it) {
          it._t = (it.title || "").toLowerCase();
          it._n = (it.name || "").toLowerCase();
          it._s = (it.sig || it.tagline || "").toLowerCase();
          it._x = (it.text || "").toLowerCase();
          return it;
        });
        return index;
      })
      .catch(function () { index = []; return index; });
  }

  /* Every word must match somewhere; a word scores by where it matched,
   * strongest first: the exact name, its start, anywhere in the name,
   * then the signature or tagline, then the body. */
  function scoreOf(it, words) {
    var total = 0;
    for (var i = 0; i < words.length; i++) {
      var w = words[i], s = 0;
      if (it._t === w || it._n === w) s = 100;
      else if (it._t.indexOf(w) === 0 || it._n.indexOf(w) === 0) s = 70;
      else if (it._t.indexOf("." + w) > -1 || it._t.indexOf("_" + w) > -1) s = 55;
      else if (it._t.indexOf(w) > -1) s = 45;
      else if (it._s.indexOf(w) > -1) s = 20;
      else if (it._x.indexOf(w) > -1) s = 8;
      if (!s) return 0;
      total += s;
    }
    if (it.kind === "page") total += 6;
    return total - Math.min(it._t.length, 40) / 40;
  }

  function render(q) {
    var words = q.toLowerCase().split(/\s+/).filter(Boolean);
    if (!words.length) {
      items = index.filter(function (it) { return it.kind === "page"; }).slice(0, 12);
      draw(items, [], "Pages");
      return;
    }
    var scored = [];
    index.forEach(function (it) {
      var s = scoreOf(it, words);
      if (s > 0) scored.push({ it: it, s: s });
    });
    scored.sort(function (a, b) { return b.s - a.s; });
    var pages = [], api = [], best = { page: 0, api: 0 };
    scored.forEach(function (x) {
      var k = x.it.kind === "page" ? "page" : "api";
      if (!best[k]) best[k] = x.s;
      if (k === "page") { if (pages.length < 6) pages.push(x.it); }
      else if (api.length < 40) api.push(x.it);
    });
    /* The group with the better match goes first: "verify" should lead
     * with x509.verify, not with the pages whose prose mentions it. */
    items = best.api > best.page ? api.concat(pages) : pages.concat(api);
    draw(items, words);
  }

  function draw(rows, words, onlyTitle) {
    sel = 0;
    if (!rows.length) {
      list.innerHTML = '<p class="palette-empty">Nothing matches “' + esc(input.value.trim()) + '”.</p>';
      return;
    }
    var html = [], group = null;
    rows.forEach(function (it, i) {
      var g = it.kind === "page" ? "Pages" : "API";
      if (onlyTitle) g = onlyTitle;
      if (g !== group) { html.push('<p class="palette-group">' + g + "</p>"); group = g; }
      var isApi = it.kind === "api";
      html.push(
        '<a class="palette-item" role="option" id="pi-' + i + '" href="' + esc(rootPath + it.url) + '"' +
        (i === 0 ? ' aria-selected="true"' : "") + ">" +
        '<span class="pi-title' + (isApi ? " is-code" : "") + '">' + mark(it.title, words) + "</span>" +
        '<span class="pi-sub' + (isApi ? " is-code" : "") + '">' + esc(isApi ? it.sig : it.tagline) + "</span></a>");
    });
    list.innerHTML = html.join("");
    input.setAttribute("aria-activedescendant", "pi-0");
  }

  function move(d) {
    var els = $$(".palette-item", list);
    if (!els.length) return;
    els[sel].removeAttribute("aria-selected");
    sel = (sel + d + els.length) % els.length;
    els[sel].setAttribute("aria-selected", "true");
    els[sel].scrollIntoView({ block: "nearest" });
    input.setAttribute("aria-activedescendant", els[sel].id);
  }

  function openPalette() {
    if (!palette) return;
    lastFocus = document.activeElement;
    palette.hidden = false;
    document.body.style.overflow = "hidden";
    input.value = "";
    input.focus();
    load().then(function () { render(""); });
  }
  function closePalette() {
    if (!palette || palette.hidden) return;
    palette.hidden = true;
    document.body.style.overflow = "";
    if (lastFocus && lastFocus.focus) lastFocus.focus();
  }

  if (palette && input && list) {
    $$("[data-search]").forEach(function (b) { b.addEventListener("click", openPalette); });
    input.addEventListener("input", function () { load().then(function () { render(input.value); }); });
    input.addEventListener("keydown", function (e) {
      if (e.key === "ArrowDown") { e.preventDefault(); move(1); }
      else if (e.key === "ArrowUp") { e.preventDefault(); move(-1); }
      else if (e.key === "Enter") {
        var cur = $$(".palette-item", list)[sel];
        if (cur) { e.preventDefault(); closePalette(); location.href = cur.href; }
      }
    });
    palette.addEventListener("click", function (e) {
      if (e.target === palette) closePalette();
      else if (e.target.closest(".palette-item")) closePalette();
    });
    list.addEventListener("mousemove", function (e) {
      var it = e.target.closest(".palette-item");
      if (!it) return;
      var els = $$(".palette-item", list), i = els.indexOf(it);
      if (i < 0 || i === sel) return;
      els[sel].removeAttribute("aria-selected");
      sel = i;
      it.setAttribute("aria-selected", "true");
    });
  }

  document.addEventListener("keydown", function (e) {
    var typing = /^(INPUT|TEXTAREA|SELECT)$/.test(document.activeElement.tagName) ||
                 document.activeElement.isContentEditable;
    if ((e.key === "k" || e.key === "K") && (e.metaKey || e.ctrlKey)) {
      e.preventDefault();
      if (palette && palette.hidden) openPalette(); else closePalette();
    } else if (e.key === "/" && !typing && palette && palette.hidden) {
      e.preventDefault();
      openPalette();
    } else if (e.key === "Escape") {
      if (palette && !palette.hidden) closePalette();
      else if (sidebar && sidebar.classList.contains("open")) { closeDrawer(); drawerBtn.focus(); }
      else if (sheet && !sheet.hidden) { sheet.hidden = true; menuBtn.setAttribute("aria-expanded", "false"); }
    }
  });
})();
