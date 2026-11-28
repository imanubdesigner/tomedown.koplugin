(function () {
  var prefersReducedMotion = !!(window.matchMedia && window.matchMedia("(prefers-reduced-motion: reduce)").matches);

  // 1. Reveal on scroll + editorial-highlight animation trigger
  var items = document.querySelectorAll("[data-reveal], mark.editorial-highlight");
  if ("IntersectionObserver" in window) {
    var io = new IntersectionObserver(function (entries) {
      entries.forEach(function (e) {
        if (e.isIntersecting) {
          e.target.classList.add("is-visible");
          io.unobserve(e.target);
        }
      });
    }, { threshold: 0.12 });
    items.forEach(function (el) { io.observe(el); });
  } else {
    items.forEach(function (el) { el.classList.add("is-visible"); });
  }

  // 2. Trigger doc-shot Ken Burns zoom only when scrolled into view
  var docShots = document.querySelectorAll(".doc-shot");
  if (docShots.length) {
    if ("IntersectionObserver" in window && !prefersReducedMotion) {
      var shotIo = new IntersectionObserver(function (entries) {
        entries.forEach(function (e) {
          if (e.isIntersecting) {
            e.target.classList.add("is-inview");
            shotIo.unobserve(e.target);
          }
        });
      }, { threshold: 0.2 });
      docShots.forEach(function (el) { shotIo.observe(el); });
    } else if (!prefersReducedMotion) {
      docShots.forEach(function (el) { el.classList.add("is-inview"); });
    }
  }

  // 3. Shared accessible tablist helper (roving tabindex, keyboard arrows, hidden="until-found" + beforematch)
  function wireTablist(tabsNodeList, panelsNodeList, onUserSelect) {
    var tabs = Array.prototype.slice.call(tabsNodeList);
    var panels = Array.prototype.slice.call(panelsNodeList);
    if (!tabs.length || tabs.length !== panels.length) return null;
    var activeIdx = 0;
    tabs.forEach(function (t, i) {
      if (t.classList.contains("is-active") || t.getAttribute("aria-selected") === "true") {
        activeIdx = i;
      }
    });

    function activate(next, moveFocus) {
      activeIdx = (next + tabs.length) % tabs.length;
      tabs.forEach(function (t, i) {
        var on = i === activeIdx;
        t.classList.toggle("is-active", on);
        t.setAttribute("aria-selected", on ? "true" : "false");
        t.setAttribute("tabindex", on ? "0" : "-1");
        if (on && moveFocus) t.focus();
      });
      panels.forEach(function (p, i) {
        var on = i === activeIdx;
        p.classList.toggle("is-active", on);
        if (on) {
          p.removeAttribute("hidden");
        } else {
          p.setAttribute("hidden", "until-found");
        }
        p.removeAttribute("tabindex");
      });
    }

    tabs.forEach(function (tab, i) {
      tab.addEventListener("click", function () {
        if (onUserSelect) onUserSelect(i);
        activate(i, false);
      });
      tab.addEventListener("keydown", function (e) {
        var next = null;
        if (e.key === "ArrowRight" || e.key === "ArrowDown") next = activeIdx + 1;
        else if (e.key === "ArrowLeft" || e.key === "ArrowUp") next = activeIdx - 1;
        else if (e.key === "Home") next = 0;
        else if (e.key === "End") next = tabs.length - 1;
        if (next !== null) {
          e.preventDefault();
          if (onUserSelect) onUserSelect(next);
          activate(next, true);
        }
      });
    });

    panels.forEach(function (panel, i) {
      panel.addEventListener("beforematch", function () {
        if (onUserSelect) onUserSelect(i);
        activate(i, false);
      });
    });

    activate(activeIdx, false);
    return {
      activate: activate,
      getIndex: function () { return activeIdx; }
    };
  }

  // Spotlight: fixed-geometry CSS Grid switcher with pre-decoded slides and calm auto-rotation
  document.querySelectorAll(".spotlight").forEach(function (spotlight) {
    var tabs = Array.prototype.slice.call(spotlight.querySelectorAll(".spotlight-tab"));
    var slides = Array.prototype.slice.call(spotlight.querySelectorAll(".spotlight-slide"));
    if (tabs.length < 2 || tabs.length !== slides.length) return;

    var activeIdx = 0;
    tabs.forEach(function (t, i) {
      if (t.classList.contains("is-active") || t.getAttribute("aria-selected") === "true") {
        activeIdx = i;
      }
    });

    var autoDelayMs = 5500;
    var autoTimer = null;
    var inViewport = true;
    var isHovered = false;
    var hasFocusInside = false;
    var predecoded = false;

    function predecodeSlides() {
      if (predecoded) return;
      predecoded = true;
      slides.forEach(function (slide) {
        var img = slide.querySelector("img");
        if (!img) return;
        img.loading = "eager";
        if (typeof img.decode === "function") {
          img.decode().catch(function () {});
        }
      });
    }

    function setSlide(nextIdx, moveFocus) {
      activeIdx = (nextIdx + tabs.length) % tabs.length;
      tabs.forEach(function (t, i) {
        var on = i === activeIdx;
        t.classList.toggle("is-active", on);
        t.setAttribute("aria-selected", on ? "true" : "false");
        t.setAttribute("tabindex", on ? "0" : "-1");
        if (on && moveFocus) t.focus();
      });
      slides.forEach(function (s, i) {
        var on = i === activeIdx;
        s.classList.toggle("is-active", on);
        s.removeAttribute("hidden");
        s.removeAttribute("tabindex");
        s.setAttribute("aria-hidden", on ? "false" : "true");
        if ("inert" in s) s.inert = !on;
      });
    }

    function stopAuto() {
      if (autoTimer) {
        clearInterval(autoTimer);
        autoTimer = null;
      }
    }

    function syncAuto() {
      stopAuto();
      if (prefersReducedMotion || !inViewport || isHovered || hasFocusInside || document.hidden) {
        return;
      }
      autoTimer = setInterval(function () {
        setSlide(activeIdx + 1, false);
      }, autoDelayMs);
    }

    tabs.forEach(function (tab, i) {
      tab.addEventListener("click", function () {
        predecodeSlides();
        setSlide(i, false);
        syncAuto();
      });
      tab.addEventListener("keydown", function (e) {
        var next = null;
        if (e.key === "ArrowRight" || e.key === "ArrowDown") next = activeIdx + 1;
        else if (e.key === "ArrowLeft" || e.key === "ArrowUp") next = activeIdx - 1;
        else if (e.key === "Home") next = 0;
        else if (e.key === "End") next = tabs.length - 1;
        if (next !== null) {
          e.preventDefault();
          predecodeSlides();
          setSlide(next, true);
          syncAuto();
        }
      });
    });

    spotlight.addEventListener("mouseenter", function () {
      isHovered = true;
      predecodeSlides();
      syncAuto();
    });
    spotlight.addEventListener("mouseleave", function () {
      isHovered = false;
      syncAuto();
    });
    spotlight.addEventListener("focusin", function () {
      hasFocusInside = true;
      predecodeSlides();
      syncAuto();
    });
    spotlight.addEventListener("focusout", function (e) {
      if (!spotlight.contains(e.relatedTarget)) {
        hasFocusInside = false;
        syncAuto();
      }
    });
    document.addEventListener("visibilitychange", syncAuto);

    if ("IntersectionObserver" in window) {
      inViewport = false;
      var preloadObserver = new IntersectionObserver(function (entries) {
        entries.forEach(function (entry) {
          if (entry.isIntersecting) {
            predecodeSlides();
            preloadObserver.disconnect();
          }
        });
      }, { rootMargin: "800px 0px" });
      preloadObserver.observe(spotlight);

      var viewObserver = new IntersectionObserver(function (entries) {
        entries.forEach(function (entry) {
          inViewport = entry.isIntersecting;
          syncAuto();
        });
      }, { threshold: 0.25 });
      viewObserver.observe(spotlight);
    } else {
      predecodeSlides();
    }

    setSlide(activeIdx, false);
    syncAuto();
  });

  // Homepage Tomedown 3.0 Interactive Live Note Specimen
  var workbench = document.getElementById("live-specimen");
  if (workbench) {
    var modeSwitch = workbench.querySelector(".spec-mode-switch");
    var modeBtns = Array.prototype.slice.call(workbench.querySelectorAll("[data-set-mode]"));
    var styleBtns = Array.prototype.slice.call(workbench.querySelectorAll("[data-set-style]"));
    var stage = workbench.querySelector("[data-spec-stage]");
    var elBadge = workbench.querySelector("[data-spec-badge]");
    var elDash = workbench.querySelector("[data-spec-dashboard]");
    var elSyn = workbench.querySelector("[data-spec-synopsis]");
    var elSpec = workbench.querySelector("[data-spec-special]");
    var elSpecLink = workbench.querySelector("[data-spec-special-link]");
    var elMeta = workbench.querySelector("[data-spec-meta]");
    var elDraw = workbench.querySelector("[data-spec-drawing]");

    var STYLE_META = {
      minimal:   { label: "Minimal",     syn: "§ ",       star: "★ " },
      emoji:     { label: "Emoji",       syn: "📖 ",      star: "⭐ " },
      badges:    { label: "Code badges", syn: "`[SYN]` ", star: "`[★]` " },
      editorial: { label: "Editorial",   syn: "",         star: "" }
    };

    var curMode = "obsidian";
    var curStyle = "minimal";
    var swapTimer = null;

    function applySpecimenContent() {
      var sm = STYLE_META[curStyle] || STYLE_META.minimal;
      var isObs = curMode === "obsidian";
      if (elBadge) {
        elBadge.textContent = (isObs ? "Obsidian" : "Standard .md") + " · " + sm.label;
      }
      if (elDash) {
        elDash.textContent = isObs ? "> [!book] Reading dashboard" : "> **Reading dashboard**";
      }
      if (elSyn) {
        elSyn.textContent = isObs
          ? "> [!abstract]- " + sm.syn + "Book synopsis"
          : "> **" + sm.syn + "Book synopsis**";
      }
      if (elSpec) {
        elSpec.textContent = isObs
          ? "> [!highlight]- " + sm.star + "Special highlights (1)"
          : "> **" + sm.star + "Special highlights (1)**";
      }
      if (elSpecLink) {
        elSpecLink.textContent = "";
        elSpecLink.appendChild(document.createTextNode("> - “There are mysteries which are better left unexamined…” — "));
        if (isObs) {
          var wl = document.createElement("span");
          wl.className = "spec-wikilink";
          wl.textContent = "[[#^hl-9f4c2a18|Chapter I · p. 15]]";
          elSpecLink.appendChild(wl);
        } else {
          var em = document.createElement("em");
          em.textContent = "Chapter I · p. 15";
          elSpecLink.appendChild(em);
        }
      }
      if (elMeta) {
        elMeta.textContent = "";
        elMeta.appendChild(document.createTextNode("— p. 15 · 16 Nov 2026"));
        if (isObs) {
          elMeta.appendChild(document.createTextNode(" "));
          var bid = document.createElement("span");
          bid.className = "spec-blockid";
          bid.textContent = "^hl-9f4c2a18";
          elMeta.appendChild(bid);
        }
      }
      if (elDraw) {
        elDraw.textContent = "";
        elDraw.appendChild(document.createTextNode("  - "));
        var dr = document.createElement("span");
        dr.className = "spec-wikilink";
        dr.textContent = isObs
          ? "![[drawings/The Three Impostors - p015.svg]]"
          : "![Sketch p. 15](drawings/The%20Three%20Impostors%20-%20p015.svg)";
        elDraw.appendChild(dr);
      }
    }

    function updateSpecimen(animate) {
      workbench.setAttribute("data-mode", curMode);
      workbench.setAttribute("data-style", curStyle);
      if (modeSwitch) modeSwitch.setAttribute("data-active", curMode);
      modeBtns.forEach(function (b) {
        b.setAttribute("aria-pressed", b.getAttribute("data-set-mode") === curMode ? "true" : "false");
      });
      styleBtns.forEach(function (b) {
        b.setAttribute("aria-pressed", b.getAttribute("data-set-style") === curStyle ? "true" : "false");
      });
      if (!animate || prefersReducedMotion || !stage) {
        applySpecimenContent();
        return;
      }
      if (swapTimer) clearTimeout(swapTimer);
      stage.classList.add("is-morphing");
      swapTimer = setTimeout(function () {
        applySpecimenContent();
        requestAnimationFrame(function () {
          stage.classList.remove("is-morphing");
        });
      }, 95);
    }

    modeBtns.forEach(function (btn) {
      btn.addEventListener("click", function () {
        var next = btn.getAttribute("data-set-mode");
        if (next && next !== curMode) {
          curMode = next;
          updateSpecimen(true);
        }
      });
    });

    styleBtns.forEach(function (btn) {
      btn.addEventListener("click", function () {
        var next = btn.getAttribute("data-set-style");
        if (next && next !== curStyle) {
          curStyle = next;
          updateSpecimen(true);
        }
      });
    });
  }

  // 6 Special Highlights Interactive Switcher
  var showcase = document.querySelector(".styles-showcase");
  if (showcase) {
    wireTablist(
      showcase.querySelectorAll(".style-tab"),
      showcase.querySelectorAll(".style-pane")
    );
  }

  // 4. Releases API with GitHub -> Codeberg fallback & editorial Markdown renderer
  var GH_API = "https://api.github.com/repos/imanubdesigner/tomedown.koplugin/releases";
  var CB_API = "https://codeberg.org/api/v1/repos/imanubdesigner/tomedown.koplugin/releases";

  function fetchJsonWithFallback(primaryUrl, fallbackUrl) {
    return fetch(primaryUrl).then(function (r) {
      return r.ok ? r.json() : Promise.reject(new Error("HTTP " + r.status));
    }).catch(function () {
      return fetch(fallbackUrl).then(function (r) {
        return r.ok ? r.json() : Promise.reject(new Error("HTTP " + r.status));
      });
    });
  }

  var version = document.getElementById("latest-version");
  var versionNum = document.getElementById("latest-version-num");
  if (version || versionNum) {
    fetchJsonWithFallback(GH_API + "/latest", CB_API + "/latest")
      .then(function (rel) {
        if (!rel || !rel.tag_name) return;
        var tag = rel.tag_name;
        var clean = tag.replace(/^v/i, "");
        if (version) version.textContent = /^v/i.test(tag) ? tag : "v" + tag;
        if (versionNum) versionNum.textContent = clean;
        var zip = (rel.assets || []).filter(function (a) { return /\.zip$/.test(a.name); })[0];
        var link = document.getElementById("latest-link");
        if (zip && link && zip.browser_download_url) link.href = zip.browser_download_url;
      }).catch(function () {});
  }

  function appendInlineMarkdown(parent, text) {
    var pattern = /(\*\*([^*]+)\*\*|`([^`]+)`|\[([^\]]+)\]\((https?:\/\/[^\s)]+)\))/g;
    var last = 0;
    var match;
    while ((match = pattern.exec(text)) !== null) {
      if (match.index > last) {
        parent.appendChild(document.createTextNode(text.slice(last, match.index)));
      }
      if (match[2] !== undefined) {
        var strong = document.createElement("strong");
        strong.textContent = match[2];
        parent.appendChild(strong);
      } else if (match[3] !== undefined) {
        var code = document.createElement("code");
        code.textContent = match[3];
        parent.appendChild(code);
      } else if (match[4] !== undefined && match[5] !== undefined) {
        var a = document.createElement("a");
        a.href = match[5];
        a.target = "_blank";
        a.rel = "noopener";
        a.textContent = match[4];
        parent.appendChild(a);
      }
      last = pattern.lastIndex;
    }
    if (last < text.length) {
      parent.appendChild(document.createTextNode(text.slice(last)));
    }
  }

  function renderReleaseBody(raw) {
    var frag = document.createDocumentFragment();
    var lines = String(raw || "").replace(/\r\n?/g, "\n").split("\n");
    var ul = null;
    var codeLines = null;

    function flushList() {
      if (ul) { frag.appendChild(ul); ul = null; }
    }
    function flushCode() {
      if (codeLines) {
        var pre = document.createElement("pre");
        var code = document.createElement("code");
        code.textContent = codeLines.join("\n");
        pre.appendChild(code);
        frag.appendChild(pre);
        codeLines = null;
      }
    }

    lines.forEach(function (line) {
      if (/^```/.test(line.trim())) {
        flushList();
        if (codeLines) flushCode();
        else codeLines = [];
        return;
      }
      if (codeLines !== null) {
        codeLines.push(line);
        return;
      }
      var trimmed = line.trim();
      if (!trimmed) {
        flushList();
        return;
      }
      var hMatch = trimmed.match(/^(#{1,4})\s+(.+)$/);
      if (hMatch) {
        flushList();
        var h = document.createElement(hMatch[1].length <= 2 ? "h3" : "h4");
        appendInlineMarkdown(h, hMatch[2]);
        frag.appendChild(h);
        return;
      }
      var liMatch = trimmed.match(/^[-*+]\s+(.+)$/);
      if (liMatch) {
        if (!ul) ul = document.createElement("ul");
        var li = document.createElement("li");
        appendInlineMarkdown(li, liMatch[1]);
        ul.appendChild(li);
        return;
      }
      flushList();
      var p = document.createElement("p");
      appendInlineMarkdown(p, trimmed);
      frag.appendChild(p);
    });
    flushList();
    flushCode();
    return frag;
  }

  var box = document.getElementById("releases");
  if (box) {
    fetchJsonWithFallback(GH_API + "?per_page=20", CB_API + "?limit=20")
      .then(function (list) {
        box.setAttribute("aria-busy", "false");
        if (!Array.isArray(list) || !list.length) {
          return Promise.reject(new Error("Empty release list"));
        }
        box.textContent = "";
        list.forEach(function (rel) {
          var article = document.createElement("article");
          article.className = "release-entry";
          var header = document.createElement("header");
          header.className = "release-entry-head";
          var h = document.createElement("h2");
          var a = document.createElement("a");
          a.href = rel.html_url || "https://github.com/imanubdesigner/tomedown.koplugin/releases";
          a.target = "_blank";
          a.rel = "noopener";
          a.textContent = rel.name || rel.tag_name;
          h.appendChild(a);
          header.appendChild(h);
          if (rel.published_at) {
            var dt = new Date(rel.published_at);
            if (!isNaN(dt.getTime())) {
              var timeEl = document.createElement("time");
              timeEl.className = "release-date";
              timeEl.setAttribute("datetime", dt.toISOString().slice(0, 10));
              timeEl.textContent = dt.toLocaleDateString("en-GB", { day: "numeric", month: "short", year: "numeric" });
              header.appendChild(timeEl);
            }
          }
          article.appendChild(header);
          var bodyDiv = document.createElement("div");
          bodyDiv.className = "release-entry-body";
          bodyDiv.appendChild(renderReleaseBody(rel.body || ""));
          article.appendChild(bodyDiv);
          box.appendChild(article);
        });
      }).catch(function () {
        box.setAttribute("aria-busy", "false");
        box.textContent = "";
        var notice = document.createElement("div");
        notice.className = "changelog-fallback";
        notice.setAttribute("role", "alert");
        var p = document.createElement("p");
        p.textContent = "Release notes could not be loaded right now (offline or rate-limited). Read the complete release history directly on ";
        var gh = document.createElement("a");
        gh.href = "https://github.com/imanubdesigner/tomedown.koplugin/releases";
        gh.textContent = "GitHub Releases";
        var cb = document.createElement("a");
        cb.href = "https://codeberg.org/imanubdesigner/tomedown.koplugin/releases";
        cb.textContent = "Codeberg Releases";
        p.appendChild(gh);
        p.appendChild(document.createTextNode(" or "));
        p.appendChild(cb);
        p.appendChild(document.createTextNode("."));
        notice.appendChild(p);
        box.appendChild(notice);
      });
  }

  // 5. Docs right-hand "On this page" scrollspy (throttled + aria-current)
  var toc = document.querySelector(".docs-toc");
  if (toc) {
    var tocLinks = Array.prototype.slice.call(toc.querySelectorAll("a[href^='#']"));
    var targets = tocLinks.map(function (a) {
      return document.getElementById(a.getAttribute("href").slice(1));
    });
    var spyTicking = false;
    var setActive = function () {
      var activeIdx = 0;
      for (var i = 0; i < targets.length; i++) {
        if (targets[i] && targets[i].getBoundingClientRect().top <= 130) {
          activeIdx = i;
        }
      }
      tocLinks.forEach(function (a, i) {
        var on = i === activeIdx;
        a.classList.toggle("is-active", on);
        if (on) a.setAttribute("aria-current", "true");
        else a.removeAttribute("aria-current");
      });
      spyTicking = false;
    };
    window.addEventListener("scroll", function () {
      if (!spyTicking) {
        spyTicking = true;
        window.requestAnimationFrame(setActive);
      }
    }, { passive: true });
    setActive();
  }

  // 6. Native <dialog> Lightbox Inspector for documentation screenshots (opens calm at 100%, gentle drag-to-pan when zoomed)
  var docShotFrames = document.querySelectorAll(".docs .prose .doc-shot-frame, .docs .prose .doc-specimen-viewport");
  if (docShotFrames.length) {
    var dialog = document.createElement("dialog");
    dialog.className = "guide-lightbox";
    dialog.setAttribute("closedby", "any");
    dialog.setAttribute("aria-label", "Screenshot preview");
    dialog.innerHTML =
      '<div class="guide-lightbox-content">' +
        '<div class="guide-viewport">' +
          '<img class="guide-zoom-img" src="" alt="" draggable="false" />' +
        '</div>' +
        '<div class="guide-toolbar">' +
          '<div class="guide-toolbar-info">' +
            '<span class="guide-zoom-badge" aria-live="polite">100%</span>' +
            '<span class="guide-toolbar-hint">Click image to zoom • Drag to pan when zoomed</span>' +
          '</div>' +
          '<div class="guide-toolbar-actions">' +
            '<button type="button" class="guide-btn guide-btn-zoom-out" aria-label="Zoom out">−</button>' +
            '<button type="button" class="guide-btn guide-btn-zoom-in" aria-label="Zoom in">+</button>' +
            '<button type="button" class="guide-btn guide-btn-toggle" aria-label="Toggle detail zoom">Zoom (160%)</button>' +
            '<button type="button" class="guide-btn guide-btn-close" aria-label="Close preview">✕ Close</button>' +
          '</div>' +
        '</div>' +
      '</div>';
    document.body.appendChild(dialog);

    var viewport = dialog.querySelector(".guide-viewport");
    var zoomImg = dialog.querySelector(".guide-zoom-img");
    var badgeScale = dialog.querySelector(".guide-zoom-badge");
    var btnZoomOut = dialog.querySelector(".guide-btn-zoom-out");
    var btnZoomIn = dialog.querySelector(".guide-btn-zoom-in");
    var btnToggle = dialog.querySelector(".guide-btn-toggle");
    var btnClose = dialog.querySelector(".guide-btn-close");
    var lastTrigger = null;

    var currentScale = 1.0;
    var detailZoom = 1.6;
    var minScale = 1.0;
    var maxScale = 2.2;
    var panX = 0;
    var panY = 0;
    var panPointerId = null;
    var panStartX = 0;
    var panStartY = 0;
    var panOriginX = 0;
    var panOriginY = 0;
    var didPanDrag = false;

    function isLightboxOpen() {
      return dialog.open || dialog.classList.contains("is-open");
    }

    function clampPan() {
      var w = zoomImg.offsetWidth || 0;
      var h = zoomImg.offsetHeight || 0;
      var maxX = Math.max(0, (w * (currentScale - 1)) / 2);
      var maxY = Math.max(0, (h * (currentScale - 1)) / 2);
      panX = Math.max(-maxX, Math.min(maxX, panX));
      panY = Math.max(-maxY, Math.min(maxY, panY));
    }

    function renderTransform() {
      clampPan();
      zoomImg.style.transform = "translate3d(" + panX.toFixed(1) + "px, " + panY.toFixed(1) + "px, 0) scale(" + currentScale.toFixed(2) + ")";
    }

    function applyScale(nextScale, focalClientX, focalClientY) {
      var prevScale = currentScale;
      var clamped = Math.max(minScale, Math.min(maxScale, Math.round(nextScale * 20) / 20));
      if (clamped <= 1.04) {
        currentScale = 1.0;
        panX = 0;
        panY = 0;
        viewport.classList.remove("is-zoomed", "is-panning");
        btnToggle.textContent = "Zoom (160%)";
        btnToggle.classList.remove("is-active");
      } else {
        currentScale = clamped;
        if (focalClientX !== undefined && focalClientY !== undefined) {
          var rect = viewport.getBoundingClientRect();
          if (rect.width && rect.height) {
            var dx = rect.left + rect.width / 2 - focalClientX;
            var dy = rect.top + rect.height / 2 - focalClientY;
            if (prevScale <= 1.04) {
              panX = dx * (currentScale - 1);
              panY = dy * (currentScale - 1);
            } else {
              var ratio = currentScale / prevScale;
              panX = panX * ratio;
              panY = panY * ratio;
            }
          }
        }
        viewport.classList.add("is-zoomed");
        btnToggle.textContent = "Fit (100%)";
        btnToggle.classList.add("is-active");
      }
      badgeScale.textContent = Math.round(currentScale * 100) + "%";
      renderTransform();
    }

    function openLightbox(src, alt, triggerEl) {
      lastTrigger = triggerEl || document.activeElement;
      zoomImg.src = src;
      zoomImg.alt = alt || "";
      applyScale(1.0);
      dialog.classList.add("is-open");
      if (typeof dialog.showModal === "function" && !dialog.open) {
        dialog.showModal();
      }
      btnClose.focus();
    }

    function closeLightbox() {
      dialog.classList.remove("is-open");
      viewport.classList.remove("is-zoomed", "is-panning");
      panPointerId = null;
      if (typeof dialog.close === "function" && dialog.open) {
        dialog.close();
      }
      if (lastTrigger && typeof lastTrigger.focus === "function") {
        lastTrigger.focus();
      }
    }

    dialog.addEventListener("close", function () {
      dialog.classList.remove("is-open");
      viewport.classList.remove("is-zoomed", "is-panning");
      panPointerId = null;
    });

    docShotFrames.forEach(function (w) {
      var img = w.querySelector("img");
      if (!w.hasAttribute("tabindex")) {
        w.setAttribute("tabindex", "0");
        w.setAttribute("role", "button");
        var label = img && img.alt ? ("Inspect screenshot: " + img.alt) : "Inspect screenshot";
        w.setAttribute("aria-label", label);
      }
      var trigger = function () {
        var targetImg = w.querySelector("img");
        if (!targetImg) return;
        openLightbox(targetImg.currentSrc || targetImg.src, targetImg.alt, w);
      };
      w.addEventListener("click", trigger);
      w.addEventListener("keydown", function (e) {
        if (e.key === "Enter" || e.key === " ") {
          e.preventDefault();
          trigger();
        }
      });
    });

    viewport.addEventListener("pointerdown", function (e) {
      if (e.button !== undefined && e.button !== 0) return;
      if (panPointerId !== null) return;
      panPointerId = e.pointerId;
      panStartX = e.clientX;
      panStartY = e.clientY;
      panOriginX = panX;
      panOriginY = panY;
      didPanDrag = false;
      if (currentScale > 1.0) {
        try { viewport.setPointerCapture(e.pointerId); } catch (_) {}
      }
    });

    viewport.addEventListener("pointermove", function (e) {
      if (e.pointerId !== panPointerId || currentScale <= 1.0) return;
      var dx = e.clientX - panStartX;
      var dy = e.clientY - panStartY;
      if (!didPanDrag && (Math.abs(dx) > 4 || Math.abs(dy) > 4)) {
        didPanDrag = true;
        viewport.classList.add("is-panning");
      }
      if (didPanDrag) {
        panX = panOriginX + dx;
        panY = panOriginY + dy;
        renderTransform();
      }
    });

    function endPan(e) {
      if (e.pointerId !== panPointerId) return;
      var wasDrag = didPanDrag;
      panPointerId = null;
      didPanDrag = false;
      viewport.classList.remove("is-panning");
      if (!wasDrag && e.type === "pointerup") {
        if (currentScale > 1.0) {
          applyScale(1.0);
        } else {
          applyScale(detailZoom, e.clientX, e.clientY);
        }
      }
    }

    viewport.addEventListener("pointerup", endPan);
    viewport.addEventListener("pointercancel", endPan);
    viewport.addEventListener("lostpointercapture", function () {
      panPointerId = null;
      didPanDrag = false;
      viewport.classList.remove("is-panning");
    });

    viewport.addEventListener("wheel", function (e) {
      e.preventDefault();
      var delta = e.deltaY < 0 ? 0.2 : -0.2;
      applyScale(currentScale + delta, e.clientX, e.clientY);
    }, { passive: false });

    btnZoomIn.addEventListener("click", function (e) {
      e.stopPropagation();
      applyScale(currentScale + 0.25);
    });
    btnZoomOut.addEventListener("click", function (e) {
      e.stopPropagation();
      applyScale(currentScale - 0.25);
    });
    btnToggle.addEventListener("click", function (e) {
      e.stopPropagation();
      applyScale(currentScale > 1.0 ? 1.0 : detailZoom);
    });
    btnClose.addEventListener("click", function (e) {
      e.stopPropagation();
      closeLightbox();
    });

    dialog.addEventListener("click", function (e) {
      if (e.target === dialog || e.target.classList.contains("guide-lightbox-content")) {
        closeLightbox();
      }
    });

    window.addEventListener("keydown", function (e) {
      if (!isLightboxOpen()) return;
      if (e.key === "+" || e.key === "=") applyScale(currentScale + 0.25);
      else if (e.key === "-" || e.key === "_") applyScale(currentScale - 0.25);
      else if (e.key === "0") applyScale(1.0);
    });
  }

  // 7. Documentation Hub Live Filter & Command Shortcut (Ctrl+K / Cmd+K)
  var searchInput = document.getElementById("hub-search-input");
  if (searchInput) {
    var chapters = document.querySelectorAll(".hub-chapter");
    var emptyMsg = document.getElementById("hub-empty");
    var statusMsg = document.getElementById("hub-search-status");
    var searchKbd = document.getElementById("hub-search-kbd");

    if (searchKbd && typeof navigator !== "undefined") {
      var isApple = /Mac|iPhone|iPad|iPod/i.test(navigator.platform || navigator.userAgent || "");
      searchKbd.textContent = isApple ? "⌘K" : "Ctrl K";
    }

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
      if (statusMsg) {
        statusMsg.textContent = q
          ? (totalVisible === 1 ? "1 chapter matches your search." : totalVisible + " chapters match your search.")
          : "";
      }
    };

    // typing or clicking here opens the full-text search (same modal as Ctrl+K)
    // with what was typed, so /docs/ never shows a weaker, titles-only search
    var openFullSearch = function () {
      var q = searchInput.value;
      searchInput.value = "";
      filterDocs();
      if (window.tomedownSearch) window.tomedownSearch.open(q);
    };
    searchInput.addEventListener("input", openFullSearch);
    searchInput.addEventListener("click", openFullSearch);

    window.addEventListener("keydown", function (e) {
      if (e.key === "Escape" && document.activeElement === searchInput && searchInput.value) {
        searchInput.value = "";
        filterDocs();
      }
    });
  }

  // 8. Docs mobile drawer, TOC dropdown & Site mobile menu drawer (with inert + focus management)
  var navToggle = document.getElementById("docs-nav-toggle");
  var navClose = document.getElementById("docs-nav-close");
  var docsNav = document.querySelector(".docs-nav");
  var backdrop = document.getElementById("docs-backdrop");
  var tocToggle = document.getElementById("docs-toc-toggle");
  var docsToc = document.querySelector(".docs-toc");
  var siteMenuToggle = document.getElementById("site-menu-toggle");
  var siteMenuClose = document.getElementById("site-menu-close");
  var siteMenuDrawer = document.getElementById("site-menu-drawer");
  var siteMenuBackdrop = document.getElementById("site-menu-backdrop");
  var mainEl = document.getElementById("main-content");
  var footerEl = document.querySelector(".site-footer");

  function setPageInert(inert) {
    [mainEl, footerEl].forEach(function (el) {
      if (!el) return;
      if (inert) el.setAttribute("inert", "");
      else el.removeAttribute("inert");
    });
  }

  function closeNavDrawer(restoreFocus) {
    var wasOpen = docsNav && docsNav.classList.contains("is-open");
    if (docsNav) docsNav.classList.remove("is-open");
    if (backdrop) backdrop.classList.remove("is-open");
    if (navToggle) navToggle.setAttribute("aria-expanded", "false");
    document.body.classList.remove("docs-drawer-open");
    if (wasOpen && restoreFocus && navToggle) navToggle.focus();
  }

  function openNavDrawer() {
    if (docsNav) docsNav.classList.add("is-open");
    if (backdrop) backdrop.classList.add("is-open");
    if (navToggle) navToggle.setAttribute("aria-expanded", "true");
    document.body.classList.add("docs-drawer-open");
    if (docsToc) docsToc.classList.remove("is-open");
    if (tocToggle) tocToggle.setAttribute("aria-expanded", "false");
    if (navClose) navClose.focus();
  }

  function closeSiteMenu(restoreFocus) {
    var wasOpen = siteMenuDrawer && siteMenuDrawer.classList.contains("is-open");
    if (siteMenuDrawer) {
      siteMenuDrawer.classList.remove("is-open");
      siteMenuDrawer.setAttribute("aria-hidden", "true");
      siteMenuDrawer.setAttribute("inert", "");
    }
    if (siteMenuBackdrop) {
      siteMenuBackdrop.classList.remove("is-open");
    }
    if (siteMenuToggle) {
      siteMenuToggle.setAttribute("aria-expanded", "false");
    }
    document.body.classList.remove("site-menu-open");
    setPageInert(false);
    if (wasOpen && restoreFocus && siteMenuToggle) siteMenuToggle.focus();
  }

  function openSiteMenu() {
    closeNavDrawer(false);
    if (siteMenuDrawer) {
      siteMenuDrawer.classList.add("is-open");
      siteMenuDrawer.setAttribute("aria-hidden", "false");
      siteMenuDrawer.removeAttribute("inert");
    }
    if (siteMenuBackdrop) {
      siteMenuBackdrop.classList.add("is-open");
    }
    if (siteMenuToggle) {
      siteMenuToggle.setAttribute("aria-expanded", "true");
    }
    document.body.classList.add("site-menu-open");
    setPageInert(true);
    if (siteMenuClose) siteMenuClose.focus();
  }

  if (navToggle) {
    navToggle.addEventListener("click", function () {
      if (docsNav && docsNav.classList.contains("is-open")) closeNavDrawer(true);
      else openNavDrawer();
    });
  }
  if (navClose) {
    navClose.addEventListener("click", function () { closeNavDrawer(true); });
  }
  if (backdrop) {
    backdrop.addEventListener("click", function () {
      closeNavDrawer(true);
      if (docsToc) docsToc.classList.remove("is-open");
      if (tocToggle) tocToggle.setAttribute("aria-expanded", "false");
    });
  }

  if (tocToggle && docsToc) {
    tocToggle.addEventListener("click", function () {
      var isOpen = docsToc.classList.toggle("is-open");
      tocToggle.setAttribute("aria-expanded", isOpen ? "true" : "false");
      tocToggle.classList.toggle("is-active", isOpen);
      if (isOpen) closeNavDrawer(false);
    });
    docsToc.querySelectorAll("a").forEach(function (a) {
      a.addEventListener("click", function () {
        docsToc.classList.remove("is-open");
        tocToggle.setAttribute("aria-expanded", "false");
        tocToggle.classList.remove("is-active");
      });
    });
  }

  if (siteMenuToggle) {
    siteMenuToggle.addEventListener("click", function () {
      if (siteMenuDrawer && siteMenuDrawer.classList.contains("is-open")) closeSiteMenu(true);
      else openSiteMenu();
    });
  }
  if (siteMenuClose) {
    siteMenuClose.addEventListener("click", function () { closeSiteMenu(true); });
  }
  if (siteMenuBackdrop) {
    siteMenuBackdrop.addEventListener("click", function () { closeSiteMenu(true); });
  }

  if (siteMenuDrawer) {
    siteMenuDrawer.querySelectorAll("a").forEach(function (link) {
      link.addEventListener("click", function (e) {
        var href = link.getAttribute("href") || "";
        closeSiteMenu(false);
        var hashIdx = href.indexOf("#");
        if (hashIdx !== -1) {
          var hash = href.slice(hashIdx + 1);
          var target = hash ? document.getElementById(hash) : null;
          if (target) {
            e.preventDefault();
            setTimeout(function () {
              target.scrollIntoView({ behavior: prefersReducedMotion ? "auto" : "smooth", block: "start" });
              try { history.pushState(null, "", "#" + hash); } catch (_) {}
            }, 30);
          }
        }
      });
    });
  }

  window.addEventListener("keydown", function (e) {
    if (e.key === "Escape") {
      closeNavDrawer(true);
      closeSiteMenu(true);
      if (docsToc && docsToc.classList.contains("is-open")) {
        docsToc.classList.remove("is-open");
        if (tocToggle) {
          tocToggle.setAttribute("aria-expanded", "false");
          tocToggle.classList.remove("is-active");
          tocToggle.focus();
        }
      }
    }
  });

  window.addEventListener("resize", function () {
    if (window.innerWidth >= 860) {
      closeNavDrawer(false);
      closeSiteMenu(false);
      if (docsToc) {
        docsToc.classList.remove("is-open");
        if (tocToggle) {
          tocToggle.setAttribute("aria-expanded", "false");
          tocToggle.classList.remove("is-active");
        }
      }
    }
  });

  // Auto-hide mobile bar on scroll down, reveal on reverse scroll
  var mobileBar = document.querySelector(".docs-mobile-bar");
  if (mobileBar) {
    var lastScrollY = Math.max(0, window.pageYOffset || document.documentElement.scrollTop || 0);
    var scrollThreshold = 8;
    var ticking = false;

    window.addEventListener("scroll", function () {
      if (!ticking) {
        window.requestAnimationFrame(function () {
          if (docsNav && docsNav.classList.contains("is-open")) {
            ticking = false;
            return;
          }
          var currentScrollY = Math.max(0, window.pageYOffset || document.documentElement.scrollTop || 0);
          var delta = currentScrollY - lastScrollY;
          if (currentScrollY <= 40) {
            mobileBar.classList.remove("is-hidden");
          } else if (delta > scrollThreshold && currentScrollY > 70) {
            if (!mobileBar.classList.contains("is-hidden")) {
              mobileBar.classList.add("is-hidden");
              if (docsToc && docsToc.classList.contains("is-open")) {
                docsToc.classList.remove("is-open");
                if (tocToggle) {
                  tocToggle.setAttribute("aria-expanded", "false");
                  tocToggle.classList.remove("is-active");
                }
              }
            }
          } else if (delta < -scrollThreshold) {
            mobileBar.classList.remove("is-hidden");
          }
          lastScrollY = currentScrollY;
          ticking = false;
        });
        ticking = true;
      }
    }, { passive: true });
  }

  // 9. System-aware Light / Dark theme toggle (syncs <meta name="color-scheme"> and clears override when matching OS)
  var themeBtns = document.querySelectorAll(".theme-toggle");
  var colorSchemeMeta = document.querySelector('meta[name="color-scheme"]');
  var darkMq = window.matchMedia ? window.matchMedia("(prefers-color-scheme: dark)") : null;

  function currentSystemTheme() {
    return (darkMq && darkMq.matches) ? "dark" : "light";
  }

  function currentActiveTheme() {
    return document.documentElement.dataset.theme || currentSystemTheme();
  }

  function syncThemeButtons() {
    var active = currentActiveTheme();
    var nextLabel = active === "dark" ? "Switch to light theme" : "Switch to dark theme";
    themeBtns.forEach(function (b) {
      b.setAttribute("aria-label", nextLabel);
      b.setAttribute("aria-pressed", active === "dark" ? "true" : "false");
    });
  }

  themeBtns.forEach(function (btn) {
    btn.addEventListener("click", function () {
      var root = document.documentElement;
      var sys = currentSystemTheme();
      var next = currentActiveTheme() === "dark" ? "light" : "dark";
      if (next === sys) {
        delete root.dataset.theme;
        if (colorSchemeMeta) colorSchemeMeta.content = "light dark";
        try { localStorage.removeItem("tomedown-theme"); } catch (e) {}
      } else {
        root.dataset.theme = next;
        if (colorSchemeMeta) colorSchemeMeta.content = next;
        try { localStorage.setItem("tomedown-theme", next); } catch (e) {}
      }
      syncThemeButtons();
    });
  });
  if (darkMq && typeof darkMq.addEventListener === "function") {
    darkMq.addEventListener("change", syncThemeButtons);
  }
  syncThemeButtons();

  // 10. Accessible Copy-to-Clipboard with live region announcement, timer reset, and error feedback
  var copyAnnouncer = document.createElement("span");
  copyAnnouncer.className = "sr-only";
  copyAnnouncer.setAttribute("role", "status");
  copyAnnouncer.setAttribute("aria-live", "polite");
  document.body.appendChild(copyAnnouncer);

  function announceCopy(msg) {
    copyAnnouncer.textContent = "";
    setTimeout(function () { copyAnnouncer.textContent = msg; }, 20);
  }

  function copyTextToClipboard(text, onDone, onError) {
    if (navigator.clipboard && navigator.clipboard.writeText) {
      navigator.clipboard.writeText(text).then(onDone).catch(function () {
        fallbackCopy(text, onDone, onError);
      });
    } else {
      fallbackCopy(text, onDone, onError);
    }
  }

  function fallbackCopy(text, onDone, onError) {
    try {
      var ta = document.createElement("textarea");
      ta.value = text;
      ta.style.position = "fixed";
      ta.style.opacity = "0";
      document.body.appendChild(ta);
      ta.select();
      var ok = document.execCommand("copy");
      document.body.removeChild(ta);
      if (ok) {
        if (onDone) onDone();
      } else if (onError) {
        onError();
      }
    } catch (e) {
      if (onError) onError();
    }
  }

  document.querySelectorAll(".prose pre, .install-card pre").forEach(function (pre) {
    if (pre.parentElement && pre.parentElement.classList.contains("code-block-wrapper")) return;
    var wrapper = document.createElement("div");
    wrapper.className = "code-block-wrapper";
    var btn = document.createElement("button");
    btn.type = "button";
    btn.className = "code-copy-btn";
    btn.setAttribute("aria-label", "Copy code to clipboard");
    btn.textContent = "Copy";
    pre.parentNode.insertBefore(wrapper, pre);
    wrapper.appendChild(pre);
    wrapper.appendChild(btn);
    var copyTimer = null;
    btn.addEventListener("click", function () {
      var codeEl = pre.querySelector("code") || pre;
      var text = (codeEl.textContent || "").trim();
      if (copyTimer) clearTimeout(copyTimer);
      copyTextToClipboard(text, function () {
        btn.classList.remove("is-error");
        btn.classList.add("is-copied");
        btn.textContent = "Copied!";
        announceCopy("Code copied to clipboard.");
        copyTimer = setTimeout(function () {
          btn.classList.remove("is-copied");
          btn.textContent = "Copy";
        }, 1800);
      }, function () {
        btn.classList.remove("is-copied");
        btn.classList.add("is-error");
        btn.textContent = "Failed";
        announceCopy("Could not copy code to clipboard.");
        copyTimer = setTimeout(function () {
          btn.classList.remove("is-error");
          btn.textContent = "Copy";
        }, 1800);
      });
    });
  });

  // Interactive Before/After Image Comparison Slider (Pointer Capture + Keyboard Range)
  document.querySelectorAll("[data-compare]").forEach(function (slider) {
    var range = slider.querySelector(".compare-range");
    if (!range) return;
    var activePointerId = null;
    var downX = 0;
    var isDragging = false;
    var clickTimer = null;

    function applySplit(val, syncInput) {
      var clamped = Math.max(0, Math.min(100, val));
      if (isNaN(clamped)) clamped = 50;
      slider.style.setProperty("--split", clamped.toFixed(2) + "%");
      slider.setAttribute("data-edge", clamped < 14 ? "start" : (clamped > 86 ? "end" : "mid"));
      if (syncInput) {
        range.value = clamped.toFixed(1);
      }
    }

    function splitFromClientX(clientX) {
      var rect = slider.getBoundingClientRect();
      if (!rect.width) return 50;
      return ((clientX - rect.left) / rect.width) * 100;
    }

    slider.addEventListener("pointerdown", function (e) {
      if (e.button !== undefined && e.button !== 0) return;
      if (activePointerId !== null) return;
      if (e.pointerType === "mouse") e.preventDefault();
      if (clickTimer) { clearTimeout(clickTimer); clickTimer = null; }
      activePointerId = e.pointerId;
      downX = e.clientX;
      isDragging = false;
      slider.classList.remove("is-dragging");
      slider.classList.add("is-clicking");
      try { slider.setPointerCapture(e.pointerId); } catch (_) {}
      applySplit(splitFromClientX(e.clientX), true);
    });

    slider.addEventListener("pointermove", function (e) {
      if (e.pointerId !== activePointerId) return;
      if (!isDragging && Math.abs(e.clientX - downX) > 3) {
        isDragging = true;
        slider.classList.remove("is-clicking");
        slider.classList.add("is-dragging");
      }
      if (isDragging) {
        applySplit(splitFromClientX(e.clientX), true);
      }
    });

    function finishPointer(e) {
      if (e.pointerId !== activePointerId) return;
      activePointerId = null;
      isDragging = false;
      slider.classList.remove("is-dragging");
      clickTimer = setTimeout(function () {
        slider.classList.remove("is-clicking");
        clickTimer = null;
      }, 180);
    }

    slider.addEventListener("pointerup", finishPointer);
    slider.addEventListener("pointercancel", finishPointer);
    slider.addEventListener("lostpointercapture", function () {
      activePointerId = null;
      isDragging = false;
      slider.classList.remove("is-dragging", "is-clicking");
    });

    range.addEventListener("input", function () {
      applySplit(Number(range.value), false);
    });
    range.addEventListener("change", function () {
      applySplit(Number(range.value), false);
    });
    applySplit(Number(range.value), false);
  });

  // Logo click: if already on homepage, smoothly scroll to top
  document.querySelectorAll("a.logo").forEach(function (logo) {
    logo.addEventListener("click", function () {
      var currentPath = window.location.pathname.replace(/(?:index\.html|\/)$/, "");
      var href = (logo.getAttribute("href") || "").split("#")[0].replace(/(?:index\.html|\/)$/, "");
      if (currentPath === href) {
        window.scrollTo({ top: 0, behavior: prefersReducedMotion ? "auto" : "smooth" });
      }
    });
  });

  document.querySelectorAll("[data-copy-hex]").forEach(function (card) {
    var hexTimer = null;
    card.addEventListener("click", function () {
      var hex = card.getAttribute("data-copy-hex");
      var label = card.querySelector("[data-hex-label]");
      if (!hex || !label) return;
      if (hexTimer) clearTimeout(hexTimer);
      copyTextToClipboard(hex, function () {
        label.classList.add("is-copied");
        label.textContent = "Copied " + hex;
        announceCopy("Copied color " + hex + " to clipboard.");
        hexTimer = setTimeout(function () {
          label.classList.remove("is-copied");
          label.textContent = label.getAttribute("data-hex-label") || hex;
        }, 1600);
      }, function () {
        label.textContent = "Copy failed";
        announceCopy("Could not copy color to clipboard.");
        hexTimer = setTimeout(function () {
          label.textContent = label.getAttribute("data-hex-label") || hex;
        }, 1600);
      });
    });
  });
  // 9. Site-wide documentation search (Ctrl/Cmd+K or "/"): full text of every
  // docs section from /search-index.json, built by site/build.py.
  (function () {
    var openers = document.querySelectorAll(".js-search-open");
    var base = (openers[0] && openers[0].getAttribute("data-base")) || "";
    var isApple = /Mac|iPhone|iPad|iPod/i.test(navigator.platform || navigator.userAgent || "");
    document.querySelectorAll(".site-search-kbd").forEach(function (k) {
      k.textContent = isApple ? "\u2318K" : "Ctrl K";
    });

    var index = null, loading = null, dialog, input, clearBtn, list, status, lastFocus, results = [], active = -1;

    function norm(str) {
      return String(str).normalize("NFD").replace(/[\u0300-\u036f]/g, "").toLowerCase();
    }
    function esc(str) {
      return str.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;");
    }
    function words(str) {
      return str.split(/[^a-z0-9]+/).filter(Boolean);
    }
    function within(a, b, max) {
      // Levenshtein distance <= max (rows kept tiny: words are short)
      if (Math.abs(a.length - b.length) > max) return false;
      var prev = [], cur, i, j;
      for (j = 0; j <= b.length; j++) prev[j] = j;
      for (i = 1; i <= a.length; i++) {
        cur = [i];
        for (j = 1; j <= b.length; j++) {
          cur[j] = Math.min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (a[i - 1] === b[j - 1] ? 0 : 1));
        }
        prev = cur;
      }
      return prev[b.length] <= max;
    }

    function load() {
      if (index) return Promise.resolve(index);
      if (!loading) {
        loading = fetch(base + "/search-index.json").then(function (r) { return r.json(); }).then(function (data) {
          data.forEach(function (e) {
            e.nh = norm(e.h); e.np = norm(e.p); e.nt = norm(e.t);
            e.hw = words(e.nh); e.tw = words(e.nt);
          });
          index = data;
          return data;
        });
      }
      return loading;
    }

    function tokenScore(tok, e) {
      var s = 0, i;
      for (i = 0; i < e.hw.length; i++) { if (e.hw[i] === tok) { s += 12; break; } if (e.hw[i].indexOf(tok) === 0) { s += 9; break; } }
      if (!s && e.nh.indexOf(tok) !== -1) s += 6;
      if (e.np.indexOf(tok) !== -1) s += 3;
      for (i = 0; i < e.tw.length; i++) { if (e.tw[i] === tok) { s += 4; break; } if (e.tw[i].indexOf(tok) === 0) { s += 3; break; } }
      if (!s && e.nt.indexOf(tok) !== -1) s += 1;
      if (!s && tok.length >= 4) {
        var max = tok.length >= 9 ? 2 : 1;
        var pool = e.hw.concat(e.tw);
        for (i = 0; i < pool.length; i++) {
          if (pool[i][0] === tok[0] && within(tok, pool[i], max)) { s += 2; break; }
        }
      }
      return s;
    }

    function run(query) {
      var q = norm(query).trim();
      var toks = words(q);
      if (!toks.length) {
        var seen = {};
        return index.filter(function (e) {
          if (e.c !== "Docs" || seen[e.p]) return false;
          seen[e.p] = true; return true;
        }).slice(0, 8).map(function (e) { return { e: e, snippet: e.t.slice(0, 140) }; });
      }
      var out = [];
      index.forEach(function (e) {
        var total = 0;
        for (var i = 0; i < toks.length; i++) {
          var s = tokenScore(toks[i], e);
          if (!s) return;
          total += s;
        }
        if (toks.length > 1) {
          if (e.nh.indexOf(q) !== -1) total += 10;
          else if (e.nt.indexOf(q) !== -1) total += 5;
        }
        if (e.c === "Docs") total += 1;
        out.push({ e: e, score: total, toks: toks });
      });
      out.sort(function (a, b) { return b.score - a.score; });
      return out.slice(0, 12);
    }

    function highlight(text, toks) {
      var n = norm(text);
      if (n.length !== text.length || !toks) return esc(text);
      var ranges = [];
      toks.forEach(function (t) {
        var from = 0, at;
        while ((at = n.indexOf(t, from)) !== -1) { ranges.push([at, at + t.length]); from = at + t.length; }
      });
      ranges.sort(function (a, b) { return a[0] - b[0]; });
      var html = "", pos = 0;
      ranges.forEach(function (r) {
        if (r[0] < pos) return;
        html += esc(text.slice(pos, r[0])) + "<mark>" + esc(text.slice(r[0], r[1])) + "</mark>";
        pos = r[1];
      });
      return html + esc(text.slice(pos));
    }

    function snippetFor(r) {
      var t = r.e.t;
      if (!r.toks) return t.slice(0, 140);
      var n = r.e.nt, at = -1;
      for (var i = 0; i < r.toks.length && at === -1; i++) at = n.indexOf(r.toks[i]);
      if (at === -1) return t.slice(0, 140);
      var start = Math.max(0, at - 50);
      var cut = t.slice(start, start + 150);
      return (start > 0 ? "\u2026" : "") + cut + (start + 150 < t.length ? "\u2026" : "");
    }

    function render(query) {
      results = run(query);
      active = results.length ? 0 : -1;
      var toks = words(norm(query));
      if (!results.length) {
        list.innerHTML = '<li class="search-empty" role="presentation">No results for \u201c' + esc(query) + '\u201d. Try fewer or different words.</li>';
        status.textContent = "No results.";
        return;
      }
      list.innerHTML = results.map(function (r, i) {
        var e = r.e, sn = r.snippet || snippetFor(r);
        var crumb = e.h === e.p ? esc(e.p) : esc(e.p) + " \u203a " + highlight(e.h, toks);
        var cat = e.c ? '<span class="search-cat">' + esc(e.c) + "</span>" : "";
        return '<li role="option" id="search-opt-' + i + '" data-i="' + i + '"' + (i === 0 ? ' aria-selected="true"' : "") + ">" +
          '<a href="' + base + e.u + '" tabindex="-1"><span class="search-head-row"><span class="search-crumb">' + crumb + "</span>" + cat + "</span>" +
          '<span class="search-snippet">' + highlight(sn, toks) + "</span></a></li>";
      }).join("");
      status.textContent = results.length + (results.length === 1 ? " result." : " results.");
      input.setAttribute("aria-activedescendant", "search-opt-0");
    }

    function setActive(i) {
      if (!results.length) return;
      active = (i + results.length) % results.length;
      list.querySelectorAll("[role=option]").forEach(function (li) {
        li.setAttribute("aria-selected", li.getAttribute("data-i") === String(active) ? "true" : "false");
      });
      var cur = document.getElementById("search-opt-" + active);
      input.setAttribute("aria-activedescendant", "search-opt-" + active);
      if (cur) cur.scrollIntoView({ block: "nearest" });
    }

    function syncClear() {
      if (clearBtn) clearBtn.hidden = !input.value.length;
    }

    function build() {
      dialog = document.createElement("div");
      dialog.className = "search-modal";
      dialog.hidden = true;
      dialog.innerHTML =
        '<div class="search-backdrop" data-close></div>' +
        '<div class="search-panel" role="dialog" aria-modal="true" aria-label="Search the documentation">' +
        '<div class="search-field"><svg width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><circle cx="11" cy="11" r="8"/><path d="m21 21-4.35-4.35"/></svg>' +
        '<input type="search" class="search-input" placeholder="Search docs, settings, changelog\u2026" autocomplete="off" spellcheck="false" role="combobox" aria-expanded="true" aria-controls="search-list" aria-label="Search the documentation">' +
        '<button type="button" class="search-clear" aria-label="Clear search" hidden><svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><line x1="18" y1="6" x2="6" y2="18"/><line x1="6" y1="6" x2="18" y2="18"/></svg></button>' +
        '<kbd>Esc</kbd></div>' +
        '<ul class="search-list" id="search-list" role="listbox" aria-label="Search results"></ul>' +
        '<p class="search-foot"><span><kbd>\u2191</kbd><kbd>\u2193</kbd> navigate</span><span><kbd>\u21b5</kbd> open</span><span><kbd>Esc</kbd> close</span></p>' +
        '<p class="sr-only" role="status" aria-live="polite" id="search-status"></p></div>';
      document.body.appendChild(dialog);
      input = dialog.querySelector(".search-input");
      clearBtn = dialog.querySelector(".search-clear");
      list = dialog.querySelector(".search-list");
      status = dialog.querySelector("#search-status");
      dialog.addEventListener("click", function (e) {
        if (e.target.hasAttribute("data-close")) close();
        var a = e.target.closest && e.target.closest("a");
        if (a) close();
      });
      clearBtn.addEventListener("click", function () {
        input.value = "";
        syncClear();
        if (index) render("");
        input.focus();
      });
      list.addEventListener("mousemove", function (e) {
        var li = e.target.closest && e.target.closest("[role=option]");
        if (li && li.getAttribute("data-i") !== String(active)) setActive(parseInt(li.getAttribute("data-i"), 10));
      });
      input.addEventListener("input", function () { syncClear(); if (index) render(input.value); });
      input.addEventListener("keydown", function (e) {
        if (e.key === "ArrowDown") { e.preventDefault(); setActive(active + 1); }
        else if (e.key === "ArrowUp") { e.preventDefault(); setActive(active - 1); }
        else if (e.key === "Enter" && results[active]) { e.preventDefault(); location.href = base + results[active].e.u; }
        else if (e.key === "Tab") { e.preventDefault(); }
      });
    }

    function open(initial) {
      if (!dialog) build();
      lastFocus = document.activeElement;
      dialog.hidden = false;
      document.body.style.overflow = "hidden";
      input.value = initial || "";
      syncClear();
      input.focus();
      var len = input.value.length;
      if (input.setSelectionRange) input.setSelectionRange(len, len);
      list.innerHTML = '<li class="search-empty" role="presentation">Loading\u2026</li>';
      load().then(function () { render(input.value); }).catch(function () {
        list.innerHTML = '<li class="search-empty" role="presentation">Search is unavailable right now.</li>';
      });
    }

    function close() {
      if (!dialog || dialog.hidden) return;
      dialog.hidden = true;
      document.body.style.overflow = "";
      if (lastFocus && lastFocus.focus) lastFocus.focus();
    }

    openers.forEach(function (b) { b.addEventListener("click", function () { open(); }); });
    window.tomedownSearch = { open: open, close: close };

    window.addEventListener("keydown", function (e) {
      var typing = /^(INPUT|TEXTAREA|SELECT)$/.test((document.activeElement || {}).tagName || "") ||
        (document.activeElement && document.activeElement.isContentEditable);
      if ((e.metaKey || e.ctrlKey) && e.key.toLowerCase() === "k") {
        e.preventDefault();
        if (dialog && !dialog.hidden) close(); else open();
      } else if (e.key === "/" && !typing && !e.metaKey && !e.ctrlKey && !e.altKey) {
        e.preventDefault();
        open();
      } else if (e.key === "Escape" && dialog && !dialog.hidden) {
        e.preventDefault();
        close();
      }
    });
  })();
})();
