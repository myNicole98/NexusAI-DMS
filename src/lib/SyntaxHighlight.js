.pragma library

// Tiny multi-language syntax highlighter producing Qt rich-text spans.
// Tokenizes raw code, escapes each chunk, wraps matches in color spans.

var KEYWORDS = {
    js: "const let var function return if else for while do switch case break continue new class extends import from export default try catch finally throw typeof instanceof in of await async yield null undefined true false this super static get set",
    ts: "const let var function return if else for while do switch case break continue new class extends implements interface type enum import from export default try catch finally throw typeof instanceof in of await async yield null undefined true false this super static readonly public private protected as",
    python: "def return if elif else for while break continue class import from as pass raise try except finally with lambda global nonlocal yield assert del in is not and or None True False self async await match case",
    bash: "if then else elif fi for while do done case esac function return in local export readonly declare unset shift source alias echo exit read cd set trap",
    json: "true false null",
    c: "if else for while do switch case break continue return struct enum union typedef static const void int char float double long short unsigned signed sizeof goto extern inline volatile default",
    cpp: "if else for while do switch case break continue return struct enum union typedef static const void int char float double long short unsigned signed sizeof goto extern inline virtual override public private protected class new delete template typename namespace using try catch throw nullptr true false auto constexpr",
    rust: "fn let mut const if else match for while loop break continue return struct enum impl trait pub use mod crate self super where async await move ref static type unsafe dyn true false Some None Ok Err",
    go: "func var const if else for range switch case break continue return struct interface map chan go defer select package import type nil true false"
};

var ALIAS = { javascript: "js", jsx: "js", tsx: "ts", typescript: "ts",
              py: "python", python3: "python", sh: "bash", shell: "bash",
              zsh: "bash", console: "bash", "c++": "cpp", "c++11": "cpp",
              golang: "go", rs: "rust", htm: "html", xhtml: "html" };

// Markup: tag-aware tokenizer (keyword regex can't express it).
var MARKUP = { html: true, xml: true, svg: true };

function esc(s) {
    return s.replace(/&/g, "&amp;").replace(/</g, "&lt;")
            .replace(/>/g, "&gt;").replace(/"/g, "&quot;");
}

function span(color, text) {
    if (!color) return esc(text);
    return '<span style="color: ' + color + ';">' + esc(text) + "</span>";
}

// Attributes inside a tag.
function highlightAttrs(s, palette) {
    var re = /([A-Za-z_][\w:.-]*)(\s*=\s*)("[^"]*"|'[^']*'|[^\s">]+)?/g;
    var out = "";
    var last = 0;
    var m;
    while ((m = re.exec(s)) !== null) {
        out += esc(s.substring(last, m.index));
        out += span(palette.type, m[1]);
        out += esc(m[2]);
        if (m[3] !== undefined) out += span(palette.string, m[3]);
        last = m.index + m[0].length;
    }
    out += esc(s.substring(last));
    return out;
}

// HTML/XML/SVG tokenizer.
function highlightHtml(code, palette) {
    palette = palette || {};
    var re = /(<!--[\s\S]*?-->)|(<!DOCTYPE[^>]*>)|(<\/?)([A-Za-z][\w:.-]*)((?:\s+[A-Za-z_][\w:.-]*(?:\s*=\s*(?:"[^"]*"|'[^']*'|[^\s">]+))?)*)(\/?>)/gi;
    var out = "";
    var last = 0;
    var m;
    while ((m = re.exec(code)) !== null) {
        out += esc(code.substring(last, m.index));
        if (m[1] !== undefined) {
            out += span(palette.comment, m[1]);
        } else if (m[2] !== undefined) {
            out += span(palette.comment, m[2]);
        } else {
            out += esc(m[3]);
            out += span(palette.keyword, m[4]);
            if (m[5]) out += highlightAttrs(m[5], palette);
            out += esc(m[6]);
        }
        last = m.index + m[0].length;
    }
    out += esc(code.substring(last));
    return out;
}

// One combined regex pass, longest-priority tokens first.
function highlightCode(code, lang, palette) {
    if (typeof code !== "string") return "";
    code = code.replace(/[\x00\x01]/g, "");
    palette = palette || {};
    var l = String(lang || "").toLowerCase();
    l = ALIAS[l] || l;

    if (MARKUP[l]) return highlightHtml(code, palette);

    var keywords = KEYWORDS[l];

    if (!keywords) {
        // Known structural languages with no keyword set, or unknown:
        // highlight nothing but escape everything.
        return esc(code);
    }

    var re = new RegExp(
        "(\\/\\*[\\s\\S]*?\\*\\/|\\/\\/[^\\n]*|#[^\\n]*)" +      // 1 comments (//, /* */, #)
        "|(\"(?:\\\\.|[^\"\\\\\\n])*\"|'(?:\\\\.|[^'\\\\\\n])*'|`(?:\\\\.|[^`\\\\])*`)" + // 2 strings
        "|\\b(\\d+(?:\\.\\d+)?)\\b" +                              // 3 numbers
        "|\\b(" + keywords.trim().split(/\s+/).join("|") + ")\\b" + // 4 keywords
        "|\\b([A-Za-z_][A-Za-z0-9_]*)(?=\\s*\\()",                 // 5 function calls
        "g"
    );

    var out = "";
    var last = 0;
    var m;
    while ((m = re.exec(code)) !== null) {
        out += esc(code.substring(last, m.index));
        if (m[1] !== undefined) out += span(palette.comment, m[1]);
        else if (m[2] !== undefined) out += span(palette.string, m[2]);
        else if (m[3] !== undefined) out += span(palette.number, m[3]);
        else if (m[4] !== undefined) out += span(palette.keyword, m[4]);
        else if (m[5] !== undefined) out += span(palette["function"], m[5]);
        last = m.index + m[0].length;
    }
    out += esc(code.substring(last));
    return out;
}
