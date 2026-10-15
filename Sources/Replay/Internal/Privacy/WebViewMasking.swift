#if canImport(UIKit) && canImport(WebKit)
import UIKit
import WebKit

/// Masks password inputs inside `WKWebView`s, as the reference tracker does
/// by default in native apps.
///
/// A web page's inputs are not UIKit views, so the frame walk can't see
/// them. Before each native capture the screenshotter asks every web view
/// drawn in the previous frame where its password inputs are (a short
/// script, run in an isolated content world so the page can't tamper with
/// it), waits for the answers, then captures and masks those rects solid.
///
/// The page measures its inputs a few milliseconds before the capture, and
/// the web process can lag the scroll view, so each input is placed against
/// the scroll position at capture time (see ``place(_:in:asked:)``).
///
/// Fail closed: a web view with no answer for the frame — the first frame
/// it appears in, a script error, or no answer within ``timeout`` — is masked
/// whole for that frame, and so is one whose answer can't be placed (zoomed
/// or resized since, one of the page's own scrollers moved, or a masked
/// input is being animated).
///
/// Nothing is installed in the page: no user scripts, no message handlers,
/// and the host's `WKUserContentController` is never touched.
///
/// Main thread only, like the capture that drives it.
final class WebViewMasking {
    /// How long a capture waits for the web views to answer.
    static let timeout: TimeInterval = 0.1

    /// Web views drawn in the last frame: the ones the next frame asks.
    private var seen: [WeakWebView] = []
    /// Web views drawn in the frame being captured.
    private var seenThisFrame: [WeakWebView] = []
    /// Answers for the frame about to be captured, with each web view's
    /// geometry when it was asked.
    private var answers: [(web: WeakWebView, answer: Answer, asked: Geometry)] = []
    /// Where each web view asked last time was scrolled to then.
    private var lastOffsets: [(web: WeakWebView, offset: CGPoint)] = []
    /// Bumped by each lookup, so a late answer can't land in a later frame.
    private var generation = 0

    private struct WeakWebView {
        weak var view: WKWebView?
    }

    /// What a page said about its masked inputs, in points (CSS px × the
    /// page's scale × the web view's page zoom).
    struct Answer {
        /// The masked inputs, from the top-left of the visual viewport the
        /// page measured them in.
        let rects: [CGRect]
        /// That viewport's top-left in the scroll view's content.
        let origin: CGPoint
        /// A masked input sits in an element whose position or size is being
        /// animated, so it is moving while the frame is taken.
        let moving: Bool
    }

    /// How a web view was zoomed, sized and scrolled when it was asked.
    struct Geometry {
        let zoomScale: CGFloat
        let pageZoom: CGFloat
        let size: CGSize
        /// The scroll view's offset.
        let offset: CGPoint
        /// The scroll view was where it was at the previous lookup (a capture
        /// interval earlier) and isn't moving, so the page has caught up with
        /// it.
        let settled: Bool
        /// The page's own scrollers (overflow areas, frames) and where they
        /// were scrolled to.
        let scrollers: [Scroller]

        struct Scroller {
            weak var view: UIScrollView?
            let offset: CGPoint

            /// Still there, not moved, and not moving.
            var isStill: Bool {
                guard let v = view else { return false }
                return v.contentOffset == offset && !v.isDragging && !v.isDecelerating && !v.isZooming
            }
        }

        /// `previousOffset`: the scroll view's offset at the previous lookup.
        init(of web: WKWebView, previousOffset: CGPoint?) {
            let sv = web.scrollView
            zoomScale = sv.zoomScale
            pageZoom = web.pageZoom
            size = web.bounds.size
            offset = sv.contentOffset
            settled = previousOffset == sv.contentOffset && !sv.isDragging && !sv.isDecelerating && !sv.isZooming
            var found: [Scroller] = []
            Self.collectScrollers(in: web.scrollView, into: &found)
            scrollers = found
        }

        private static func collectScrollers(in view: UIView, into out: inout [Scroller]) {
            for sub in view.subviews {
                if let s = sub as? UIScrollView { out.append(Scroller(view: s, offset: s.contentOffset)) }
                collectScrollers(in: sub, into: &out)
            }
        }
    }

