// Executed only against an inert document, inside Reed's network-blocked WebKit shell.
const doc = new DOMParser().parseFromString(html, "text/html");
doc.querySelectorAll("base").forEach(node => node.remove());
const base = doc.createElement("base");
base.href = sourceURL;
doc.head.prepend(base);
for (const img of doc.querySelectorAll("img")) {
    const lazy = img.getAttribute("data-src") || img.getAttribute("data-original") || img.getAttribute("data-lazy-src");
    if (lazy) img.setAttribute("src", lazy);
    if (!img.getAttribute("src")) {
        const source = img.getAttribute("srcset") || img.getAttribute("data-srcset") ||
            img.closest("picture")?.querySelector("source")?.getAttribute("srcset");
        if (source) img.setAttribute("src", source.split(",")[0].trim().split(/\s+/)[0]);
    }
}
const site = applySiteRule(doc, new URL(sourceURL), resources);
if (site?.needs) return JSON.stringify({ needs: site.needs });
let result = site;
if (!result) {
    result = new Readability(doc, { maxElemsToParse: 60000 }).parse();
    if (!result || !result.textContent || result.textContent.trim().length < 100) return null;
}
const clean = DOMPurify.sanitize(result.content, {
    ALLOWED_TAGS: ["p", "div", "section", "article", "h1", "h2", "h3", "h4", "h5", "h6", "a", "img", "figure", "figcaption", "picture", "blockquote", "pre", "code", "ul", "ol", "li", "dl", "dt", "dd", "table", "thead", "tbody", "tfoot", "tr", "td", "th", "caption", "strong", "em", "b", "i", "u", "s", "sub", "sup", "br", "hr", "span", "time", "abbr"],
    ALLOWED_ATTR: ["href", "src", "alt", "title", "colspan", "rowspan", "start", "dir"],
    ALLOW_DATA_ATTR: false
});
const output = new DOMParser().parseFromString(clean, "text/html");
// Readability may retain a standalone byline even though we display it in the reader header.
const firstParagraph = output.querySelector("p");
if (result.byline && firstParagraph?.textContent.trim() === result.byline.trim()) firstParagraph.remove();
const excerpt = site?.excerpt || Array.from(output.querySelectorAll("p")).map(p => p.textContent.trim()).find(text => text.length > 80)
    || result.excerpt || result.textContent.trim();
const images = [];
const seen = new Map();
for (const img of output.querySelectorAll("img")) {
    let url;
    try { url = new URL(img.getAttribute("src"), sourceURL); } catch { img.remove(); continue; }
    if (!["https:", "http:"].includes(url.protocol)) { img.remove(); continue; }
    let filename = seen.get(url.href);
    if (!filename) {
        filename = "image-" + images.length;
        seen.set(url.href, filename);
        images.push({ url: url.href, filename, alt: img.getAttribute("alt") || "" });
    }
    img.setAttribute("src", filename);
}
for (const link of output.querySelectorAll("a")) {
    const href = link.getAttribute("href");
    if (!href) continue;
    try {
        const url = new URL(href, sourceURL);
        if (["https:", "http:"].includes(url.protocol)) link.setAttribute("href", url.href);
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
    images
});
