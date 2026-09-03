.pragma library

// Native (built-in) chat tools: web_search + webfetch. Pure JS;
// NativeToolsService.qml is the transport. Never log with nested
// parens — the test harness strips console.* naively.

// Append trailer for `curl -w` so the collected stdout carries the HTTP
// status (and content type) after the body. Same convention as the
// provider fetchers' NEXUS_STATUS trailer; extractHttpStatus splits it.
var STATUS_TRAILER = "\\nNEXUS_STATUS:%{http_code}|%{content_type}\\n";

var MAX_SEARCH_RESULTS = 8;
var MAX_QUERY_LENGTH = 400;
// webfetch returns at most FETCH_CHUNK characters per call; the model
// pages through long content with start_index.
var FETCH_CHUNK = 16000;
// Guard before any regex work on untrusted bodies (perf).
var MAX_BODY_BYTES = 2 * 1024 * 1024;
// Pinned empirically: DDG captcha-challenges modern/curl-ish UAs;
// this string passes. Regression test guards it — don't "modernize".
var USER_AGENT = "Mozilla/5.0 (Windows NT 10.0; Win64; x64)";

function isNativeTool(name) {
    return name === "web_search" || name === "webfetch";
}

// Tool defs for chat requests. `enabledNames` (optional array) keeps
// only those tools; absent/null → the full registry.
function toolDefs(enabledNames) {
    var all = [
        {
            type: "function",
            function: {
                name: "web_search",
                description: "Search the web via DuckDuckGo. Returns " +
                    "numbered results with title, URL and snippet.",
                parameters: {
                    type: "object",
                    properties: {
                        query: { type: "string", description: "Search query" }
                    },
                    required: ["query"]
                }
            }
        },
        {
            type: "function",
            function: {
                name: "webfetch",
                description: "Fetch a URL (http/https) and return its " +
                    "readable text content.",
                parameters: {
                    type: "object",
                    properties: {
                        url: { type: "string", description: "The URL to fetch" },
                        start_index: {
                            type: "integer",
                            description: "Optional character offset to " +
                                "continue reading a long page (from the " +
                                "truncation marker of the previous call)"
                        }
                    },
                    required: ["url"]
                }
            }
        }
    ];
    if (!enabledNames) return all;
    return all.filter(function (d) {
        return enabledNames.indexOf(d.function.name) >= 0;
    });
}