    /// Ask the web views drawn in the last frame where their masked inputs
    /// are, then call `ready` once all have answered or ``timeout`` passes,
    /// whichever comes first. `allFields` adds every text-like input (the
    /// app's or the dashboard's "mask all text fields").
    func prepare(allFields: Bool, _ ready: @escaping () -> Void) {
        generation &+= 1
        let gen = generation
        answers.removeAll()
        let views = seen.compactMap { $0.view }.filter { PrivacyRegistry.isEffectivelyVisible($0) }
        guard !views.isEmpty else { ready(); return }
        var pending = views.count
        var finished = false
        let finish = {
            guard !finished else { return }
            finished = true
            ready()
        }
        let script = allFields ? Self.allFieldsScript : Self.passwordScript
        let previous = lastOffsets
        lastOffsets = views.map { (WeakWebView(view: $0), $0.scrollView.contentOffset) }
        for web in views {
            let asked = Geometry(of: web, previousOffset: previous.first { $0.web.view === web }?.offset)
            web.evaluateJavaScript(script, in: nil, in: .defaultClient) { [weak self, weak web] result in
                // Too late for this frame: the web view was masked whole.
                guard let self, !finished, gen == self.generation else { return }
                if let web, case .success(let value) = result,
                   let answer = Self.answer(from: value, pageZoom: asked.pageZoom) {
                    self.answers.append((WeakWebView(view: web), answer, asked))
                }
                pending -= 1
                if pending == 0 { finish() }
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.timeout) { finish() }
    }

    /// Masks for `web` in `root`'s coordinates, for the frame being captured:
    /// its masked inputs when it answered in time and they can be placed,
    /// otherwise the whole web view. Notes the web view for the next frame's
    /// lookup.
    func maskRects(for web: WKWebView, in root: UIView) -> [MaskRect] {
        seenThisFrame.append(WeakWebView(view: web))
        let whole = PrivacyRegistry.screenRect(of: web, in: root)
        guard !whole.isEmpty else { return [] }
        guard let found = answers.first(where: { $0.web.view === web }),
              let rects = Self.place(found.answer, in: web, asked: found.asked) else {
            // Fail closed, like the reference tracker: never leave a
            // sensitive region uncovered.
            return [MaskRect(rect: whole, style: .overlay)]
        }
        return rects.compactMap { r in
            let s = PrivacyRegistry.screenRect(of: web, in: root, rect: r).intersection(whole)
            return s.isNull || s.isEmpty ? nil : MaskRect(rect: s, style: .overlay)
        }
    }

    /// The frame was captured: its answers are spent, and the web views it
    /// drew are the ones the next frame asks.
    func endFrame() {
        seen = seenThisFrame
        seenThisFrame = []
        answers.removeAll()
    }

    /// Where the measured inputs are drawn now, in the web view's own
    /// coordinates.
    ///
    /// The page gives each input's place in the content (where its viewport
    /// was, plus where the input sat in it), so the input is placed against
    /// the scroll view's offset at capture time, and the one drawn
    /// mid-animation: exact for anything in the page's flow however far the
    /// web process lags the scroll view, and for everything once the page
    /// has caught up. Until then an input pinned to the viewport (a fixed
    /// login sheet) stays where the page measured it, below whatever
    /// obscures the top of the web view, so it is also covered there, for
    /// every inset from none to the largest the web view could be using.
    ///
    /// Nil, so the whole web view is masked, when the measurements can't be
    /// placed: a masked input is being animated, the web view was zoomed or
    /// resized since it was asked or is being zoomed, or one of the page's
    /// own scrollers moved.
    static func place(_ answer: Answer, in web: WKWebView, asked: Geometry) -> [CGRect]? {
        guard !answer.rects.isEmpty else { return [] }
        let sv = web.scrollView
        guard !answer.moving, !sv.isZooming, !sv.isZoomBouncing,
              sv.zoomScale == asked.zoomScale, web.pageZoom == asked.pageZoom,
              web.bounds.size == asked.size,
              asked.scrollers.allSatisfy({ $0.isStill }) else { return nil }
        var offsets = [sv.contentOffset]
        if let p = sv.layer.presentation(), p.bounds.origin != sv.contentOffset {
            offsets.append(p.bounds.origin)
        }
        let settled = asked.settled && !sv.isDragging && !sv.isDecelerating
            && offsets.allSatisfy { $0 == asked.offset }
        let reach = settled ? .zero : largestObscuredInset(of: web)
        let bounds = web.bounds
        var out: [CGRect] = []
        out.reserveCapacity(answer.rects.count)
        for r in answer.rects {
            var cover = CGRect.null
            for o in offsets {
                cover = cover.union(r.offsetBy(dx: answer.origin.x - o.x, dy: answer.origin.y - o.y))
            }
            if !settled {
                cover = cover.union(r).union(r.offsetBy(dx: reach.left, dy: reach.top))
            }
            // A point of slack for rounding between CSS pixels and points.
            let clipped = cover.insetBy(dx: -1, dy: -1).intersection(bounds)
            if !clipped.isNull && !clipped.isEmpty { out.append(clipped) }
        }
        return out
    }

    /// An upper bound on the inset at the top and left of the web view that
    /// the page's viewport starts below: the scroll view's adjusted content
    /// inset, the safe area, and the web view's obscured content insets.
    /// WebKit uses the safe area part (or the obscured insets the app set),
    /// never more.
    static func largestObscuredInset(of web: WKWebView) -> UIEdgeInsets {
        let a = web.scrollView.adjustedContentInset, safe = web.safeAreaInsets
        var top = max(a.top, safe.top), left = max(a.left, safe.left)
        #if compiler(>=6.2)
        if #available(iOS 26.0, *) {
            top = max(top, web.obscuredContentInsets.top)
            left = max(left, web.obscuredContentInsets.left)
        }
        #endif
        return UIEdgeInsets(top: max(top, 0), left: max(left, 0), bottom: 0, right: 0)
    }

