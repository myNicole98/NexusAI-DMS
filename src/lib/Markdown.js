.pragma library

// Markdown → Qt rich-text HTML. Built for live rendering: unterminated
// constructs (open code fences, unclosed bold) degrade to plain text
// instead of breaking. All input is HTML-escaped; link schemes are
// restricted to http(s).

function escapeHtml(s) {
    if (typeof s !== "string") return "";
    return s.replace(/&/g, "&amp;").replace(/</g, "&lt;")
            .replace(/>/g, "&gt;").replace(/"/g, "&quot;");
}

function safeUrl(url) {
    var u = (url || "").trim();
    return /^https?:\/\//i.test(u) ? u : "";
}

// Split message text into text / code segments for the bubble
// renderer. Mirrors markdownToHtml's fenced-block grammar exactly
// (including mid-stream unterminated fences) so both render paths
// never disagree; no input character is dropped.
function splitCodeSegments(text) {
    var segs = [];
    if (typeof text !== "string" || text.length === 0) return segs;

    var re = /```([^\n`]*)\n([\s\S]*?)(?:```|$)/g;
    var last = 0;
    var m;
    while ((m = re.exec(text)) !== null) {
        if (m.index > last) {
            var between = text.substring(last, m.index);
            if (between.length > 0) segs.push({ type: "text", text: between });
        }
        segs.push({
            type: "code",
            lang: m[1].trim(),
            code: m[2].replace(/\n$/, "")
        });
        last = m.index + m[0].length;
    }
    if (last < text.length) {
        var tail = text.substring(last);
        if (tail.length > 0) segs.push({ type: "text", text: tail });
    }
    return segs;
}

function styleAttr(colors, key, cssProp) {
    if (!colors || !colors[key]) return "";
    return ' style="' + cssProp + ": " + colors[key] + ';"';
}

// ── Inline formatting (run on escaped text) ──────────────────────

function fmtInline(escaped, colors) {
    var s = escaped;

    // inline code first; stash rendered spans behind \x01 placeholders so
    // later rules (emphasis, links, autolinks) cannot reach inside them
    var codeSpans = [];
    s = s.replace(/`([^`\n]+)`/g, function (_, code) {
        codeSpans.push('<code style="font-family: monospace; background-color: ' +
            ((colors && colors.inlineCodeBg) || "rgba(128,128,128,0.18)") + ";" +
            ((colors && colors.inlineCodeColor)
                ? " color: " + colors.inlineCodeColor + ";" : "") +
            ' border-radius: 4px; padding: 0 3px;">' + code + "</code>");
        return "\x01C" + (codeSpans.length - 1) + "\x01";
    });

    s = s.replace(/\*\*\*([^*\n]+)\*\*\*/g, "<b><i>$1</i></b>");
    s = s.replace(/\*\*([^*\n]+)\*\*/g, "<b>$1</b>");
    s = s.replace(/\*([^*\n]+)\*/g, "<i>$1</i>");
    s = s.replace(/__([^_\n]+)__/g, "<b>$1</b>");
    s = s.replace(/~~([^~\n]+)~~/g, "<s>$1</s>");

    // links: [text](url) — text already escaped, url re-validated
    s = s.replace(/\[([^\]\n]+)\]\(([^)\s]+)\)/g, function (_, text, url) {
        var u = safeUrl(url.replace(/&amp;/g, "&"));
        if (!u) return text;
        return '<a href="' + escapeHtml(u) + '"' +
            styleAttr(colors, "linkColor", "color") + ">" + text + "</a>";
    });

    // autolink bare http(s) URLs
    s = s.replace(/(^|[\s(])(https?:\/\/[^\s<)]+)/g, function (_, pre, url) {
        var u = url.replace(/&amp;/g, "&");
        return pre + '<a href="' + escapeHtml(u) + '"' +
            styleAttr(colors, "linkColor", "color") + ">" + url + "</a>";
    });

    return s.replace(/\x01C(\d+)\x01/g, function (_, idx) {
        return codeSpans[parseInt(idx, 10)];
    });
}

// ── Block pipeline ────────────────────────────────────────────────

