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
/// Fail closed: a web view with no answer for the frame — the first frame
/// it appears in, a script error, or no answer within ``timeout`` — is masked
/// whole for that frame.
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
    /// Answers for the frame about to be captured: the masked inputs, in
    /// each web view's own coordinates.
    private var answers: [(web: WeakWebView, rects: [CGRect])] = []
    /// Bumped by each lookup, so a late answer can't land in a later frame.
    private var generation = 0

    private struct WeakWebView {
        weak var view: WKWebView?
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
        for web in views {
            web.evaluateJavaScript(script, in: nil, in: .defaultClient) { [weak self, weak web] result in
                // Too late for this frame: the web view was masked whole.
                guard let self, !finished, gen == self.generation else { return }
                if let web, case .success(let value) = result,
                   let rects = Self.rects(from: value, in: web) {
                    self.answers.append((WeakWebView(view: web), rects))
                }
                pending -= 1
                if pending == 0 { finish() }
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.timeout) { finish() }
    }

    /// Masks for `web` in `root`'s coordinates, for the frame being captured:
    /// its masked inputs when it answered in time, otherwise the whole web
    /// view. Notes the web view for the next frame's lookup.
    func maskRects(for web: WKWebView, in root: UIView) -> [MaskRect] {
        seenThisFrame.append(WeakWebView(view: web))
        let whole = PrivacyRegistry.screenRect(of: web, in: root)
        guard !whole.isEmpty else { return [] }
        guard let rects = answers.first(where: { $0.web.view === web })?.rects else {
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

    /// The script's `[[x, y, w, h], …]` (points from the visual viewport's
    /// top-left, CSS px × pinch scale) mapped into the web view's own
    /// coordinates: × the web view's page zoom, offset by the scroll view's
    /// insets (the visual viewport starts below a translucent bar). Nil when
    /// the answer is malformed, so the web view is masked whole.
    static func rects(from value: Any, in web: WKWebView) -> [CGRect]? {
        guard let rows = value as? [Any] else { return nil }
        let zoom = web.pageZoom
        let inset = web.scrollView.adjustedContentInset
        var out: [CGRect] = []
        out.reserveCapacity(rows.count)
        for row in rows {
            guard let n = row as? [NSNumber], n.count == 4 else { return nil }
            let v = n.map { CGFloat($0.doubleValue) }
            guard v.allSatisfy({ $0.isFinite }) else { return nil }
            let r = CGRect(x: inset.left + v[0] * zoom, y: inset.top + v[1] * zoom,
                           width: v[2] * zoom, height: v[3] * zoom)
            // A point of slack for rounding between CSS pixels and points.
            let clipped = r.insetBy(dx: -1, dy: -1).intersection(web.bounds)
            if !clipped.isNull && !clipped.isEmpty { out.append(clipped) }
        }
        return out
    }

    static let passwordScript = script(allFields: false)
    static let allFieldsScript = script(allFields: true)

    /// The page-side lookup. Collects, in the main document and in every
    /// same-origin frame:
    ///   - `input` elements of type password, or whose autocomplete names a
    ///     password, one-time code or card number (the web's names for the
    ///     content types masked natively);
    ///   - with `allFields`, every text-like input and every textarea;
    ///   - elements carrying our web SDK's privacy classes.
    /// A frame the page can't read into (another origin) is masked whole: its
    /// inputs can't be found, and web replay can't record such frames either.
    /// Zero-size elements are skipped.
    private static func script(allFields: Bool) -> String {
        return #"""
        (function (allFields) {
          var vv = window.visualViewport;
          var s = vv ? vv.scale : 1, ox = vv ? vv.offsetLeft : 0, oy = vv ? vv.offsetTop : 0;
          var textTypes = { text: 1, email: 1, url: 1, search: 1, tel: 1, number: 1 };
          var secureTokens = { 'current-password': 1, 'new-password': 1, 'one-time-code': 1, 'cc-number': 1 };
          var out = [];
          function push(r, dx, dy, clip) {
            var l = r.left + dx, t = r.top + dy, rt = r.right + dx, b = r.bottom + dy;
            if (clip) {
              l = Math.max(l, clip[0]); t = Math.max(t, clip[1]);
              rt = Math.min(rt, clip[2]); b = Math.min(b, clip[3]);
            }
            if (!(rt - l > 0) || !(b - t > 0)) return;
            out.push([(l - ox) * s, (t - oy) * s, (rt - l) * s, (b - t) * s]);
          }
          function isSecure(el) {
            if ((el.type || '').toLowerCase() === 'password') return true;
            var ac = (el.getAttribute('autocomplete') || '').toLowerCase().split(/\s+/);
            for (var i = 0; i < ac.length; i++) if (secureTokens[ac[i]]) return true;
            return false;
          }
          function scan(doc, dx, dy, clip, depth) {
            var i, el, list = doc.querySelectorAll('input');
            for (i = 0; i < list.length; i++) {
              el = list[i];
              if (isSecure(el) || (allFields && textTypes[(el.type || '').toLowerCase()])) {
                push(el.getBoundingClientRect(), dx, dy, clip);
              }
            }
            if (allFields) {
              list = doc.querySelectorAll('textarea');
              for (i = 0; i < list.length; i++) push(list[i].getBoundingClientRect(), dx, dy, clip);
            }
            list = doc.querySelectorAll('.rr-block, .rr-mask');
            for (i = 0; i < list.length; i++) push(list[i].getBoundingClientRect(), dx, dy, clip);
            list = doc.querySelectorAll('iframe, frame');
            for (i = 0; i < list.length; i++) {
              var f = list[i], fr = f.getBoundingClientRect(), inner = null;
              if (!(fr.width > 0) || !(fr.height > 0)) continue;
              try { inner = f.contentDocument; } catch (e) { inner = null; }
              if (!inner || depth >= 3) { push(fr, dx, dy, clip); continue; }
              var ix = dx + fr.left + f.clientLeft, iy = dy + fr.top + f.clientTop;
              var c = [ix, iy, ix + f.clientWidth, iy + f.clientHeight];
              if (clip) {
                c = [Math.max(c[0], clip[0]), Math.max(c[1], clip[1]),
                     Math.min(c[2], clip[2]), Math.min(c[3], clip[3])];
              }
              scan(inner, ix, iy, c, depth + 1);
            }
          }
          scan(document, 0, 0, null, 0);
          return out;
        })(
        """# + (allFields ? "true" : "false") + ");"
    }
}
#endif