    /// The script's `{r: [[x, y, w, h], …], o: [x, y], m: moving}` (CSS px ×
    /// the page's scale) × the web view's page zoom. `r` is relative to the
    /// visual viewport, `o` is that viewport's top-left in the page. Nil when
    /// the answer is malformed, so the web view is masked whole.
    static func answer(from value: Any, pageZoom zoom: CGFloat) -> Answer? {
        guard let dict = value as? [String: Any],
              let rows = dict["r"] as? [Any],
              let o = numbers(dict["o"], count: 2),
              let moving = dict["m"] as? Bool else { return nil }
        var rects: [CGRect] = []
        rects.reserveCapacity(rows.count)
        for row in rows {
            guard let v = numbers(row, count: 4) else { return nil }
            rects.append(CGRect(x: v[0] * zoom, y: v[1] * zoom, width: v[2] * zoom, height: v[3] * zoom))
        }
        return Answer(rects: rects, origin: CGPoint(x: o[0] * zoom, y: o[1] * zoom), moving: moving)
    }

    private static func numbers(_ value: Any?, count: Int) -> [CGFloat]? {
        guard let n = value as? [NSNumber], n.count == count else { return nil }
        let v = n.map { CGFloat($0.doubleValue) }
        return v.allSatisfy({ $0.isFinite }) ? v : nil
    }

    static let passwordScript = script(allFields: false)
    static let allFieldsScript = script(allFields: true)

