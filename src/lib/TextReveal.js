.pragma library
// Word-aligned reveal helper for MessageBubble's streaming fade.
// A fade must start once per complete word: if the reveal cuts
// mid-word, the next batch's fade anchor walks back into the shown
// fragment and re-dims it — the word blinks. cut() answers "how far
// may this reveal tick safely advance?" so cuts always land just
// past a whitespace boundary.

// Reveal end-index for `text`, advancing from offset `from` with a
// per-tick cap of `cap` chars. Scans the window
// [from, min(text.length, from + cap)) for the LAST whitespace and
// returns the index just past it (that word is complete). No
// whitespace in the window and the window reaches the text's end →
// return `from`: the trailing word is still incomplete, hold it. No
// whitespace but text continues past the cap → return the window end
// (escape valve: a >cap non-space run, e.g. a long URL or minified
// code, must still stream rather than stall the UI).
function cut(text, from, cap) {
    var end = Math.min(text.length, from + cap);
    for (var i = end - 1; i >= from; i--)
        if (/\s/.test(text[i])) return i + 1;
    return end === text.length ? from : end;
}