// Escape a value for a double-quoted curl config directive. Local copy
// of Providers.escapeCurlConfig — this lib must stay import-free for
// the node test harness.
function escapeCurlConfig(s) {
    if (typeof s !== "string") return "";
    return s.replace(/\\/g, "\\\\")
            .replace(/"/g, '\\"')
            .replace(/\n/g, "\\n")
            .replace(/\r/g, "\\r")
            .replace(/\t/g, "\\t");
}

// Validate + normalize native-tool arguments. Returns
// {ok:true, args:{…}} or {ok:false, error:"…"}. webfetch allows any
// http/https URL — no private-range filtering (deliberate).
function validateArgs(name, args) {
    args = args || {};
    if (name === "web_search") {
        var q = typeof args.query === "string" ? args.query.trim() : "";
        if (!q) return { ok: false, error: "Missing required argument: query" };
        if (q.length > MAX_QUERY_LENGTH) q = q.substring(0, MAX_QUERY_LENGTH);
        return { ok: true, args: { query: q } };
    }
    if (name === "webfetch") {
        var u = typeof args.url === "string" ? args.url.trim() : "";
        if (!u) return { ok: false, error: "Missing required argument: url" };
        if (!/^https?:\/\//i.test(u))
            return { ok: false,
                     error: "Unsupported URL scheme — only http and https are allowed" };
        var s = 0;
        if (typeof args.start_index === "number"
            && isFinite(args.start_index))
            s = Math.max(0, Math.floor(args.start_index));
        else if (typeof args.start_index === "string"
                 && args.start_index.trim() !== ""
                 && isFinite(parseInt(args.start_index, 10)))
            s = Math.max(0, parseInt(args.start_index, 10));
        return { ok: true, args: { url: u, start_index: s } };
    }
    return { ok: false, error: "Unknown native tool: " + String(name) };
}

// Split the STATUS_TRAILER off collected curl stdout.
function extractHttpStatus(text) {
    var out = { status: 0, contentType: "", body: text || "" };
    if (!text) return out;
    var marker = "NEXUS_STATUS:";
    var idx = text.lastIndexOf(marker);
    if (idx < 0) return out;
    var tail = text.substring(idx + marker.length).trim();
    var pipe = tail.indexOf("|");
    var statusPart = pipe >= 0 ? tail.substring(0, pipe) : tail;
    if (pipe >= 0) out.contentType = tail.substring(pipe + 1).trim().toLowerCase();
    var status = parseInt(statusPart, 10);
    if (isNaN(status)) return out;
    out.status = status;
    out.body = text.substring(0, idx);
    if (out.body.length > 0 && out.body[out.body.length - 1] === "\n")
        out.body = out.body.substring(0, out.body.length - 1);
    return out;
}

function _baseCmd(maxTime) {
    return ["curl", "-K", "-", "-sS", "--show-error",
            "--connect-timeout", "5", "--max-time", String(maxTime),
            "-w", STATUS_TRAILER];
}

// curl argv + stdin config for a search POST to the DuckDuckGo HTML
// endpoint. encodeURIComponent output never contains ", \ or newlines,
// so the data directive needs no further escaping.
function buildSearchRequest(args) {
    var v = validateArgs("web_search", args);
    if (!v.ok) return v;
    var config = 'url = "https://html.duckduckgo.com/html/"\n'
        + 'user-agent = "' + USER_AGENT + '"\n'
        + 'data = "q=' + encodeURIComponent(v.args.query) + '"\n';
    return { ok: true, cmd: _baseCmd(15), config: config, args: v.args };
}

// curl argv + stdin config for a page fetch. Model-provided URLs are
// config-escaped (they may contain quotes/newlines).
function buildFetchRequest(args) {
    var v = validateArgs("webfetch", args);
    if (!v.ok) return v;
    var config = 'url = "' + escapeCurlConfig(v.args.url) + '"\n'
        + 'user-agent = "' + USER_AGENT + '"\n'
        + 'location\n';
    return { ok: true, cmd: _baseCmd(20), config: config, args: v.args };
}

// ── Text helpers (shared with htmlToText) ────────────────────────

function _fromCodePoint(c) {
    if (String.fromCodePoint) return String.fromCodePoint(c);
    if (c <= 0xffff) return String.fromCharCode(c);
    c -= 0x10000;
    return String.fromCharCode(0xd800 + (c >> 10), 0xdc00 + (c & 0x3ff));
}

var NAMED_ENTITIES = {
    amp: "&", lt: "<", gt: ">", quot: "\"", apos: "'", nbsp: " ",
    hellip: "…", mdash: "—", ndash: "–",
    lsquo: "\u2018", rsquo: "\u2019", ldquo: "\u201C", rdquo: "\u201D",
    copy: "©", reg: "®", trade: "™", laquo: "«", raquo: "»",
    middot: "·", bull: "•", sect: "§", para: "¶", deg: "°",
    plusmn: "±", times: "×", divide: "÷", micro: "µ", euro: "€",
    pound: "£", yen: "¥", cent: "¢",
    eacute: "é", egrave: "è", agrave: "à", ccedil: "ç", uuml: "ü",
    ouml: "ö", auml: "ä", szlig: "ß"
};

function decodeEntities(s) {
    return String(s || "")
        .replace(/&#x([0-9a-fA-F]+);/g, function (m, h) {
            var c = parseInt(h, 16);
            return isFinite(c) && c > 0 && c <= 0x10ffff ? _fromCodePoint(c) : m;
        })
        .replace(/&#(\d+);/g, function (m, d) {
            var c = parseInt(d, 10);
            return isFinite(c) && c > 0 && c <= 0x10ffff ? _fromCodePoint(c) : m;
        })
        .replace(/&([a-zA-Z][a-zA-Z0-9]*);/g, function (m, name) {
            return Object.prototype.hasOwnProperty.call(NAMED_ENTITIES, name)
                ? NAMED_ENTITIES[name] : m;
        });
}

function _stripTags(s) {
    return String(s || "").replace(/<[^>]*>/g, " ");
}

// Tags off, entities decoded, all whitespace runs collapsed.
function collapse(s) {
    return decodeEntities(_stripTags(s)).replace(/\s+/g, " ").trim();
}

// ── DuckDuckGo HTML search parsing ───────────────────────────────

// Collect <a> tags carrying exactly `className` in their class list
// (word match, so result__a never matches result__ad). Returns
// [{href, inner}] in document order.
function _collectAnchors(html, className) {
    var out = [];
    var re = /<a\b([^>]*)>([\s\S]*?)<\/a>/g;
    var m;
    while ((m = re.exec(html)) !== null) {
        var attrs = m[1];
        if (attrs.indexOf(className) < 0) continue;
        var cm = /\bclass\s*=\s*"([^"]*)"/.exec(attrs)
            || /\bclass\s*=\s*'([^']*)'/.exec(attrs);
        if (!cm) continue;
        if (cm[1].split(/\s+/).indexOf(className) < 0) continue;
        var hm = /\bhref\s*=\s*"([^"]*)"/.exec(attrs)
            || /\bhref\s*=\s*'([^']*)'/.exec(attrs);
        out.push({ href: hm ? hm[1] : "", inner: m[2] });
    }
    return out;
}

