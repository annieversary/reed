// Executed only against an inert document, inside Reed's network-blocked WebKit shell.
const doc = new DOMParser().parseFromString(html, "text/html");
doc.querySelectorAll("base").forEach(node => node.remove());
const base = doc.createElement("base");
base.href = sourceURL;
doc.head.prepend(base);
// Taken before Readability, which drops the navigation between chapters.
const navigation = pageLinks(doc, sourceURL);
for (const img of doc.querySelectorAll("img")) {
    const lazy = img.getAttribute("data-src") || img.getAttribute("data-original") || img.getAttribute("data-lazy-src");
    if (lazy) img.setAttribute("src", lazy);
    // Spacers and tracking pixels; Readability would count them as images and drop the tables they indent.
    else if (["width", "height"].some(name => parseFloat(img.getAttribute(name)) <= 1)) { img.remove(); continue; }
    if (!img.getAttribute("src")) {
        const source = img.getAttribute("srcset") || img.getAttribute("data-srcset") ||
            img.closest("picture")?.querySelector("source")?.getAttribute("srcset");
        if (source) img.setAttribute("src", source.split(",")[0].trim().split(/\s+/)[0]);
    }
}
// Older ways of marking monospaced text become code, which the reader keeps.
for (const node of doc.querySelectorAll("tt, kbd, samp")) {
    const code = doc.createElement("code");
    code.append(...node.childNodes);
    node.replaceWith(code);
}
prepareMath(doc);
// Readability drops what's hidden from screen readers, which includes the keys to charts; icons are dropped later.
doc.querySelectorAll('svg[aria-hidden="true"]').forEach(svg => svg.removeAttribute("aria-hidden"));
const site = applySiteRule(doc, new URL(sourceURL), resources);
if (site?.needs) return JSON.stringify({ needs: site.needs });
let result = site;
if (!result) {
    result = new Readability(doc, { maxElemsToParse: 60000 }).parse();
    if (!result || !result.textContent || result.textContent.trim().length < 100) return null;
}
const clean = DOMPurify.sanitize(result.content, {
    ALLOWED_TAGS: ["p", "div", "section", "article", "h1", "h2", "h3", "h4", "h5", "h6", "a", "img", "figure", "figcaption", "picture", "blockquote", "pre", "code", "ul", "ol", "li", "dl", "dt", "dd", "table", "thead", "tbody", "tfoot", "tr", "td", "th", "caption", "strong", "em", "b", "i", "u", "s", "sub", "sup", "br", "hr", "span", "time", "abbr",
        "math", "mrow", "mi", "mn", "mo", "ms", "mtext", "mspace", "msup", "msub", "msubsup", "mfrac", "msqrt", "mroot",
        "mover", "munder", "munderover", "mtable", "mtr", "mtd", "mstyle", "mpadded", "mphantom", "menclose", "mmultiscripts", "mprescripts",
        "svg", "g", "path", "circle", "ellipse", "line", "polyline", "polygon", "rect", "text", "tspan", "defs", "use", "symbol",
        "lineargradient", "radialgradient", "stop", "clippath", "mask", "marker", "pattern", "title", "desc", "image"],
    ALLOWED_ATTR: ["href", "id", "name", "src", "alt", "title", "colspan", "rowspan", "start", "dir",
        "display", "alttext", "mathvariant", "stretchy", "fence", "separator", "accent", "accentunder", "movablelimits",
        "lspace", "rspace", "largeop", "symmetric", "minsize", "maxsize", "linethickness", "scriptlevel", "displaystyle",
        "columnalign", "columnspan", "rowspacing", "columnspacing", "form", "notation", "width", "height", "depth", "voffset",
        "viewbox", "preserveaspectratio", "d", "points", "transform", "x", "y", "x1", "y1", "x2", "y2", "cx", "cy", "r", "rx", "ry",
        "fx", "fy", "dx", "dy", "fill", "fill-opacity", "fill-rule", "clip-rule", "stroke", "stroke-width", "stroke-opacity",
        "stroke-dasharray", "stroke-dashoffset", "stroke-linecap", "stroke-linejoin", "stroke-miterlimit", "opacity", "visibility",
        "offset", "stop-color", "stop-opacity", "gradientunits", "gradienttransform", "spreadmethod", "clip-path", "clippathunits",
        "mask", "maskunits", "marker-start", "marker-mid", "marker-end", "markerwidth", "markerheight", "markerunits", "refx", "refy",
        "orient", "patternunits", "patterntransform", "font-size", "font-family", "font-weight", "font-style", "text-anchor",
        "dominant-baseline", "alignment-baseline", "letter-spacing", "textlength", "lengthadjust", "vector-effect", "role", "aria-label"],
    ALLOW_DATA_ATTR: false
});
const output = new DOMParser().parseFromString(clean, "text/html");
const ink = document.createElement("canvas").getContext("2d");
// Whether a colour is more than a shade of grey; a drawing that isn't transparent or white counts.
function isColoured(value) {
    if (!value || value === "none" || value === "transparent") return false;
    if (value.startsWith("url(")) return true;
    ink.fillStyle = "#000";
    ink.fillStyle = value;
    const style = ink.fillStyle;
    const [r, g, b, a = 1] = style.startsWith("#") ? [1, 3, 5].map(i => parseInt(style.slice(i, i + 2), 16)) : style.match(/[\d.]+/g).map(Number);
    return a > 0 && Math.max(r, g, b) - Math.min(r, g, b) > 30;
}
for (const svg of output.querySelectorAll("svg")) {
    const nodes = [svg, ...svg.querySelectorAll("*")];
    // A colour from the page's stylesheet, which isn't kept, falls back to the one it names, or to the default.
    for (const node of nodes) {
        for (const attribute of Array.from(node.attributes)) {
            if (!attribute.value.includes("var(")) continue;
            const fallback = attribute.value.match(/^\s*var\(\s*--[\w-]+\s*,\s*(.+)\)\s*$/)?.[1];
            if (fallback && !fallback.includes("var(")) node.setAttribute(attribute.name, fallback);
            else node.removeAttribute(attribute.name);
        }
    }
    // Small drawings in greys are icons, drawn in the colour of the text; small coloured ones, like a chart's key, stay.
    const size = Math.max(parseFloat(svg.getAttribute("width")) || 0, parseFloat(svg.getAttribute("height")) || 0);
    const small = size > 0 && size <= 32 && !svg.parentElement?.closest("svg");
    if (small && !nodes.some(node => ["fill", "stroke", "stop-color"].some(property => isColoured(node.getAttribute(property))))) svg.remove();
}
// Readability may retain a standalone byline even though we display it in the reader header.
const firstParagraph = output.querySelector("p");
if (result.byline && firstParagraph?.textContent.trim() === result.byline.trim()) firstParagraph.remove();
const excerpt = site?.excerpt || Array.from(output.querySelectorAll("p")).map(p => textWithFormulas(p).trim()).find(text => text.length > 80)
    || result.excerpt || result.textContent.trim();
