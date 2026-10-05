// The page's title and links, each with what it says and how it relates to the page, for finding the chapters around it.
function pageLinks(doc, sourceURL) {
    const links = [];
    for (const node of doc.querySelectorAll("a[href], link[href][rel]")) {
        const rel = (node.getAttribute("rel") || "").toLowerCase();
        if (node.localName === "link" && !/\b(next|prev|previous|contents|toc|index)\b/.test(rel)) continue;
        let url;
        try { url = new URL(node.getAttribute("href"), sourceURL); } catch { continue; }
        if (!["https:", "http:"].includes(url.protocol)) continue;
        url.hash = "";
        // Buttons drawn as arrows or icons say what they are in their label or image.
        const text = node.localName === "a" ? node.textContent.trim() || node.getAttribute("aria-label") || node.getAttribute("title")
            || node.querySelector("img[alt]")?.getAttribute("alt") || "" : "";
        links.push({ url: url.href, text: text.replace(/\s+/g, " ").trim().slice(0, 200), rel });
        if (links.length >= 5000) break;
    }
    return { title: (doc.title || "").replace(/\s+/g, " ").trim(), links };
}