function markdownToHtml(text, colors, highlightFn) {
    if (typeof text !== "string" || text.length === 0) return "";

    // NUL/SOH are reserved as internal placeholder sentinels (\x00B…\x00
    // fenced blocks, \x01C…\x01 inline code); strip them from raw input so
    // literal control chars in message text cannot collide with them.
    text = text.replace(/[\x00\x01]/g, "");

    // 1. Pull out fenced code blocks before anything else so their
    //    content never sees inline formatting. An unterminated fence
    //    (mid-stream) still captures to end-of-text.
    var blocks = [];
    var src = text.replace(/```([^\n`]*)\n([\s\S]*?)(?:```|$)/g, function (_, lang, code) {
        var language = lang.trim();
        var rendered;
        if (language && highlightFn)
            rendered = highlightFn(code.replace(/\n$/, ""), language);
        else
            rendered = escapeHtml(code.replace(/\n$/, ""));
        var html = (language
            ? '<div style="font-family: monospace; font-size: small; opacity: 0.7; margin: 4px 0 0 4px;">' +
              escapeHtml(language) + "</div>"
            : "") +
            '<pre style="background-color: ' +
            ((colors && colors.codeBg) || "rgba(128,128,128,0.14)") +
            '; border-radius: 8px; padding: 8px; margin: 4px 0;">' +
            '<code style="font-family: monospace; white-space: pre-wrap;">' +
            rendered + "</code></pre>";
        blocks.push(html);
        return "\x00B" + (blocks.length - 1) + "\x00";
    });

    // 2. Escape everything that remains.
    src = escapeHtml(src);

    // 3. Split into lines and group into blocks.
    var lines = src.split("\n");
    var html = "";
    var i = 0;

    function flushParagraph(buf) {
        if (buf.length === 0) return;
        // fmtInline per line: the autolink prefix (^|[\s(]) must see each
        // line start, which the "<br>" join would otherwise hide
        html += "<p>" + buf.map(function (l) { return fmtInline(l, colors); })
            .join("<br>") + "</p>";
    }

    var para = [];
    while (i < lines.length) {
        var line = lines[i];

        // placeholder-only line → emit code block directly
        var bm = line.match(/^\x00B(\d+)\x00$/);
        if (bm) {
            flushParagraph(para); para = [];
            html += blocks[parseInt(bm[1], 10)];
            i++;
            continue;
        }

        // heading
        var hm = line.match(/^(#{1,6})\s+(.*)$/);
        if (hm) {
            flushParagraph(para); para = [];
            var level = hm[1].length;
            var sizes = ["xx-large", "x-large", "large", "medium", "medium", "medium"];
            html += "<h" + level + ' style="font-size: ' + sizes[level - 1] + ";" +
                ((colors && colors.headingColor)
                    ? " color: " + colors.headingColor + ";" : "") + '">' +
                fmtInline(hm[2].trim(), colors) + "</h" + level + ">";
            i++;
            continue;
        }

        // horizontal rule
        if (/^\s*(-{3,}|\*{3,}|_{3,})\s*$/.test(line)) {
            flushParagraph(para); para = [];
            html += "<hr>";
            i++;
            continue;
        }

        // blockquote (consecutive lines)
        if (/^\s*&gt;\s?/.test(line)) {
            flushParagraph(para); para = [];
            var quote = [];
            while (i < lines.length && /^\s*&gt;\s?/.test(lines[i])) {
                quote.push(lines[i].replace(/^\s*&gt;\s?/, ""));
                i++;
            }
            html += '<blockquote style="border-left: 3px solid ' +
                ((colors && colors.blockquoteBorder) || "rgba(128,128,128,0.5)") +
                "; background-color: " +
                ((colors && colors.blockquoteBg) || "rgba(128,128,128,0.08)") + ";" +
                ((colors && colors.blockquoteText)
                    ? " color: " + colors.blockquoteText + ";" : "") +
                '; margin: 4px 0; padding: 4px 8px;">' +
                quote.map(function (l) { return fmtInline(l, colors); })
                    .join("<br>") + "</blockquote>";
            continue;
        }

        // table (header + separator + rows)
        if (line.indexOf("|") >= 0 && i + 1 < lines.length &&
            /^\s*\|?[\s:|-]+\|[\s:|-]*$/.test(lines[i + 1]) &&
            lines[i + 1].indexOf("-") >= 0) {
            flushParagraph(para); para = [];
            function cells(row) {
                return row.replace(/^\s*\|/, "").replace(/\|\s*$/, "").split("|")
                    .map(function (c) { return c.trim(); });
            }
            var head = cells(line);
            i += 2;
            var rows = [];
            while (i < lines.length && lines[i].indexOf("|") >= 0 &&
                   lines[i].trim().length > 0) {
                rows.push(cells(lines[i]));
                i++;
            }
            html += '<table width="100%" cellspacing="0" cellpadding="4" border="1"' +
                ((colors && colors.tableBorderColor)
                    ? ' bordercolor="' + colors.tableBorderColor + '"' : "") + ">" +
                "<tr" + ((colors && colors.tableHeaderBg)
                    ? ' bgcolor="' + colors.tableHeaderBg + '"' : "") + ">" +
                head.map(function (h) {
                    return "<th>" + fmtInline(h, colors) + "</th>";
                }).join("") + "</tr>";
            for (var r = 0; r < rows.length; r++) {
                html += "<tr" + ((colors && colors.tableRowAltBg && r % 2 === 1)
                    ? ' bgcolor="' + colors.tableRowAltBg + '"' : "") + ">" +
                    rows[r].map(function (c) {
                        return "<td>" + fmtInline(c, colors) + "</td>";
                    }).join("") + "</tr>";
            }
            html += "</table>";
            continue;
        }

        // lists (consecutive -/* items; "1." renders ordered)
        if (/^\s*[-*]\s+/.test(line) || /^\s*\d+\.\s+/.test(line)) {
            flushParagraph(para); para = [];
            var ordered = /^\s*\d+\.\s/.test(line);
            var items = [];
            while (i < lines.length &&
                   (ordered ? /^\s*\d+\.\s+/.test(lines[i]) : /^\s*[-*]\s+/.test(lines[i]))) {
                var item = lines[i].replace(/^\s*(?:\d+\.|[-*])\s+/, "");
                var check = item.match(/^\[([ xX])\]\s+(.*)$/);
                items.push(check
                    ? (check[1] === " " ? "\u2610 " : "\u2611 ") + fmtInline(check[2], colors)
                    : fmtInline(item, colors));
                i++;
            }
            html += (ordered ? "<ol>" : "<ul>") +
                items.map(function (it) { return "<li>" + it + "</li>"; }).join("") +
                (ordered ? "</ol>" : "</ul>");
            continue;
        }

        // blank line ends paragraph
        if (line.trim().length === 0) {
            flushParagraph(para); para = [];
            i++;
            continue;
        }

        para.push(line);
        i++;
    }
    flushParagraph(para);

    // 4. Inline code blocks that ended up inside paragraphs (rare but
    //    possible mid-stream when the fence placeholder shares a line).
    html = html.replace(/\x00B(\d+)\x00/g, function (_, idx) {
        return blocks[parseInt(idx, 10)];
    });

    return html;
}

  // ── Streaming fade tail ───────────────────────────────────────────
  // Append spanHtml inside the LAST block of html; refuses (returns
  // input unchanged) unless the anchor is a trailing block closer, so
  // mid-structure injections are impossible.

function spliceIntoLastBlock(html, spanHtml) {
    if (typeof html !== "string" || html.length === 0) return html;
    if (typeof spanHtml !== "string" || spanHtml.length === 0) return html;

    var closers = ["</p>", "</li>", "</h1>", "</h2>", "</h3>",
                   "</h4>", "</h5>", "</h6>", "</blockquote>"];
    var best = -1;
    for (var i = 0; i < closers.length; i++) {
        var idx = html.lastIndexOf(closers[i]);
        if (idx > best) best = idx;
    }
    if (best < 0) return html;

    // only closing tags / whitespace may follow the anchor
    var suffix = html.substring(best);
    if (!/^(<\/(p|li|ul|ol|blockquote|h[1-6])>\s*)+$/.test(suffix))
        return html;

    return html.substring(0, best) + spanHtml + suffix;
}