    /// The page-side lookup. Collects, in the main document, in every
    /// same-origin frame and in every open shadow root (web components):
    ///   - `input` elements of type password, or whose autocomplete names a
    ///     password, one-time code or card number (the web's names for the
    ///     content types masked natively);
    ///   - with `allFields`, every text-like input and every textarea;
    ///   - elements carrying our web SDK's privacy classes.
    /// A frame of another origin can't be read into. It is masked whole only
    /// when its attributes say it may take a password, code or card (payment
    /// or sign-in frames); video, map and other embeds stay visible, as in
    /// the reference tracker. Zero-size elements are skipped.
    ///
    /// Also returns where the visual viewport is in the page, and whether a
    /// masked element sits in one whose position or size is being animated.
    private static func script(allFields: Bool) -> String {
        return #"""
        (function (allFields) {
          var vv = window.visualViewport;
          var s = vv ? vv.scale : 1, ox = vv ? vv.offsetLeft : 0, oy = vv ? vv.offsetTop : 0;
          var px = vv ? vv.pageLeft : window.scrollX, py = vv ? vv.pageTop : window.scrollY;
          var textTypes = { text: 1, email: 1, url: 1, search: 1, tel: 1, number: 1 };
          var secureTokens = { 'current-password': 1, 'new-password': 1, 'one-time-code': 1, 'cc-number': 1 };
          var credentialFrame = /pay|card|checkout|billing|secure|3ds|auth|login|log-in|signin|sign-in|password|passcode|otp|verif|account|bank|wallet|cvc|cvv/i;
          var credentialAllow = /payment|publickey-credentials|otp-credentials/i;
          var out = [], hits = [], docs = [document];
          function push(el, r, dx, dy, clip) {
            var l = r.left + dx, t = r.top + dy, rt = r.right + dx, b = r.bottom + dy;
            if (clip) {
              l = Math.max(l, clip[0]); t = Math.max(t, clip[1]);
              rt = Math.min(rt, clip[2]); b = Math.min(b, clip[3]);
            }
            if (!(rt - l > 0) || !(b - t > 0)) return;
            out.push([(l - ox) * s, (t - oy) * s, (rt - l) * s, (b - t) * s]);
            hits.push(el);
          }
          function isSecure(el) {
            if ((el.type || '').toLowerCase() === 'password') return true;
            var ac = (el.getAttribute('autocomplete') || '').toLowerCase().split(/\s+/);
            for (var i = 0; i < ac.length; i++) if (secureTokens[ac[i]]) return true;
            return false;
          }
          function mayTakeCredentials(f) {
            if (credentialAllow.test(f.getAttribute('allow') || '')) return true;
            return credentialFrame.test([f.getAttribute('src'), f.getAttribute('name'),
              f.getAttribute('title'), f.id, f.getAttribute('class')].join(' '));
          }
          function scan(root, dx, dy, clip, depth) {
            var i, el, list = root.querySelectorAll('input');
            for (i = 0; i < list.length; i++) {
              el = list[i];
              if (isSecure(el) || (allFields && textTypes[(el.type || '').toLowerCase()])) {
                push(el, el.getBoundingClientRect(), dx, dy, clip);
              }
            }
            if (allFields) {
              list = root.querySelectorAll('textarea');
              for (i = 0; i < list.length; i++) push(list[i], list[i].getBoundingClientRect(), dx, dy, clip);
            }
            list = root.querySelectorAll('.rr-block, .rr-mask');
            for (i = 0; i < list.length; i++) push(list[i], list[i].getBoundingClientRect(), dx, dy, clip);
            list = root.querySelectorAll('iframe, frame');
            for (i = 0; i < list.length; i++) {
              var f = list[i], fr = f.getBoundingClientRect(), inner = null;
              if (!(fr.width > 0) || !(fr.height > 0)) continue;
              try { inner = f.contentDocument; } catch (e) { inner = null; }
              if (!inner) { if (mayTakeCredentials(f)) push(f, fr, dx, dy, clip); continue; }
              if (depth >= 8) { push(f, fr, dx, dy, clip); continue; }
              var ix = dx + fr.left + f.clientLeft, iy = dy + fr.top + f.clientTop;
              var c = [ix, iy, ix + f.clientWidth, iy + f.clientHeight];
              if (clip) {
                c = [Math.max(c[0], clip[0]), Math.max(c[1], clip[1]),
                     Math.min(c[2], clip[2]), Math.min(c[3], clip[3])];
              }
              docs.push(inner);
              scan(inner, ix, iy, c, depth + 1);
            }
            list = root.querySelectorAll('*');
            for (i = 0; i < list.length; i++) {
              if (list[i].shadowRoot) scan(list[i].shadowRoot, dx, dy, clip, depth);
            }
          }
          var skipKeys = { offset: 1, computedOffset: 1, easing: 1, composite: 1 };
          var geometry = /^(transform|translate|rotate|scale|left|top|right|bottom|inset|margin|padding|width|height|offset|zoom)/;
          function movesGeometry(a) {
            if (a.playState !== 'running' || !a.effect || !a.effect.target || !a.effect.getKeyframes) return false;
            var kf = a.effect.getKeyframes();
            for (var i = 0; i < kf.length; i++) {
              for (var k in kf[i]) if (!skipKeys[k] && geometry.test(k)) return true;
            }
            return false;
          }
          function inside(node, ancestor) {
            while (node) {
              if (node === ancestor) return true;
              if (node.nodeType === 9) node = node.defaultView ? node.defaultView.frameElement : null;
              else node = node.parentNode || node.host || null;
            }
            return false;
          }
          scan(document, 0, 0, null, 0);
          var moving = false;
          if (hits.length) {
            var anims = [];
            for (var d = 0; d < docs.length; d++) {
              if (docs[d].getAnimations) anims = anims.concat(docs[d].getAnimations());
            }
            for (var a = 0; a < anims.length && !moving; a++) {
              if (!movesGeometry(anims[a])) continue;
              for (var h = 0; h < hits.length; h++) {
                if (inside(hits[h], anims[a].effect.target)) { moving = true; break; }
              }
            }
          }
          return { r: out, o: [px * s, py * s], m: moving };
        })(
        """# + (allFields ? "true" : "false") + ");"
    }
}
#endif
