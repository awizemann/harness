//
//  WebSessionStateIO.swift
//  Harness
//
//  Injecting `WebSessionState` into — and exporting it out of — a live
//  `WKWebView`'s (still non-persistent) website data store.
//
//  ## The invariant this must not break
//
//  `WebViewWindowController` builds every session on
//  `WKWebsiteDataStore.nonPersistent()`. That is the fresh-user invariant:
//  no cookies, no localStorage, no service workers, nothing inherited from a
//  previous session or from the user's browser, nothing written to disk.
//  Injection does NOT change the store type — it seeds an in-memory store
//  that still dies with the session. A session started without
//  `session_state` is byte-for-byte the historical fresh user.
//
//  ## Secrets
//
//  Cookie and localStorage values are credentials. Nothing in this file logs
//  a value: the log lines carry counts and, at most, cookie NAMES. See the
//  header of `WebSessionState.swift` for the full rule.
//

import Foundation
import WebKit

@MainActor
enum WebSessionStateIO {

    /// Seed `state` into the controller's data store BEFORE the first
    /// navigation.
    ///
    /// Cookies go straight into `WKHTTPCookieStore`, which needs no document.
    /// `localStorage` does: it is per-origin and only reachable from a page
    /// on that origin, so each requested origin is loaded once (its root URL),
    /// seeded via JS, and left behind when the caller loads the real start
    /// URL. That extra load is the price of localStorage support and is why
    /// `origins` is optional in the wire schema — a cookie-only state costs
    /// no navigation at all.
    ///
    /// Best-effort per item: one malformed cookie or one origin that refuses
    /// to load does not fail the session. Returns the counts actually applied
    /// so the caller can log them (counts only — never values).
    @discardableResult
    static func inject(
        _ state: WebSessionState,
        into controller: WebViewWindowController,
        navigationTimeout: Duration = .seconds(20)
    ) async -> (cookies: Int, storageItems: Int) {
        let store = controller.webView.configuration.websiteDataStore.httpCookieStore

        var applied = 0
        for cookie in state.cookies {
            guard let http = httpCookie(from: cookie) else { continue }
            await store.setCookie(http)
            applied += 1
        }

        var seededItems = 0
        for origin in state.origins where !origin.localStorage.isEmpty {
            guard let url = URL(string: origin.origin), url.scheme != nil, url.host != nil else { continue }
            controller.webView.load(URLRequest(url: url))
            await controller.navigationDelegate.awaitNextLoad(timeout: navigationTimeout)
            let payload = origin.localStorage.map { ["name": $0.name, "value": $0.value] }
            // The values ride as `arguments:` rather than being interpolated
            // into the script text — a token containing a quote or a newline
            // can't break out of the script, and the value never becomes part
            // of a string WebKit might echo back in a JS error message.
            let js = """
            const items = pairs;
            let n = 0;
            for (const item of items) {
              try { window.localStorage.setItem(item.name, item.value); n++; } catch (e) {}
            }
            return n;
            """
            do {
                let result = try await controller.webView.callAsyncJavaScript(
                    js, arguments: ["pairs": payload], in: nil, contentWorld: .page
                )
                seededItems += (result as? Int) ?? ((result as? NSNumber)?.intValue ?? 0)
            } catch {
                // Origin unreachable / storage blocked — skip it. The caller
                // still gets a working session with whatever cookies applied.
                continue
            }
        }
        return (applied, seededItems)
    }

    /// Read the live session's cookies plus the CURRENT page's `localStorage`.
    ///
    /// Origin scope is deliberate and documented on the tool: a page can only
    /// read its own origin's storage, so the export covers the origin the
    /// session is standing on right now. Cookies are not so limited — the
    /// store hands back everything it holds, which is what makes an export
    /// taken after an SSO round-trip useful.
    static func export(from controller: WebViewWindowController) async -> WebSessionState {
        let store = controller.webView.configuration.websiteDataStore.httpCookieStore
        let httpCookies = await store.allCookies()
        let cookies = httpCookies.map { c in
            WebSessionCookie(
                name: c.name,
                value: c.value,
                domain: c.domain,
                path: c.path,
                expires: c.expiresDate,
                secure: c.isSecure,
                httpOnly: c.isHTTPOnly
            )
        }

        var origins: [WebSessionOriginState] = []
        let js = """
        return (() => {
          const out = [];
          try {
            for (let i = 0; i < window.localStorage.length; i++) {
              const k = window.localStorage.key(i);
              out.push({ name: k, value: window.localStorage.getItem(k) });
            }
          } catch (e) {}
          return { origin: location.origin, items: out };
        })();
        """
        if let result = try? await controller.webView.callAsyncJavaScript(
            js, arguments: [:], in: nil, contentWorld: .page
        ), let dict = result as? [String: Any],
           let origin = dict["origin"] as? String, !origin.isEmpty, origin != "null" {
            let items = ((dict["items"] as? [[String: Any]]) ?? []).compactMap { raw -> WebSessionStorageItem? in
                guard let name = raw["name"] as? String, let value = raw["value"] as? String else { return nil }
                return WebSessionStorageItem(name: name, value: value)
            }
            origins.append(WebSessionOriginState(origin: origin, localStorage: items))
        }

        return WebSessionState(cookies: cookies, origins: origins)
    }

    /// Map our value type to Foundation's cookie. Returns nil for a cookie
    /// the platform rejects (an empty domain, a name it won't accept) rather
    /// than substituting a guess.
    static func httpCookie(from cookie: WebSessionCookie) -> HTTPCookie? {
        // Foundation will happily build a cookie with an empty name or domain;
        // WebKit then has nothing to match it against, so it would be silently
        // dropped at request time. Reject it here instead, so the injection
        // count the caller logs reflects what was actually applied.
        guard !cookie.name.isEmpty, !cookie.domain.isEmpty else { return nil }
        var properties: [HTTPCookiePropertyKey: Any] = [
            .name: cookie.name,
            .value: cookie.value,
            .domain: cookie.domain,
            .path: cookie.path.isEmpty ? "/" : cookie.path
        ]
        if let expires = cookie.expires { properties[.expires] = expires }
        if cookie.secure { properties[.secure] = "TRUE" }
        // `HTTPOnly` has no public HTTPCookiePropertyKey; the raw key is what
        // Foundation itself reads, and it round-trips through WKHTTPCookieStore.
        if cookie.httpOnly { properties[HTTPCookiePropertyKey("HttpOnly")] = "TRUE" }
        return HTTPCookie(properties: properties)
    }
}
