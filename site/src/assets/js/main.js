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
