import Foundation

/// Builds the HTML document the markdown preview loads: rendered markdown plus
/// the page script for links, heading anchors, find, broken images and the
/// image lightbox.
enum MarkdownPreviewPage {
    struct Colors {
        var background: String
        var foreground: String
        var muted: String
    }

    /// Values handed to the page script on load.
    struct Options: Encodable {
        var scrollY: Double = 0
        var fragment: String?
        var canGoBack = false
    }

    /// Name of the script message handler the page posts to.
    static let messageHandler = "boo"

    static func document(body: String, colors: Colors, options: Options) -> String {
        // Raw HTML in markdown stays allowed (READMEs use it), so a CSP keeps
        // every script except ours from running.
        let nonce = UUID().uuidString.replacingOccurrences(of: "-", with: "")
        let optionsJSON =
            (try? JSONEncoder().encode(options)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        let scheme = MarkdownAssetSchemeHandler.scheme
        return """
            <!DOCTYPE html>
            <html>
            <head>
            <meta charset="utf-8">
            <meta http-equiv="Content-Security-Policy" content="default-src 'none'; \
            img-src * data: blob: \(scheme):; media-src * data: \(scheme):; \
            style-src 'unsafe-inline'; font-src data:; script-src 'nonce-\(nonce)'">
            <style>
            :root {
                color-scheme: dark light;
                --bg: \(colors.background);
                --fg: \(colors.foreground);
                --muted: \(colors.muted);
            }
            \(css)
            </style>
            </head>
            <body>
            <article id="boo-content">
            \(body)
            </article>
            <script nonce="\(nonce)">
            window.BOO_OPTIONS = \(optionsJSON);
            \(script)
            </script>
            </body>
            </html>
            """
    }

    static func placeholder(colors: Colors) -> String {
        """
        <!DOCTYPE html>
        <html>
        <head>
        <style>
            body {
                display: flex; align-items: center; justify-content: center;
                height: 100vh; margin: 0;
                background: \(colors.background); color: \(colors.muted);
                font-family: -apple-system, sans-serif;
            }
        </style>
        </head>
        <body><p>No markdown file loaded</p></body>
        </html>
        """
    }

    // MARK: - CSS

    private static let css = """
        body {
            font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Helvetica, Arial, sans-serif;
            font-size: 14px;
            line-height: 1.6;
            margin: 0;
            background: var(--bg);
            color: var(--fg);
        }
        #boo-content { padding: 24px; max-width: 900px; margin: 0 auto; }
        h1, h2, h3, h4, h5, h6 {
            margin-top: 24px;
            margin-bottom: 16px;
            font-weight: 600;
            line-height: 1.25;
            position: relative;
            scroll-margin-top: 16px;
        }
        h1 { font-size: 2em; border-bottom: 1px solid var(--muted); padding-bottom: 0.3em; }
        h2 { font-size: 1.5em; border-bottom: 1px solid var(--muted); padding-bottom: 0.3em; }
        h3 { font-size: 1.25em; }
        .boo-anchor {
            position: absolute; left: -1.1em; padding-right: 0.3em;
            color: var(--muted); opacity: 0; font-weight: 400;
        }
        :is(h1, h2, h3, h4, h5, h6):hover .boo-anchor { opacity: 1; }
        .boo-anchor:hover { text-decoration: none; color: #58a6ff; }
        .boo-flash { animation: boo-flash 1.2s ease-out; }
        @keyframes boo-flash { from { background: rgba(88, 166, 255, 0.25); } to { background: transparent; } }
        p { margin-top: 0; margin-bottom: 16px; }
        a { color: #58a6ff; text-decoration: none; }
        a:hover { text-decoration: underline; }
        pre {
            background: rgba(128, 128, 128, 0.1);
            padding: 16px;
            border-radius: 6px;
            overflow-x: auto;
            font-size: 13px;
        }
        code { font-family: "SF Mono", Menlo, Monaco, Consolas, monospace; font-size: 0.9em; }
        :not(pre) > code {
            background: rgba(128, 128, 128, 0.15);
            padding: 0.2em 0.4em;
            border-radius: 4px;
        }
        blockquote { margin: 0; padding: 0 1em; border-left: 4px solid var(--muted); color: var(--muted); }
        ul, ol { padding-left: 2em; }
        li { margin-bottom: 4px; }
        hr { height: 1px; border: none; background: var(--muted); margin: 24px 0; }
        table { border-collapse: collapse; width: 100%; margin-bottom: 16px; }
        th, td { padding: 8px 12px; border: 1px solid var(--muted); }
        th { background: rgba(128, 128, 128, 0.1); }
        img { max-width: 100%; }
        #boo-content img.boo-zoomable { cursor: zoom-in; }
        .task-list-item { list-style-type: none; }
        .task-list-item input { margin-right: 8px; }

        .boo-img-broken {
            display: inline-flex; align-items: center; gap: 8px;
            max-width: 100%; padding: 8px 12px; margin: 2px 0;
            border: 1px dashed var(--muted); border-radius: 6px;
            color: var(--muted); font-size: 12px; cursor: pointer;
            vertical-align: middle; word-break: break-all;
        }
        .boo-img-broken b { color: var(--fg); font-weight: 500; }

        mark.boo-hit { background: rgba(255, 214, 10, 0.35); color: inherit; border-radius: 2px; }
        mark.boo-hit.boo-current { background: #ff9f0a; color: #000; }

        #boo-back {
            position: fixed; top: 10px; left: 10px; z-index: 10;
            display: none; padding: 4px 10px; border-radius: 14px;
            border: 1px solid rgba(128, 128, 128, 0.35);
            background: color-mix(in srgb, var(--bg) 85%, transparent);
            -webkit-backdrop-filter: blur(8px);
            color: var(--fg); font: 12px -apple-system, sans-serif; cursor: pointer;
        }
        #boo-back:hover { background: rgba(128, 128, 128, 0.2); }
        #boo-toast {
            position: fixed; bottom: 16px; left: 50%; transform: translateX(-50%);
            z-index: 30; padding: 6px 14px; border-radius: 8px;
            background: rgba(30, 30, 30, 0.92); color: #fff;
            font: 12px -apple-system, sans-serif; opacity: 0; transition: opacity .2s;
            pointer-events: none; max-width: 80vw; word-break: break-all;
        }
        #boo-toast.show { opacity: 1; }

        #boo-lightbox {
            position: fixed; inset: 0; z-index: 20; display: none;
            background: rgba(0, 0, 0, 0.88); overflow: hidden;
            font: 12px -apple-system, sans-serif; color: #eee;
            user-select: none; -webkit-user-select: none;
        }
        #boo-lightbox.open { display: block; }
        #boo-lb-stage { position: absolute; inset: 0; cursor: grab; }
        #boo-lb-stage.dragging { cursor: grabbing; }
        #boo-lb-img {
            position: absolute; left: 0; top: 0; transform-origin: 0 0;
            max-width: none;
            box-shadow: 0 4px 30px rgba(0, 0, 0, 0.5);
            background: repeating-conic-gradient(#808080 0 25%, #a0a0a0 0 50%) 0 0 / 16px 16px;
        }
        #boo-lb-img.pixelated { image-rendering: pixelated; }
        .boo-lb-bar {
            position: absolute; left: 50%; transform: translateX(-50%);
            display: flex; align-items: center; gap: 2px; padding: 4px;
            background: rgba(40, 40, 40, 0.9); border-radius: 10px;
            border: 1px solid rgba(255, 255, 255, 0.12);
            -webkit-backdrop-filter: blur(12px);
        }
        #boo-lb-tools { bottom: 16px; }
        #boo-lb-info {
            top: 12px; padding: 4px 12px; gap: 10px; max-width: 80vw;
            white-space: nowrap; overflow: hidden;
        }
        #boo-lb-caption { overflow: hidden; text-overflow: ellipsis; }
        .boo-lb-dim { color: #aaa; }
        .boo-lb-bar button {
            min-width: 28px; height: 26px; padding: 0 8px; border: 0; border-radius: 6px;
            background: transparent; color: #eee; font: 13px -apple-system, sans-serif; cursor: pointer;
        }
        .boo-lb-bar button:hover { background: rgba(255, 255, 255, 0.14); }
        .boo-lb-bar button:disabled { opacity: 0.35; cursor: default; background: transparent; }
        #boo-lb-zoom { min-width: 54px; font-variant-numeric: tabular-nums; }
        .boo-lb-sep { width: 1px; height: 16px; background: rgba(255, 255, 255, 0.18); margin: 0 4px; }
        .boo-lb-nav {
            position: absolute; top: 50%; transform: translateY(-50%);
            width: 40px; height: 64px; border: 0; border-radius: 8px;
            background: rgba(40, 40, 40, 0.6); color: #eee; font-size: 22px; cursor: pointer;
        }
        .boo-lb-nav:hover { background: rgba(70, 70, 70, 0.85); }
        #boo-lb-prev { left: 12px; }
        #boo-lb-next { right: 12px; }
        #boo-lb-close { top: 10px; right: 12px; transform: none; width: 32px; height: 32px; font-size: 16px; }
        """

    // MARK: - Script

    private static let script = #"""
        (() => {
        const opts = window.BOO_OPTIONS || {};
        const content = document.getElementById('boo-content');
        const post = (msg) => {
            try { window.webkit.messageHandlers.boo.postMessage(msg); } catch (_) {}
        };

        // ---- Toast -------------------------------------------------------
        const toast = document.createElement('div');
        toast.id = 'boo-toast';
        document.body.appendChild(toast);
        let toastTimer = 0;
        window.booToast = (text) => {
            toast.textContent = text;
            toast.classList.add('show');
            clearTimeout(toastTimer);
            toastTimer = setTimeout(() => toast.classList.remove('show'), 2400);
        };

        // ---- Heading anchors (GitHub-style slugs) ------------------------
        const slugCounts = {};
        const slugify = (text) => text.trim().toLowerCase()
            .replace(/[^\p{L}\p{N}\s_-]/gu, '')
            .replace(/\s/g, '-');
        content.querySelectorAll('h1, h2, h3, h4, h5, h6').forEach((h) => {
            let id = h.id;
            if (!id) {
                const base = slugify(h.textContent) || 'section';
                const n = slugCounts[base] || 0;
                slugCounts[base] = n + 1;
                id = n ? `${base}-${n}` : base;
                h.id = id;
            }
            const a = document.createElement('a');
            a.className = 'boo-anchor';
            a.href = '#' + encodeURIComponent(id);
            a.textContent = '#';
            a.setAttribute('aria-hidden', 'true');
            h.prepend(a);
        });

        const findTarget = (fragment) => {
            if (!fragment) return null;
            let decoded = fragment;
            try { decoded = decodeURIComponent(fragment); } catch (_) {}
            return document.getElementById(decoded)
                || document.getElementsByName(decoded)[0]
                || document.getElementById(decoded.toLowerCase())
                || document.getElementById(slugify(decoded));
        };
        const flash = (el) => {
            el.classList.remove('boo-flash');
            void el.offsetWidth;
            el.classList.add('boo-flash');
        };
        window.booScrollToFragment = (fragment) => {
            if (!fragment) { window.scrollTo(0, 0); return; }
            const el = findTarget(fragment);
            if (!el) { booToast('No section “' + fragment + '” in this file'); return; }
            el.closest('details')?.setAttribute('open', '');
            el.scrollIntoView({ block: 'start' });
            flash(el);
        };

        // ---- Links -------------------------------------------------------
        document.addEventListener('click', (e) => {
            if (e.defaultPrevented || e.button !== 0) return;
            const a = e.target.closest('a[href]');
            if (!a || a.closest('#boo-lightbox')) return;
            const raw = a.getAttribute('href');
            e.preventDefault();
            if (!raw || raw.startsWith('javascript:')) return;
            if (raw.startsWith('#')) {
                booScrollToFragment(raw.slice(1));
                return;
            }
            post({ type: 'link', href: a.href });
        }, true);

        // ---- Back pill ---------------------------------------------------
        const back = document.createElement('button');
        back.id = 'boo-back';
        back.textContent = '‹ Back';
        back.title = 'Back (⌘←)';
        back.addEventListener('click', () => post({ type: 'back' }));
        document.body.appendChild(back);
        if (opts.canGoBack) back.style.display = 'block';

        // ---- Broken images -----------------------------------------------
        const shortSrc = (img) => {
            const src = img.getAttribute('src') || '';
            return src.length > 120 ? '…' + src.slice(-117) : src;
        };
        const markBroken = (img) => {
            if (!img.isConnected || img.dataset.booBroken) return;
            img.dataset.booBroken = '1';
            const box = document.createElement('span');
            box.className = 'boo-img-broken';
            box.title = 'Click to retry';
            const alt = img.getAttribute('alt');
            box.innerHTML = '<span>🖼︎</span><span></span>';
            const label = box.lastChild;
            if (alt) {
                const b = document.createElement('b');
                b.textContent = alt;
                label.append(b, document.createElement('br'));
            }
            label.append('Image failed to load: ' + shortSrc(img));
            box.addEventListener('click', (e) => {
                e.preventDefault();
                e.stopPropagation();
                delete img.dataset.booBroken;
                const src = img.src;
                img.src = '';
                img.src = src;
                box.replaceWith(img);
            });
            img.replaceWith(box);
        };
        const watchImage = (img) => {
            // The page origin may not read file: URLs; route them through our scheme.
            const raw = img.getAttribute('src') || '';
            if (raw.startsWith('file://')) img.src = '\#(MarkdownAssetSchemeHandler.scheme)://local' + raw.slice(7);
            if (!img.closest('a')) img.classList.add('boo-zoomable');
            img.addEventListener('error', () => markBroken(img));
            if (img.complete && img.naturalWidth === 0 && img.getAttribute('src')) markBroken(img);
        };
        content.querySelectorAll('img').forEach(watchImage);

        // ---- Find --------------------------------------------------------
        let hits = [];
        let hitIndex = -1;
        const clearHits = () => {
            const parents = new Set();
            for (const m of hits) {
                const parent = m.parentNode;
                if (!parent) continue;
                parent.replaceChild(document.createTextNode(m.textContent), m);
                parents.add(parent);
            }
            parents.forEach((p) => p.normalize());
            hits = [];
            hitIndex = -1;
        };
        const selectHit = (i) => {
            hits[hitIndex]?.classList.remove('boo-current');
            hitIndex = i;
            const m = hits[i];
            if (!m) return;
            m.classList.add('boo-current');
            m.closest('details')?.setAttribute('open', '');
            m.scrollIntoView({ block: 'center', inline: 'nearest' });
        };
        window.booFind = (needle) => {
            clearHits();
            if (!needle) return [-1, -1];
            const q = needle.toLowerCase();
            // Elements are walked only to skip whole script/style/anchor subtrees.
            const walker = document.createTreeWalker(content, NodeFilter.SHOW_ELEMENT | NodeFilter.SHOW_TEXT, {
                acceptNode: (n) => n.nodeType === Node.TEXT_NODE ? NodeFilter.FILTER_ACCEPT
                    : n.matches('script, style, .boo-anchor') ? NodeFilter.FILTER_REJECT : NodeFilter.FILTER_SKIP,
            });
            const nodes = [];
            while (walker.nextNode()) {
                const lower = walker.currentNode.nodeValue.toLowerCase();
                if (lower.includes(q)) nodes.push([walker.currentNode, lower]);
            }
            for (const [node, lower] of nodes) {
                const text = node.nodeValue;
                const frag = document.createDocumentFragment();
                let last = 0;
                let i = lower.indexOf(q);
                while (i !== -1) {
                    if (i > last) frag.append(text.slice(last, i));
                    const m = document.createElement('mark');
                    m.className = 'boo-hit';
                    m.textContent = text.slice(i, i + q.length);
                    frag.append(m);
                    hits.push(m);
                    last = i + q.length;
                    i = lower.indexOf(q, last);
                }
                if (last < text.length) frag.append(text.slice(last));
                node.parentNode.replaceChild(frag, node);
            }
            if (!hits.length) return [-1, 0];
            // Start at the first match at or below the current scroll position.
            const top = window.scrollY;
            let start = hits.findIndex((m) => m.getBoundingClientRect().top + window.scrollY >= top);
            selectHit(start < 0 ? 0 : start);
            return [hitIndex, hits.length];
        };
        window.booFindStep = (forward) => {
            if (!hits.length) return [-1, 0];
            const n = hits.length;
            selectHit(forward ? (hitIndex + 1) % n : (hitIndex - 1 + n) % n);
            return [hitIndex, n];
        };
        window.booFindClear = clearHits;

        // ---- Scroll position ---------------------------------------------
        let scrollTimer = 0;
        window.addEventListener('scroll', () => {
            clearTimeout(scrollTimer);
            scrollTimer = setTimeout(() => post({ type: 'scroll', y: window.scrollY }), 200);
        }, { passive: true });

        // ---- Lightbox ----------------------------------------------------
        const lb = document.createElement('div');
        lb.id = 'boo-lightbox';
        lb.innerHTML = `
            <div id="boo-lb-stage"><img id="boo-lb-img" alt=""></div>
            <div id="boo-lb-info" class="boo-lb-bar">
                <span id="boo-lb-caption"></span>
                <span id="boo-lb-dims" class="boo-lb-dim"></span>
                <span id="boo-lb-count" class="boo-lb-dim"></span>
            </div>
            <button id="boo-lb-prev" class="boo-lb-nav" data-act="prev" title="Previous image (←)">‹</button>
            <button id="boo-lb-next" class="boo-lb-nav" data-act="next" title="Next image (→)">›</button>
            <div id="boo-lb-tools" class="boo-lb-bar">
                <button data-act="out" title="Zoom out (−)">−</button>
                <button id="boo-lb-zoom" data-act="actual" title="Actual size (1)">100%</button>
                <button data-act="in" title="Zoom in (+)">+</button>
                <span class="boo-lb-sep"></span>
                <button data-act="fit" title="Fit to window (0)">Fit</button>
                <button data-act="actual" title="Actual size (1)">1:1</button>
                <button data-act="rotate" title="Rotate (R)">⟳</button>
                <span class="boo-lb-sep"></span>
                <button data-act="copy" title="Copy image address">Copy Path</button>
                <button data-act="reveal" title="Show in Finder">Reveal</button>
                <button data-act="open" title="Open in default app">Open</button>
            </div>
            <button id="boo-lb-close" class="boo-lb-nav" data-act="close" title="Close (Esc)">✕</button>`;
        document.body.appendChild(lb);
        const stage = lb.querySelector('#boo-lb-stage');
        const lbImg = lb.querySelector('#boo-lb-img');
        const $ = (id) => lb.querySelector(id);
        const zoomLabel = $('#boo-lb-zoom');
        const view = { list: [], index: 0, s: 1, x: 0, y: 0, rot: 0, fit: true };

        const natural = () => {
            const w = lbImg.naturalWidth || 1, h = lbImg.naturalHeight || 1;
            return view.rot % 180 ? { w: h, h: w } : { w, h };
        };
        const fitScale = () => {
            const { w, h } = natural();
            return Math.min((innerWidth - 120) / w, (innerHeight - 120) / h, 1);
        };
        const apply = () => {
            const { w, h } = natural();
            const nw = lbImg.naturalWidth, nh = lbImg.naturalHeight;
            // (x, y) is the top-left of the (rotated) box; rotate about the image center.
            lbImg.style.transform =
                `translate(${view.x}px, ${view.y}px) scale(${view.s})` +
                ` translate(${w / 2}px, ${h / 2}px) rotate(${view.rot}deg)` +
                ` translate(${-nw / 2}px, ${-nh / 2}px)`;
            lbImg.classList.toggle('pixelated', view.s >= 3);
            const pct = Math.round(view.s * 100) + '%';
            if (zoomLabel.textContent !== pct) zoomLabel.textContent = pct;
        };
        const center = () => {
            const { w, h } = natural();
            view.x = (innerWidth - w * view.s) / 2;
            view.y = (innerHeight - h * view.s) / 2;
        };
        const fit = () => { view.s = fitScale(); view.fit = true; center(); apply(); };
        const zoomAt = (factor, cx = innerWidth / 2, cy = innerHeight / 2) => {
            const ns = Math.min(Math.max(view.s * factor, 0.02), 40);
            view.x = cx - (cx - view.x) * (ns / view.s);
            view.y = cy - (cy - view.y) * (ns / view.s);
            view.s = ns;
            view.fit = false;
            apply();
        };
        const actual = (cx, cy) => zoomAt(1 / view.s, cx, cy);

        const show = (i) => {
            const n = view.list.length;
            if (!n) return;
            view.index = (i + n) % n;
            const src = view.list[view.index];
            view.rot = 0;
            lbImg.style.visibility = 'hidden';
            lbImg.onload = () => {
                lbImg.style.visibility = 'visible';
                $('#boo-lb-dims').textContent = `${lbImg.naturalWidth} × ${lbImg.naturalHeight}`;
                fit();
            };
            lbImg.onerror = () => booToast('Image failed to load');
            lbImg.src = src.src;
            $('#boo-lb-caption').textContent = src.alt || decodeURIComponent(src.src.split('/').pop() || '');
            $('#boo-lb-count').textContent = n > 1 ? `${view.index + 1} / ${n}` : '';
            $('#boo-lb-prev').style.display = n > 1 ? '' : 'none';
            $('#boo-lb-next').style.display = n > 1 ? '' : 'none';
            const local = src.src.startsWith('\#(MarkdownAssetSchemeHandler.scheme):');
            lb.querySelector('[data-act="reveal"]').disabled = !local;
        };
        const open = (img) => {
            view.list = Array.from(content.querySelectorAll('img.boo-zoomable'))
                .filter((i) => i.naturalWidth > 0)
                .map((i) => ({ src: i.currentSrc || i.src, alt: i.getAttribute('alt') || i.title || '', el: i }));
            const idx = view.list.findIndex((e) => e.el === img);
            if (idx < 0) return;
            lb.classList.add('open');
            show(idx);
        };
        const close = () => {
            lb.classList.remove('open');
            lbImg.removeAttribute('src');
        };

        content.addEventListener('click', (e) => {
            const img = e.target.closest('img.boo-zoomable');
            if (!img || img.naturalWidth === 0) return;
            e.preventDefault();
            open(img);
        });

        const src = () => view.list[view.index].src;
        const acts = {
            in: () => zoomAt(1.25),
            out: () => zoomAt(0.8),
            fit,
            actual: () => actual(),
            rotate: () => { view.rot = (view.rot + 90) % 360; fit(); },
            prev: () => show(view.index - 1),
            next: () => show(view.index + 1),
            close,
            open: () => post({ type: 'openImage', src: src() }),
            reveal: () => post({ type: 'revealImage', src: src() }),
            copy: () => { post({ type: 'copyImagePath', src: src() }); booToast('Copied'); },
        };
        const keys = {
            Escape: 'close', ArrowLeft: 'prev', ArrowRight: 'next',
            '+': 'in', '=': 'in', '-': 'out', '0': 'fit', '1': 'actual', r: 'rotate',
        };

        lb.addEventListener('click', (e) => {
            const act = acts[e.target.closest('button')?.dataset.act];
            if (!act) return;
            e.stopPropagation();
            act();
        });

        // Wheel zooms around the cursor; a trackpad pinch arrives as ctrl+wheel.
        stage.addEventListener('wheel', (e) => {
            e.preventDefault();
            if (!e.ctrlKey && Math.abs(e.deltaX) > Math.abs(e.deltaY) && e.deltaMode === 0) {
                view.x -= e.deltaX; view.y -= e.deltaY; view.fit = false; apply();
                return;
            }
            const k = e.ctrlKey ? 0.01 : 0.002;
            zoomAt(Math.exp(-e.deltaY * k), e.clientX, e.clientY);
        }, { passive: false });
        let gestureScale = 1;
        stage.addEventListener('gesturestart', (e) => { e.preventDefault(); gestureScale = 1; });
        stage.addEventListener('gesturechange', (e) => {
            e.preventDefault();
            zoomAt(e.scale / gestureScale, e.clientX, e.clientY);
            gestureScale = e.scale;
        });

        let drag = null;
        stage.addEventListener('pointerdown', (e) => {
            if (e.button !== 0) return;
            drag = { x: e.clientX, y: e.clientY, vx: view.x, vy: view.y, moved: false };
            stage.setPointerCapture(e.pointerId);
            stage.classList.add('dragging');
        });
        stage.addEventListener('pointermove', (e) => {
            if (!drag) return;
            const dx = e.clientX - drag.x, dy = e.clientY - drag.y;
            if (Math.abs(dx) + Math.abs(dy) > 3) drag.moved = true;
            view.x = drag.vx + dx; view.y = drag.vy + dy; view.fit = false;
            apply();
        });
        stage.addEventListener('pointerup', (e) => {
            stage.classList.remove('dragging');
            const d = drag;
            drag = null;
            // A plain click on the backdrop (not the image) closes the viewer.
            if (d && !d.moved && e.target === stage) close();
        });
        stage.addEventListener('dblclick', (e) => {
            // Fit ⇄ actual size (2× when fit already is 1:1).
            if (!view.fit) fit();
            else if (Math.abs(view.s - 1) > 0.01) actual(e.clientX, e.clientY);
            else zoomAt(2, e.clientX, e.clientY);
        });
        window.addEventListener('resize', () => { if (lb.classList.contains('open') && view.fit) fit(); });

        // ---- Keyboard ----------------------------------------------------
        document.addEventListener('keydown', (e) => {
            if (lb.classList.contains('open')) {
                if (e.metaKey) return;
                const act = acts[keys[e.key]];
                if (act) { e.preventDefault(); act(); }
                return;
            }
            if (e.metaKey && (e.key === 'ArrowLeft' || e.key === '[')) {
                if (opts.canGoBack) { e.preventDefault(); post({ type: 'back' }); }
            }
        });

        // ---- Initial position --------------------------------------------
        // Restore now, and again once images have loaded and shifted the
        // layout, unless the user scrolled in between.
        const restore = () => {
            if (opts.fragment) booScrollToFragment(opts.fragment);
            else if (opts.scrollY) window.scrollTo(0, opts.scrollY);
            return window.scrollY;
        };
        if (opts.fragment || opts.scrollY) {
            const restoredY = restore();
            window.addEventListener('load', () => {
                if (Math.abs(window.scrollY - restoredY) < 2) restore();
            }, { once: true });
        }
        })();
        """#
}
