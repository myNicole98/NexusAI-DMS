.pragma library

// Fuzzy model-search matcher: case-insensitive subsequence test with
// whitespace stripped from both sides, so "gpt4o" and "gpt 4o" both
// match "gpt-4o", "c45" matches "claude-sonnet-4-5", and plain
// substrings keep working. Pure JS — must stay node-testable.

function matches(query, target) {
    if (typeof query !== "string" || typeof target !== "string")
        return false;
    var q = query.replace(/\s+/g, "").toLowerCase();
    if (q.length === 0) return true;   // no filter → everything passes
    var t = target.replace(/\s+/g, "").toLowerCase();
    var i = 0;
    for (var j = 0; j < t.length && i < q.length; j++)
        if (t.charCodeAt(j) === q.charCodeAt(i)) i++;
    return i === q.length;
}