// DDG wraps result hrefs in a redirect: //duckduckgo.com/l/?uddg=<enc>&rut=…
// Direct http(s) hrefs pass through; anything else → "".
function _resolveHref(href) {
    if (!href) return "";
    var abs = href.charAt(0) === "/" && href.charAt(1) === "/"
        ? "https:" + href : href;
    var uddg = /[?&]uddg=([^&]+)/.exec(abs);
    if (uddg) {
        try { return decodeURIComponent(uddg[1]); } catch (e) { return ""; }
    }
    return /^https?:\/\//i.test(abs) ? abs : "";
}

function parseSearchResults(html) {
    if (typeof html !== "string" || html.length === 0)
        return { ok: false, error: "Empty response from DuckDuckGo." };

    // Sponsored blocks are removed before collection so their anchors
    // never appear as results. Lazy two-close-div match: best-effort by
    // design — if a mutated layout defeats it, an occasional sponsored
    // result may surface (cosmetic, titles/urls still correct).
    var clean = html.replace(
        /<div[^>]*result--ad[^>]*>[\s\S]*?<\/div>\s*<\/div>/g, "");

    var anchors = _collectAnchors(clean, "result__a");
    if (anchors.length === 0) {
        // Only consult block-page markers when there are no results at
        // all — "anomaly" inside a snippet must not false-positive.
        var lower = clean.toLowerCase();
        if (lower.indexOf("anomaly") >= 0
            || lower.indexOf("unfortunately, bots") >= 0
            || lower.indexOf("captcha") >= 0)
            return { ok: false,
                     error: "DuckDuckGo blocked this search — try again shortly." };
        return { ok: true, results: [] };
    }

    var snippets = _collectAnchors(clean, "result__snippet");
    var results = [];
    var seen = {};
    for (var i = 0; i < anchors.length && results.length < MAX_SEARCH_RESULTS; i++) {
        var url = _resolveHref(anchors[i].href);
        var title = collapse(anchors[i].inner);
        if (!url || !title || seen[url]) continue;
        seen[url] = true;
        results.push({
            title: title,
            url: url,
            snippet: snippets[i] ? collapse(snippets[i].inner) : ""
        });
    }
    return { ok: true, results: results };
}

// True when the body should go through HTML extraction: an explicit
// html content-type wins; with no type, sniff a leading tag.
function isHtmlContent(contentType, body) {
    if (contentType) return contentType.indexOf("html") >= 0;
    return /^\s*</.test(String(body || ""));
}

// HTML → readable plain text for the model. Order matters: comments,
// script-ish blocks and tags are stripped BEFORE entity decoding, so
// "&lt;script&gt;" inside text decodes to literal text and is never
// treated as markup.
function htmlToText(html) {
    if (typeof html !== "string") return { title: "", text: "" };
    var tm = /<title[^>]*>([\s\S]*?)<\/title>/i.exec(html);
    var title = tm ? collapse(tm[1]) : "";
    if (html.length > MAX_BODY_BYTES) html = html.substring(0, MAX_BODY_BYTES);
    var s = html
        .replace(/<!--[\s\S]*?-->/g, " ")
        .replace(/<(script|style|noscript|svg|head)\b[^>]*>[\s\S]*?<\/\1>/gi, " ")
        .replace(/<br\s*\/?>/gi, "\n")
        .replace(/<\/(p|div|li|h[1-6]|tr|blockquote|pre|section|article|header|footer|table|ul|ol|dl|dt|dd)>/gi, "\n")
        .replace(/<[^>]*>/g, " ");
    s = decodeEntities(s);
    s = s.replace(/[ \t]+/g, " ");
    s = s.replace(/ ?\n ?/g, "\n");
    s = s.replace(/\n{3,}/g, "\n\n").trim();
    return { title: title, text: s };
}

// Numbered plain-text listing the model reads. Zero results is a
// normal outcome, not an error.
function formatSearchResults(results, query) {
    if (!results || results.length === 0)
        return "No results found for \"" + String(query || "") + "\".";
    var lines = [];
    for (var i = 0; i < results.length; i++) {
        var r = results[i];
        lines.push((i + 1) + ". " + r.title + "\n   " + r.url
            + (r.snippet ? "\n   " + r.snippet : ""));
    }
    return lines.join("\n");
}

// Final webfetch body: optional title header + a FETCH_CHUNK slice of
// content starting at startIndex, with a continuation marker when cut.
// Header/offsets are independent: the marker counts characters of the
// content itself so start_index paging is header-agnostic.
function pageContent(text, startIndex, title) {
    text = String(text || "");
    var start = typeof startIndex === "number"
        && isFinite(startIndex) && startIndex > 0 ? Math.floor(startIndex) : 0;
    if (start >= text.length)
        return "[start_index " + start + " is beyond the end of the " +
               "content (length " + text.length + ").]";
    var slice = text.substring(start, start + FETCH_CHUNK);
    var end = start + slice.length;
    var body = (title ? "# " + title + "\n\n" : "") + slice;
    if (end < text.length)
        body += "\n\n[Truncated at character " + end + " of " +
                text.length + " — call webfetch again with start_index=" +
                end + " to continue.]";
    return body;
}
