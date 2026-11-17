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

  // Interactive intelligent zoom inspector for obsidian-guide SVGs
  var guideImages = document.querySelectorAll(".docs .prose img[src*='obsidian-guide']");
  if (guideImages.length) {
    // 1. Wrap each in-page guide image with interactive wrapper and badge
    guideImages.forEach(function (img) {
      if (img.parentElement && img.parentElement.classList.contains("guide-interactive-wrapper")) return;
      var wrapper = document.createElement("div");
      wrapper.className = "guide-interactive-wrapper";
      wrapper.title = "Click to inspect with interactive zoom";
      var badge = document.createElement("span");
      badge.className = "guide-interactive-badge";
      badge.innerHTML = '<svg width="15" height="15" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><circle cx="11" cy="11" r="8"></circle><line x1="21" y1="21" x2="16.65" y2="16.65"></line><line x1="11" y1="8" x2="11" y2="14"></line><line x1="8" y1="11" x2="14" y2="11"></line></svg> Interactive zoom';

      img.parentNode.insertBefore(wrapper, img);
      wrapper.appendChild(img);
      wrapper.appendChild(badge);
    });

    // 2. Create the lightbox inspector dialog
    var overlay = document.createElement("div");
    overlay.className = "guide-lightbox";
    overlay.setAttribute("role", "dialog");
    overlay.setAttribute("aria-modal", "true");
    overlay.setAttribute("aria-label", "Interactive diagram inspector");
    overlay.innerHTML =
      '<div class="guide-lightbox-content">' +
        '<div class="guide-viewport" title="Click to toggle overview / detail">' +
          '<img class="guide-zoom-img" src="" alt="" draggable="false" />' +
        '</div>' +
        '<div class="guide-toolbar">' +
          '<div class="guide-toolbar-info">' +
            '<span class="guide-zoom-badge">2.4×</span>' +
            '<span class="guide-toolbar-hint">Move mouse to inspect • Wheel to zoom</span>' +
          '</div>' +
          '<div class="guide-toolbar-actions">' +
            '<button type="button" class="guide-btn guide-btn-zoom-out" title="Zoom out (−)">−</button>' +
            '<button type="button" class="guide-btn guide-btn-zoom-in" title="Zoom in (+)">+</button>' +
            '<button type="button" class="guide-btn guide-btn-toggle" title="Toggle overview / detail">Overview (1×)</button>' +
            '<button type="button" class="guide-btn guide-btn-close" title="Close (Esc)">✕ Close</button>' +
          '</div>' +
        '</div>' +
      '</div>';
    document.body.appendChild(overlay);

    var viewport = overlay.querySelector(".guide-viewport");
    var zoomImg = overlay.querySelector(".guide-zoom-img");
    var badgeScale = overlay.querySelector(".guide-zoom-badge");
    var btnZoomOut = overlay.querySelector(".guide-btn-zoom-out");
    var btnZoomIn = overlay.querySelector(".guide-btn-zoom-in");
    var btnToggle = overlay.querySelector(".guide-btn-toggle");
    var btnClose = overlay.querySelector(".guide-btn-close");

    var currentScale = 2.4;
    var defaultZoom = 2.4;
    var minScale = 1.0;
    var maxScale = 3.8;

    function applyScale(scale) {
      currentScale = Math.max(minScale, Math.min(maxScale, Math.round(scale * 10) / 10));
      badgeScale.textContent = currentScale.toFixed(1) + "×";
      if (currentScale <= 1.05) {
        currentScale = 1.0;
        zoomImg.style.transform = "scale(1)";
        zoomImg.style.transformOrigin = "50% 50%";
        viewport.classList.add("is-overview");
        viewport.classList.remove("is-tracking");
        btnToggle.textContent = "Detail (2.4×)";
        btnToggle.classList.remove("is-active");
      } else {
        zoomImg.style.transform = "scale(" + currentScale + ")";
        viewport.classList.remove("is-overview");
        btnToggle.textContent = "Overview (1×)";
        btnToggle.classList.add("is-active");
      }
    }

    function updateOrigin(clientX, clientY) {
      if (currentScale <= 1.0) return;
      var rect = viewport.getBoundingClientRect();
      if (!rect.width || !rect.height) return;
      var fx = (clientX - rect.left) / rect.width;
      var fy = (clientY - rect.top) / rect.height;
      fx = Math.max(0, Math.min(1, fx));
      fy = Math.max(0, Math.min(1, fy));
      viewport.classList.add("is-tracking");
      zoomImg.style.transformOrigin = (fx * 100).toFixed(2) + "% " + (fy * 100).toFixed(2) + "%";
    }

    function openLightbox(src, alt, initialFx, initialFy) {
      zoomImg.src = src;
      zoomImg.alt = alt || "";
      overlay.classList.add("is-open");
      document.body.style.overflow = "hidden";
      applyScale(defaultZoom);
      var fx = (initialFx !== undefined) ? Math.max(0, Math.min(1, initialFx)) : 0.5;
      var fy = (initialFy !== undefined) ? Math.max(0, Math.min(1, initialFy)) : 0.25;
      zoomImg.style.transformOrigin = (fx * 100).toFixed(2) + "% " + (fy * 100).toFixed(2) + "%";
    }

    function closeLightbox() {
      overlay.classList.remove("is-open");
      document.body.style.overflow = "";
      viewport.classList.remove("is-tracking");
    }

    // Attach click to in-page guide wrappers
    document.querySelectorAll(".guide-interactive-wrapper").forEach(function (w) {
      w.addEventListener("click", function (e) {
        var img = w.querySelector("img");
        if (!img) return;
        var r = w.getBoundingClientRect();
        var fx = (e.clientX - r.left) / r.width;
        var fy = (e.clientY - r.top) / r.height;
        openLightbox(img.src, img.alt, fx, fy);
      });
    });

    // Viewport mousemove -> intelligent tracking
    viewport.addEventListener("mousemove", function (e) {
      updateOrigin(e.clientX, e.clientY);
    });

    // Viewport touchmove -> mobile panning
    viewport.addEventListener("touchmove", function (e) {
      if (e.touches && e.touches[0]) {
        updateOrigin(e.touches[0].clientX, e.touches[0].clientY);
      }
    }, { passive: true });

    // Wheel zoom
    viewport.addEventListener("wheel", function (e) {
      e.preventDefault();
      var delta = e.deltaY < 0 ? 0.3 : -0.3;
      applyScale(currentScale + delta);
      updateOrigin(e.clientX, e.clientY);
    }, { passive: false });

    // Click viewport to toggle between 1x overview and 2.4x detail
    viewport.addEventListener("click", function (e) {
      if (currentScale > 1.0) {
        applyScale(1.0);
      } else {
        applyScale(defaultZoom);
        updateOrigin(e.clientX, e.clientY);
      }
    });

    // Buttons
    btnZoomIn.addEventListener("click", function (e) {
      e.stopPropagation();
      applyScale(currentScale + 0.4);
    });
    btnZoomOut.addEventListener("click", function (e) {
      e.stopPropagation();
      applyScale(currentScale - 0.4);
    });
    btnToggle.addEventListener("click", function (e) {
      e.stopPropagation();
      if (currentScale > 1.0) {
        applyScale(1.0);
      } else {
        applyScale(defaultZoom);
      }
    });
    btnClose.addEventListener("click", function (e) {
      e.stopPropagation();
      closeLightbox();
    });

    // Backdrop click
    overlay.addEventListener("click", function (e) {
      if (e.target === overlay || e.target.classList.contains("guide-lightbox-content")) {
        closeLightbox();
      }
    });

    // Keyboard navigation
    window.addEventListener("keydown", function (e) {
      if (!overlay.classList.contains("is-open")) return;
      if (e.key === "Escape") closeLightbox();
      else if (e.key === "+" || e.key === "=") applyScale(currentScale + 0.3);
      else if (e.key === "-" || e.key === "_") applyScale(currentScale - 0.3);
      else if (e.key === "0") applyScale(1.0);
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
