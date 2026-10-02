// Gives each formula in `html` an `aria-label` with ClearSpeak's reading of it, for narration.
// Runs after extraction, with Speech Rule Engine loaded and its English rules in `mathMaps`.
const started = performance.now();
const doc = new DOMParser().parseFromString(html, "text/html");
const formulas = Array.from(doc.querySelectorAll("math"));
if (!formulas.length) return html;
await SRE.setupEngine({ locale: "en", domain: "clearspeak", modality: "speech",
                        custom: locale => Promise.resolve(mathMaps[locale.replace(/\.json$/, "")]) });
await SRE.engineReady();

const scripts = ["msub", "msup", "msubsup"];
// What a group starts or ends with, looking into nested groups.
const leading = node => {
    while (node && ["mrow", ...scripts].includes(node.localName)) node = node.firstElementChild;
    return node;
};
const trailing = node => {
    while (node?.localName === "mrow") node = node.lastElementChild;
    return node;
};
const isName = node => ["mi", "mtext", ...scripts].includes(node?.localName) && ["mi", "mtext"].includes(leading(node).localName);
const isOpening = node => node?.localName === "mo" && node.textContent.trim() === "(";
// LaTeXML writes f(x) with the same invisible operator as a product, or with none, so it's read as
// "f times x". A name followed by a parenthesis is taken to be a function applied to its argument.
const markFunctions = math => {
    for (const operator of Array.from(math.querySelectorAll("mo"))) {
        // A slash through a relation, as in ≠, is read only when it's composed into one character.
        operator.textContent = operator.textContent.normalize("NFC");
        if (/^[\u200b\u2062]$/.test(operator.textContent)) {
            if (isName(trailing(operator.previousElementSibling)) && isOpening(leading(operator.nextElementSibling))) operator.textContent = "\u2061";
        } else if (isOpening(operator)) {
            let group = operator;
            while (group.parentElement && ["mrow", ...scripts].includes(group.parentElement.localName) && group.parentElement.firstElementChild === group) group = group.parentElement;
            if (isName(trailing(group.previousElementSibling))) {
                const apply = doc.createElementNS(math.namespaceURI, "mo");
                apply.textContent = "\u2061";
                group.before(apply);
            }
        }
    }
    return math;
};
const tidy = speech => speech
    // Marks SRE doesn't read, like a slash through a relation with no composed form, would cling to the space before.
    .replace(/(^|\s)\p{M}+/gu, "$1")
    .replace(/\bnormal script l\b/g, "ell")
    .replace(/\bnormal (?=\S)/g, "")
    .replace(/\bitalic d\b/g, "d")
    .replace(/\bthe metric of\b/g, "the norm of")
    .replace(/\braised to the down tack power\b/g, "transpose")
    .replace(/\bdown tack\b/g, "transpose")
    // Powers of the number sets, as in "r-n" for R to the n.
    .replace(/\b([rzqnc])-(?!th\b)(\S+)/g, (_, set, power) => `${set.toUpperCase()} to the ${power}`);

const speak = math => {
    try { return tidy(SRE.toSpeech(markFunctions(math.cloneNode(true)).outerHTML)).trim(); } catch { return ""; }
};
for (const math of formulas) {
    // Formulas left unlabelled fall back to being read only when they're plain text.
    if (performance.now() - started > 15000) break;
    let speech = speak(math);
    // SRE gives up on some multi-line layouts, which can still be read a cell at a time.
    if (!speech) {
        speech = Array.from(math.querySelectorAll("mtd"), cell => {
            const part = doc.createElementNS(math.namespaceURI, "math");
            part.append(...cell.cloneNode(true).childNodes);
            return speak(part);
        }).filter(Boolean).join(", ");
    }
    if (speech) math.setAttribute("aria-label", speech);
}
return doc.body.innerHTML;
