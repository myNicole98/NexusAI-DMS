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
// Scripts that never put spaces between words (CJK, kana, Thai, Lao,
// Khmer, Myanmar) can never complete a word at whitespace — a run
// containing them is revealed as it arrives instead of held; their
// fade is anchored-away upstream and renders un-faded.
var SPACELESS = /[\u3000-\u303f\u3040-\u30ff\u3400-\u4dbf\u4e00-\u9fff\uf900-\ufaff\uff01-\uff5e\uff61-\uff9f\u0e00-\u0e7f\u0e80-\u0eff\u1000-\u109f\u1780-\u17ff]/;
function cut(text, from, cap) {
    var end = Math.min(text.length, from + cap);
    var lastWs = -1;
    for (var i = end - 1; i >= from; i--)
        if (/\s/.test(text[i])) { lastWs = i; break; }
    if (lastWs < 0) {
        if (SPACELESS.test(text.substring(from, end))) return end;
        return end === text.length ? from : end;
    }
    if (SPACELESS.test(text.substring(lastWs + 1, end))) return end;
    return lastWs + 1;
}
