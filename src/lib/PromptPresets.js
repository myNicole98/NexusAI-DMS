.pragma library

// System-prompt personality presets. "Serious" is the default
// personality (fresh installs start with it); "custom" means the
// user wrote their own prompt in the box.

var PRESETS = [
    { id: "serious", name: "Serious",
      text: "You are a helpful and professional assistant. Maintain a serious tone, provide concise responses, and avoid using emojis or excessive emphasis" },
    { id: "playful", name: "Playful",
      text: "Deliver accurate knowledge with whimsical enthusiasm; maintain a lighthearted, engaging conversational tone." },
    { id: "socratic", name: "Socratic Teacher",
      text: "Never provide direct answers; guide the user toward self-discovery using only probing questions and logical inquiry." },
    { id: "engineer", name: "Engineer",
      text: "Maintain maximum objectivity; structure all responses systematically using precise inputs, processes, and defined outputs." },
    { id: "custom", name: "Custom", text: "" }
];

function textFor(id) {
    for (var i = 0; i < PRESETS.length; i++)
        if (PRESETS[i].id === id) return PRESETS[i].text;
    return "";
}

// Which preset does this prompt correspond to? Exact (trimmed) match
// → that preset; empty → serious (the default personality);
// anything else → custom.
function detect(text) {
    var t = String(text || "").trim();
    if (!t) return "serious";
    for (var i = 0; i < PRESETS.length; i++)
        if (PRESETS[i].text && PRESETS[i].text === t) return PRESETS[i].id;
    return "custom";
}

// The activity-line convention, appended whenever tools are live: the
// client routes these tags into the chat's status row and strips them from
// the answer, so the model must treat them as a status channel, not prose.
function narrationInstruction() {
    return "Before each tool call and whenever your work changes direction, emit one\n"
        + "short status line in <narrate>…</narrate>: plain text, under 80 characters,\n"
        + "no markdown, no tool names in backticks. It is a status for the user, never\n"
        + "part of your answer. Those tags are reserved; do not use them inside code\n"
        + "blocks.";
}
