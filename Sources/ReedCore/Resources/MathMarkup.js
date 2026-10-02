// Brings a page's formulas to one form before extraction: MathML, with its TeX source in `alttext` and
// nothing else beside it. Rendered math (KaTeX, MathJax 3, Wikipedia) carries MathML for assistive
// technology, kept in place of its visual copy; TeX left for MathJax or KaTeX to render in the browser
// is converted with Temml.

function prepareMath(doc) {
    for (const katex of doc.querySelectorAll(".katex")) {
        const math = katex.querySelector(".katex-mathml math");
        if (math) replaceWithFormula(katex.closest(".katex-display") || katex, math, !!katex.closest(".katex-display"));
    }
    for (const container of doc.querySelectorAll("mjx-container")) {
        const math = container.querySelector("mjx-assistive-mml math");
        if (math) replaceWithFormula(container, math, container.getAttribute("display") === "true");
    }
    for (const element of doc.querySelectorAll(".mwe-math-element")) {
        const math = element.querySelector("math");
        if (math) replaceWithFormula(element, math, math.getAttribute("display") === "block");
    }
    doc.querySelectorAll(".MathJax_Preview").forEach(node => node.remove());
    for (const script of doc.querySelectorAll('script[type^="math/tex"]')) {
        const math = renderTeX(doc, script.textContent, /mode\s*=\s*display/.test(script.type));
        if (math) script.replaceWith(math);
    }
    const scripts = Array.from(doc.querySelectorAll("script:not([src])"), script => script.textContent).join("\n");
    const rendersTeX = Array.from(doc.querySelectorAll("script[src], link[href]"))
        .some(node => /mathjax|katex/i.test(node.getAttribute("src") || node.getAttribute("href")))
        || /MathJax|renderMathInElement/.test(scripts);
    // A lone $ is a delimiter only where the page says so, since it's usually a price.
    const dollars = /inlineMath[\s\S]{0,200}?['"]\$['"]\s*,\s*['"]\$['"]|left\s*:\s*['"]\$['"]\s*,\s*right\s*:\s*['"]\$['"]/.test(scripts);
    if (rendersTeX) convertDelimitedTeX(doc, doc.body, dollars);
    // arXiv marks the text its MathJax renders, with $ delimiters.
    for (const element of doc.querySelectorAll(".mathjax")) convertDelimitedTeX(doc, element, true);
    tidyMathML(doc);
}

// TeX source into `alttext`, and annotations and their `semantics` wrapper out, so only the formula remains.
function tidyMathML(root) {
    for (const math of root.querySelectorAll("math")) {
        const tex = math.querySelector('annotation[encoding="application/x-tex"]')?.textContent.trim();
        if (tex && !math.hasAttribute("alttext")) math.setAttribute("alttext", tex);
    }
    root.querySelectorAll("math annotation, math annotation-xml").forEach(node => node.remove());
    root.querySelectorAll("math semantics").forEach(node => node.replaceWith(...node.childNodes));
}

// An element's text, with each formula as its TeX source.
function textWithFormulas(node) {
    const copy = node.cloneNode(true);
    copy.querySelectorAll("math").forEach(math => math.replaceWith(math.getAttribute("alttext") || math.textContent));
    return copy.textContent;
}

function replaceWithFormula(node, math, display) {
    if (display) math.setAttribute("display", "block");
    node.replaceWith(math);
}

function renderTeX(doc, tex, display) {
    let markup;
    try { markup = temml.renderToString(tex.trim(), { displayMode: display, throwOnError: true }); } catch { return null; }
    const math = doc.importNode(new DOMParser().parseFromString(markup, "text/html").querySelector("math"), true);
    math.setAttribute("alttext", tex.trim());
    return math;
}

function convertDelimitedTeX(doc, root, dollars) {
    // Delimited as MathJax and KaTeX find them, which is what the page was written for.
    const delimiters = new RegExp(String.raw`\$\$([\s\S]+?)\$\$|\\\[([\s\S]+?)\\\]|\\\(([\s\S]+?)\\\)` +
        (dollars ? String.raw`|(?<![\\$])\$((?:\\\$|[^$])+?)\$` : ""), "g");
    const walker = doc.createTreeWalker(root, NodeFilter.SHOW_TEXT, {
        acceptNode: node => node.parentElement.closest("pre, code, kbd, samp, script, style, textarea, math")
            ? NodeFilter.FILTER_REJECT : NodeFilter.FILTER_ACCEPT
    });
    const nodes = [];
    for (let node; (node = walker.nextNode());) if (/[$\\]/.test(node.data)) nodes.push(node);
    for (const node of nodes) {
        const parts = [];
        let last = 0;
        for (const match of node.data.matchAll(delimiters)) {
            const [source, displayDollars, displayBrackets, inline, inlineDollars] = match;
            const math = renderTeX(doc, displayDollars ?? displayBrackets ?? inline ?? inlineDollars, !!(displayDollars ?? displayBrackets));
            if (!math) continue;
            parts.push(node.data.slice(last, match.index), math);
            last = match.index + source.length;
        }
        if (!parts.length) continue;
        parts.push(node.data.slice(last));
        node.replaceWith(...parts);
    }
}
