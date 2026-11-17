(function () {
  // reveal on scroll
  var items = document.querySelectorAll("[data-reveal]");
  if ("IntersectionObserver" in window) {
    var io = new IntersectionObserver(function (entries) {
      entries.forEach(function (e) {
        if (e.isIntersecting) { e.target.classList.add("is-visible"); io.unobserve(e.target); }
      });
    }, { threshold: 0.12 });
    items.forEach(function (el) { io.observe(el); });
  } else {
    items.forEach(function (el) { el.classList.add("is-visible"); });
  }

  // trigger doc-shot Ken Burns zoom only when scrolled into view
  var docShots = document.querySelectorAll(".doc-shot");
  if (docShots.length) {
    if ("IntersectionObserver" in window) {
      var shotIo = new IntersectionObserver(function (entries) {
        entries.forEach(function (e) {
          if (e.isIntersecting) {
            e.target.classList.add("is-inview");
            shotIo.unobserve(e.target);
          }
        });
      }, { threshold: 0.2 });
      docShots.forEach(function (el) { shotIo.observe(el); });
    } else {
      docShots.forEach(function (el) { el.classList.add("is-inview"); });
    }
  }

  // spotlight: tab switcher + gentle auto-cycle (supports home & docs)
  document.querySelectorAll(".spotlight").forEach(function (spotlight) {
    var tabs = spotlight.querySelectorAll(".spotlight-tab");
    var slides = spotlight.querySelectorAll(".spotlight-slide");
    var idx = 0;
    var timer = null;
    var show = function (next) {
      idx = (next + slides.length) % slides.length;
      tabs.forEach(function (t, i) {
        var on = i === idx;
        t.classList.toggle("is-active", on);
        t.setAttribute("aria-selected", on ? "true" : "false");
      });
      slides.forEach(function (s, i) {
        s.classList.toggle("is-active", i === idx);
      });
    };
    var start = function () {
      if (timer) clearInterval(timer);
      timer = setInterval(function () { show(idx + 1); }, 6500);
    };
    tabs.forEach(function (tab, i) {
      tab.addEventListener("click", function () {
        show(i);
        start();
      });
    });
    spotlight.addEventListener("mouseenter", function () { if (timer) clearInterval(timer); });
    spotlight.addEventListener("mouseleave", start);
    start();
  });

  var API = "https://api.github.com/repos/imanubdesigner/tomedown.koplugin/releases";

  // download page: latest version and zip
  var version = document.getElementById("latest-version");
  if (version) {
    fetch(API + "/latest").then(function (r) { return r.ok ? r.json() : Promise.reject(); })
      .then(function (rel) {
        version.textContent = rel.tag_name;
        var zip = (rel.assets || []).filter(function (a) { return /\.zip$/.test(a.name); })[0];
        if (zip) document.getElementById("latest-link").href = zip.browser_download_url;
      }).catch(function () {});
  }

  // changelog page: release notes, rendered as plain text
  var box = document.getElementById("releases");
  if (box) {
    fetch(API + "?per_page=20").then(function (r) { return r.ok ? r.json() : Promise.reject(); })
      .then(function (list) {
        box.textContent = "";
        list.forEach(function (rel) {
          var h = document.createElement("h2");
          var a = document.createElement("a");
          a.href = rel.html_url;
          a.textContent = rel.name || rel.tag_name;
          h.appendChild(a);
          var pre = document.createElement("pre");
          pre.style.whiteSpace = "pre-wrap";
          pre.textContent = rel.body || "";
          box.appendChild(h);
          box.appendChild(pre);
        });
      }).catch(function () {});
  }

  // docs right-hand "On this page" scrollspy
  var toc = document.querySelector(".docs-toc");
  if (toc) {
    var tocLinks = Array.prototype.slice.call(toc.querySelectorAll("a[href^='#']"));
    var targets = tocLinks.map(function (a) {
      return document.getElementById(a.getAttribute("href").slice(1));
    });
    var setActive = function () {
      var y = window.scrollY + 120;
      var activeIdx = 0;
      for (var i = 0; i < targets.length; i++) {
        if (targets[i] && targets[i].offsetTop <= y) activeIdx = i;
      }
      tocLinks.forEach(function (a, i) {
        a.classList.toggle("is-active", i === activeIdx);
      });
    };
    window.addEventListener("scroll", setActive, { passive: true });
    setActive();
  }

  // lightbox overlay for obsidian-guide SVGs
  var guideImages = document.querySelectorAll(".docs .prose img[src*='obsidian-guide']");
  if (guideImages.length) {
    var overlay = document.createElement("div");
    overlay.className = "guide-lightbox";
    overlay.innerHTML = "<div class='guide-lightbox-inner'><img src='' alt='' /><button type='button' class='guide-lightbox-close' aria-label='Close'>&times;</button></div>";
    document.body.appendChild(overlay);
    var overlayImg = overlay.querySelector("img");
    var closeBtn = overlay.querySelector(".guide-lightbox-close");
    var closeLightbox = function () {
      overlay.classList.remove("is-open");
      document.body.style.overflow = "";
    };
    guideImages.forEach(function (img) {
      img.addEventListener("click", function () {
        overlayImg.src = img.src;
        overlayImg.alt = img.alt || "";
        overlay.classList.add("is-open");
        document.body.style.overflow = "hidden";
      });
    });
    overlay.addEventListener("click", function (e) {
      if (e.target === overlay || e.target === closeBtn) closeLightbox();
    });
    window.addEventListener("keydown", function (e) {
      if (e.key === "Escape" && overlay.classList.contains("is-open")) closeLightbox();
    });
  }

  // 6 Special Highlights Interactive Switcher
  var showcase = document.querySelector(".styles-showcase");
  if (showcase) {
    var styleTabs = showcase.querySelectorAll(".style-tab");
    var stylePanes = showcase.querySelectorAll(".style-pane");
    styleTabs.forEach(function (tab) {
      tab.addEventListener("click", function () {
        var targetStyle = tab.getAttribute("data-style");
        styleTabs.forEach(function (t) {
          var on = t === tab;
          t.classList.toggle("is-active", on);
          t.setAttribute("aria-selected", on ? "true" : "false");
        });
        stylePanes.forEach(function (p) {
          p.classList.toggle("is-active", p.getAttribute("data-pane") === targetStyle);
        });
      });
    });
  }


  // Documentation Hub Live Filter & Command Palette (Ctrl+K / Cmd+K)
  var searchInput = document.getElementById("hub-search-input");
  if (searchInput) {
    var chapters = document.querySelectorAll(".hub-chapter");
    var emptyMsg = document.getElementById("hub-empty");

    var filterDocs = function () {
      var q = searchInput.value.trim().toLowerCase();
      var totalVisible = 0;
      chapters.forEach(function (chap) {
        var chapCards = chap.querySelectorAll(".hub-card");
        var visibleCount = 0;
        chapCards.forEach(function (c) {
          var title = c.getAttribute("data-title") || "";
          var desc = c.getAttribute("data-desc") || "";
          var match = !q || title.indexOf(q) !== -1 || desc.indexOf(q) !== -1;
          c.style.display = match ? "" : "none";
          if (match) visibleCount++;
        });
        chap.style.display = visibleCount > 0 ? "" : "none";
        totalVisible += visibleCount;
      });
      if (emptyMsg) {
        emptyMsg.hidden = totalVisible > 0;
      }
    };

    searchInput.addEventListener("input", filterDocs);

    window.addEventListener("keydown", function (e) {
      if ((e.metaKey || e.ctrlKey) && e.key.toLowerCase() === "k") {
        e.preventDefault();
        searchInput.focus();
        searchInput.select();
      } else if (e.key === "Escape" && document.activeElement === searchInput && searchInput.value) {
        searchInput.value = "";
        filterDocs();
      }
    });
  }

  // light / dark theme toggle (follows OS by default)
  var themeBtn = document.getElementById("theme-toggle");
  if (themeBtn) {
    themeBtn.addEventListener("click", function () {
      var root = document.documentElement;
      var current = root.dataset.theme || (window.matchMedia("(prefers-color-scheme: dark)").matches ? "dark" : "light");
      var next = current === "dark" ? "light" : "dark";
      root.dataset.theme = next;
      try { localStorage.setItem("tomedown-theme", next); } catch (e) {}
    });
  }
})();