for (const node of output.querySelectorAll("svg use, svg image")) {
    const href = node.getAttribute("href") || node.getAttribute("xlink:href");
    node.removeAttribute("xlink:href");
    if (href) node.setAttribute("href", href);
    // Symbols are drawn from within the article; other files aren't fetched.
    if (node.localName === "use" && !href?.startsWith("#")) node.remove();
}
const images = [];
const seen = new Map();
for (const img of output.querySelectorAll("img, svg image")) {
    const attribute = img.localName === "img" ? "src" : "href";
    let url;
    try { url = new URL(img.getAttribute(attribute), sourceURL); } catch { img.remove(); continue; }
    if (!["https:", "http:"].includes(url.protocol)) { img.remove(); continue; }
    let filename = seen.get(url.href);
    if (!filename) {
        // Offline, WebKit types images by extension, and renders SVG only when typed as such.
        filename = "image-" + images.length + (/\.svg$/i.test(url.pathname) ? ".svg" : "");
        seen.set(url.href, filename);
        images.push({ url: url.href, filename, alt: img.getAttribute("alt") || img.getAttribute("aria-label") || "" });
    }
    img.setAttribute(attribute, filename);
}
for (const link of output.querySelectorAll("a")) {
    const href = link.getAttribute("href");
    if (!href) continue;
    try {
        const url = new URL(href, sourceURL);
        const page = new URL(sourceURL);
        if (url.hash && url.origin + url.pathname + url.search === page.origin + page.pathname + page.search) link.setAttribute("href", url.hash);
        else if (["https:", "http:"].includes(url.protocol)) link.setAttribute("href", url.href);
        else link.removeAttribute("href");
    } catch { link.removeAttribute("href"); }
}
return JSON.stringify({
    title: result.title || new URL(sourceURL).hostname,
    author: result.byline || null,
    publishedAt: Date.parse(result.publishedTime) || null,
    excerpt: excerpt.slice(0, 280),
    html: output.body.innerHTML,
    wordCount: result.textContent.trim().split(/\s+/).length,
    images,
    page: navigation
});
