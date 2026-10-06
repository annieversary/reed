// Executed only against an inert document, inside Reed's network-blocked WebKit shell.
// A book's chapter arrives as its files, already in the archive; anything else is a web page to find the article in.
const book = typeof chapter === "undefined" ? null : chapter;
const doc = book ? chapterDocument(book) : new DOMParser().parseFromString(html, "text/html");
doc.querySelectorAll("base").forEach(node => node.remove());
const base = doc.createElement("base");
base.href = sourceURL;
doc.head.prepend(base);
// Taken before Readability, which drops the navigation between chapters.
const navigation = book ? { title: "", links: [] } : pageLinks(doc, sourceURL);
for (const img of doc.querySelectorAll("img")) {
    const lazy = img.getAttribute("data-src") || img.getAttribute("data-original") || img.getAttribute("data-lazy-src");
    if (lazy) img.setAttribute("src", lazy);
    // Spacers and tracking pixels; Readability would count them as images and drop the tables they indent.
    else if (["width", "height"].some(name => parseFloat(img.getAttribute(name)) <= 1)) { img.remove(); continue; }
    if (!img.getAttribute("src")) {
        const source = img.getAttribute("srcset") || img.getAttribute("data-srcset") ||
            img.closest("picture")?.querySelector("source")?.getAttribute("srcset");
        const chosen = source && fromSrcset(source);
        if (chosen) img.setAttribute("src", chosen);
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
const site = book ? null : applySiteRule(doc, new URL(sourceURL), resources);
if (site?.needs) return JSON.stringify({ needs: site.needs });
let result = site;
const images = [];
if (book) result = chapterContent(doc, book, images);
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
const seen = new Map();
for (const img of book ? [] : output.querySelectorAll("img, svg image")) {
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
for (const link of book ? [] : output.querySelectorAll("a")) {
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
    wordCount: result.textContent.trim() ? result.textContent.trim().split(/\s+/).length : 0,
    images,
    page: navigation
});

// One document of a chapter's parts of files, each a section, with its links and images made absolute within the book.
function chapterDocument(book) {
    const doc = document.implementation.createHTMLDocument("");
    for (const file of book.files) {
        let source = new DOMParser().parseFromString(file.html, "application/xhtml+xml");
        if (source.querySelector("parsererror")) source = new DOMParser().parseFromString(file.html, "text/html");
        const body = source.body || source.querySelector("body");
        if (!body) continue;
        const base = bookURL(file.path);
        for (const node of body.querySelectorAll("[src], [href], [*|href]")) {
            for (const name of ["src", "href", "xlink:href"]) {
                const value = node.getAttribute(name);
                if (value === null) continue;
                node.removeAttribute(name);
                try { node.setAttribute(name === "src" ? "src" : "href", new URL(value, base).href); } catch {}
            }
        }
        const section = doc.createElement("section");
        if (file.from || file.to) section.append(doc.importNode(slice(source, body, file.from, file.to), true));
        else section.append(...Array.from(body.childNodes, node => doc.importNode(node, true)));
        doc.body.append(section);
    }
    return doc;
}

// The part of a file from the element with ID `from` to the one with ID `to`, either of which may be absent.
// An element opening its parent stands for the parent, so a chapter starting at a heading's anchor takes the heading.
function slice(source, body, from, to) {
    const opensParent = node => {
        for (let sibling = node.parentNode.firstChild; sibling !== node; sibling = sibling.nextSibling) {
            if (sibling.nodeType !== Node.TEXT_NODE || sibling.textContent.trim()) return false;
        }
        return true;
    };
    const element = id => {
        let node = id ? source.getElementById(id) : null;
        while (node && node.parentNode && node.parentNode !== body && opensParent(node)) node = node.parentNode;
        return node;
    };
    const range = source.createRange();
    range.selectNodeContents(body);
    const start = element(from), end = element(to);
    if (start) range.setStartBefore(start);
    if (end) range.setEndBefore(end);
    return range.cloneContents();
}

function bookURL(path) {
    return "epub:///" + path.split("/").map(encodeURIComponent).join("/");
}

// The path within the book that an absolute book URL points to.
function bookPath(url) {
    // A malformed escape is left as written, rather than failing the whole book.
    const decode = part => { try { return decodeURIComponent(part); } catch { return part; } };
    return url.pathname.slice(1).split("/").map(decode).join("/");
}

// The chapter as Readability would give an article. Images are named after their place in the book, so a version's
// chapters can share them, and links to other chapters point at their saved files.
function chapterContent(doc, book, images) {
    // A drop cap drawn as a picture of its letter is the letter, so the word reads and is heard whole.
    for (const img of doc.querySelectorAll("img[alt]")) {
        if (/^\p{L}$/u.test(img.getAttribute("alt"))) img.replaceWith(img.getAttribute("alt"));
    }
    for (const img of doc.querySelectorAll("img, image")) {
        const attribute = img.localName === "img" ? "src" : "href";
        let url;
        try { url = new URL(img.getAttribute(attribute)); } catch { img.remove(); continue; }
        if (url.protocol !== "epub:") { img.remove(); continue; }
        const path = bookPath(url);
        const filename = bookImageName(path);
        if (!images.some(image => image.filename === filename)) {
            images.push({ url: path, filename, alt: img.getAttribute("alt") || img.getAttribute("aria-label") || "" });
        }
        img.setAttribute(attribute, filename);
    }
    for (const link of doc.querySelectorAll("a[href]")) {
        let url;
        try { url = new URL(link.getAttribute("href")); } catch { link.removeAttribute("href"); continue; }
        if (["https:", "http:"].includes(url.protocol)) continue;
        const target = url.protocol === "epub:" ? book.links[bookPath(url)] : undefined;
        if (target === undefined) link.removeAttribute("href");
        else if (target === book.index) {
            if (url.hash) link.setAttribute("href", url.hash); else link.removeAttribute("href");
        } else link.setAttribute("href", target + ".html" + url.hash);
    }
    // The reader shows the chapter's title above it, so the same heading opening the text would repeat it.
    const normalize = text => text.replace(/\s+/g, " ").trim().toLowerCase();
    const heading = doc.body.querySelector("h1, h2, h3, h4, h5, h6");
    let headingText = "", named = "";
    if (heading) {
        headingText = heading.textContent.replace(/\s+/g, " ").trim();
        // An illustration's caption may share the heading; the chapter's name is the rest.
        const bare = heading.cloneNode(true);
        bare.querySelectorAll(".caption").forEach(caption => caption.remove());
        named = bare.textContent.replace(/\s+/g, " ").trim();
    }
    let title = book.title || named;
    if (named && (normalize(title) === normalize(headingText) || normalize(title).endsWith(" " + normalize(named)))) title = named;
    if (heading && [headingText, named].some(text => text && normalize(text) === normalize(book.title || title))) {
        // Its illustration stays, with its caption.
        const pictures = Array.from(heading.querySelectorAll("img, svg"));
        const caption = Array.from(heading.querySelectorAll(".caption"), node => node.textContent.trim()).join(" ");
        if (pictures.length) {
            const figure = doc.createElement("figure");
            figure.append(...pictures);
            if (caption) {
                const text = doc.createElement("figcaption");
                text.textContent = caption;
                figure.append(text);
            }
            heading.replaceWith(figure);
        } else heading.remove();
    }
    const textContent = doc.body.textContent;
    return { title: title || "Chapter " + (book.index + 1), byline: null, content: doc.body.innerHTML, textContent };
}

// A name for an image file in a saved book, from its path in the archive.
function bookImageName(path) {
    return "book-" + path.replace(/[^A-Za-z0-9.-]/g, "_");
}

// The sharpest picture in a srcset that isn't needlessly large: the widest up to 1600 pixels, or densest up to 2x,
// else the smallest. Its URLs may hold commas, as image services' often do; a comma ending one, or one before a
// candidate's descriptor ends, separates candidates.
function fromSrcset(srcset) {
    const candidates = [];
    let rest = srcset.trim();
    while (rest) {
        let url = rest.match(/^\S+/)[0];
        rest = rest.slice(url.length);
        let descriptor = "";
        if (/,$/.test(url)) url = url.replace(/,+$/, "");
        else [, descriptor, rest] = rest.match(/^\s*([^,]*),?([\s\S]*)$/);
        rest = rest.trimStart();
        const size = descriptor.match(/^([\d.]+)([wx])$/i);
        candidates.push({ url, width: size ? parseFloat(size[1]) * (size[2].toLowerCase() === "x" ? 800 : 1) : 0 });
    }
    const fitting = candidates.filter(candidate => candidate.width <= 1600).sort((a, b) => b.width - a.width);
    return (fitting[0] ?? candidates.sort((a, b) => a.width - b.width)[0])?.url;
}
