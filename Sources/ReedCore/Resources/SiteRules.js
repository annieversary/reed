// Pages Readability handles poorly, picked out by hand. A rule whose `matches(doc, url)` is true
// returns from `extract(doc, url, resources)` either:
//   { title, description?, excerpt?, content: [Node] } — used instead of Readability's guess;
//   { needs: [url] }  — same-origin JSON or HTML to fetch first; the extraction then runs again
//                       with each response text in `resources[url]`;
//   null              — fall back to Readability.
const meta = (doc, key) =>
    doc.querySelector(`meta[property="${key}"], meta[name="${key}"]`)?.getAttribute("content")?.trim() || null;
const text = node => node?.textContent.trim() || null;
const first = (doc, ...selectors) => selectors.map(selector => doc.querySelector(selector)).find(Boolean) || null;
const pathParts = url => url.pathname.split("/").filter(Boolean);

const siteRules = [
    {
        name: "GitHub repository",
        matches: (_, url) => url.hostname === "github.com" &&
            (pathParts(url).length === 2 || pathParts(url)[2] === "tree"),
        extract(doc, url) {
            const readme = doc.querySelector("article.markdown-body");
            if (!readme) return null;
            const description = text(first(doc, '[class*="SidebarAbout-module__description"]', ".BorderGrid-cell p.f4"));
            return { title: pathParts(url).slice(0, 2).join("/"), description, content: [readme] };
        }
    },
    {
        name: "GitLab project",
        matches: doc => meta(doc, "og:site_name") === "GitLab" && doc.querySelector(".project-home-panel, .home-panel"),
        extract(doc, url, resources) {
            const description = text(first(doc, '[itemprop="description"] .read-more-content', '[itemprop="description"]'));
            const title = meta(doc, "og:title")?.replace(/ · GitLab$/, "") || null;
            // The README is rendered client-side from a JSON endpoint the page lists in `gl.startup_calls`.
            const calls = Array.from(doc.querySelectorAll("script"), s => s.textContent.match(/gl\.startup_calls\s*=\s*(\{.*?\});/s)?.[1]).find(Boolean);
            let readmeURL;
            try { readmeURL = Object.keys(JSON.parse(calls)).find(path => /\/-\/blob\/.*viewer=rich/.test(path)); } catch {}
            if (!readmeURL) return description ? { title, description, content: [] } : null;
            readmeURL = new URL(readmeURL, url).href;
            if (!(readmeURL in resources)) return { needs: [readmeURL] };
            let html;
            try { html = JSON.parse(resources[readmeURL]).html; } catch {}
            const readme = new DOMParser().parseFromString(html || "", "text/html").querySelector(".file-content");
            return { title, description, content: readme ? [readme] : [] };
        }
    },
    {
        name: "Tangled repository",
        // Only the repository's front page, which `forge:summary` points to (without the handle's "@").
        matches: (doc, url) => {
            const summary = meta(doc, "forge:summary");
            const path = p => p.replace(/\/@/, "/").replace(/\/$/, "");
            return meta(doc, "og:site_name") === "Tangled" && summary && path(new URL(summary, url).pathname) === path(url.pathname);
        },
        extract(doc) {
            const readme = doc.querySelector("section.prose > article");
            if (!readme) return null;
            return { title: meta(doc, "og:title"), description: meta(doc, "og:description"), content: [readme] };
        }
    },
    {
        name: "arXiv paper",
        matches: (_, url) => /(^|\.)arxiv\.org$/.test(url.hostname) && pathParts(url)[0] === "abs",
        extract(doc, url, resources) {
            const title = meta(doc, "citation_title");
            const abstract = doc.querySelector("blockquote.abstract");
            if (!title || !abstract) return null;
            const link = doc.querySelector("#latexml-download-link")?.getAttribute("href");
            const paperURL = link ? new URL(new URL(link, url).pathname, url).href : null;
            if (paperURL && !(paperURL in resources)) return { needs: [paperURL] };

            abstract.querySelectorAll(".descriptor").forEach(node => node.remove());
            const heading = text => Object.assign(doc.createElement("h2"), { textContent: text });
            const abstractBody = doc.createElement("p");
            abstractBody.append(...abstract.childNodes);
            const content = [heading("Abstract"), abstractBody];
            const authors = Array.from(doc.querySelectorAll(".authors a"), a => a.textContent.trim()).filter(Boolean);
            if (authors.length) {
                content.unshift(Object.assign(doc.createElement("p"), { textContent: "Authors: " + authors.join(", ") }));
            }
            const paper = paperURL && arxivPaperBody(resources[paperURL], paperURL);
            if (paper) content.push(heading("Paper"), paper);
            return { title, excerpt: textWithFormulas(abstractBody).trim(), content };
        }
    },
    {
        name: "Wikipedia article",
        // Articles only; talk, user and other pages are left to Readability.
        matches: (doc, url) => /(^|\.)wikipedia\.org$/.test(url.hostname) && doc.body?.classList.contains("ns-0"),
        extract(doc, url, resources) {
            let title;
            try {
                const canonical = new URL(doc.querySelector('link[rel="canonical"]')?.getAttribute("href") || url.href, url);
                title = decodeURIComponent(canonical.pathname.match(/^\/wiki\/(.+)/)?.[1] ?? "");
            } catch {}
            if (!title) return null;
            // Parsoid's rendering marks citations, navigation and sections plainly, whatever the skin.
            const parsoidURL = `${url.origin}/w/rest.php/v1/page/${encodeURIComponent(title)}/html`;
            if (!(parsoidURL in resources)) return { needs: [parsoidURL] };
            const article = wikipediaArticle(resources[parsoidURL], new URL("/wiki/", url));
            return article && { title: article.title || title.replace(/_/g, " "), content: [article.body] };
        }
    }
];

// A Wikipedia article from its Parsoid HTML, without citations, navigation, maintenance notices, or the sections
// that only list references and links elsewhere. The infobox gives way to its picture.
function wikipediaArticle(html, base) {
    const page = new DOMParser().parseFromString(html || "", "text/html");
    if (!page.body.querySelector("section")) return null;
    // Links are relative to the wiki rather than the article, whose title may hold slashes.
    for (const link of page.body.querySelectorAll("a[href]")) {
        try { link.setAttribute("href", new URL(link.getAttribute("href"), base).href); } catch {}
    }
    prepareMath(page);
    page.body.querySelectorAll([
        "style", "link", "meta", "script",
        '[typeof~="mw:Extension/ref"]', '[typeof~="mw:Extension/references"]', ".mw-references-wrap", ".reflist", ".refbegin",
        ".navbox", ".navbox-styles", ".vertical-navbox", ".sidebar", ".hatnote", ".shortdescription", ".noprint", ".metadata",
        ".ambox", ".sistersitebox", ".side-box", ".portal-bar", ".authority-control", '[role="navigation"]', '[role="note"]',
        '[typeof~="mw:Extension/phonos"]', '[style*="display:none"]', '[style*="display: none"]'
    ].join(", ")).forEach(node => node.remove());
    for (const infobox of page.body.querySelectorAll("table.infobox")) {
        const picture = infobox.querySelector("img");
        if (!picture || parseFloat(picture.getAttribute("width")) < 100) { infobox.remove(); continue; }
        const figure = page.createElement("figure");
        figure.append(picture);
        const caption = infobox.querySelector(".infobox-caption")?.textContent.trim();
        if (caption) figure.append(Object.assign(page.createElement("figcaption"), { textContent: caption }));
        infobox.replaceWith(figure);
    }
    for (const img of page.body.querySelectorAll("img")) {
        // Flags and icons.
        if (parseFloat(img.getAttribute("width")) < 50) { (img.closest('[typeof^="mw:File"]') || img).remove(); continue; }
        const sharper = img.getAttribute("srcset") && fromSrcset(img.getAttribute("srcset"));
        if (sharper) img.setAttribute("src", sharper);
    }
    const listings = new Set(["See_also", "Notes", "References", "Footnotes", "Citations", "Sources", "Further_reading",
        "External_links", "Works_cited", "Notes_and_references", "Explanatory_notes"]);
    for (const section of page.body.querySelectorAll(":scope > section")) {
        const heading = section.querySelector(":scope > h2");
        if (!heading) continue;
        const length = nodes => nodes.reduce((sum, node) => sum + node.textContent.trim().length, 0);
        const content = length(Array.from(section.childNodes).filter(node => node !== heading));
        // In any language, a section left empty held only references, and one of links out with no prose is external links.
        const external = length(Array.from(section.querySelectorAll('a[rel~="mw:ExtLink"]')));
        const prose = Array.from(section.querySelectorAll("p")).some(p => p.textContent.trim());
        if (listings.has(heading.id) || !content || (!prose && external > content / 2)) section.remove();
    }
    const body = page.createElement("div");
    body.append(...page.body.childNodes);
    return body.textContent.trim() ? { title: page.querySelector("title")?.textContent.trim(), body } : null;
}

// The body of an arXiv HTML rendering, without the title, authors and abstract the abstract page already gives.
function arxivPaperBody(html, paperURL) {
    const paper = new DOMParser().parseFromString(html || "", "text/html");
    const article = paper.querySelector("article.ltx_document");
    if (!article) return null;
    article.querySelectorAll(".ltx_title_document, .ltx_authors, .ltx_abstract, .ltx_dates, .ltx_keywords").forEach(node => node.remove());
    for (const object of article.querySelectorAll('object[type="image/svg+xml"][data]')) {
        object.replaceWith(Object.assign(paper.createElement("img"), { src: object.getAttribute("data"), alt: "" }));
    }
    for (const [selector, attribute] of [["img", "src"], ["a", "href"]]) {
        for (const node of article.querySelectorAll(`${selector}[${attribute}]`)) {
            try { node.setAttribute(attribute, new URL(node.getAttribute(attribute), paperURL).href); } catch {}
        }
    }
    tidyMathML(article);
    // Displayed equations are laid out in tables, one row per line with its number in a cell of its own.
    for (const table of article.querySelectorAll("table.ltx_equation, table.ltx_equationgroup")) {
        const equation = paper.createElement("div");
        for (const row of table.querySelectorAll("tr")) {
            const line = paper.createElement("p");
            for (const cell of row.cells) line.append(...cell.childNodes, " ");
            if (!line.textContent.trim()) continue;
            // A block formula would push its number onto a line of its own.
            if (row.querySelector(".ltx_eqn_eqno")) {
                line.querySelectorAll("math").forEach(math => { math.setAttribute("display", "inline"); math.setAttribute("displaystyle", "true"); });
            }
            equation.append(line);
        }
        table.replaceWith(equation);
    }
    // LaTeXML's class names read to Readability as clutter, like the "headers" in `ltx_guessed_headers` on tables.
    [article, ...article.querySelectorAll("[class]")].forEach(node => node.removeAttribute("class"));
    paper.body.replaceChildren(article);
    let result;
    try { result = new Readability(paper, { maxElemsToParse: 60000 }).parse(); } catch {}
    const body = paper.createElement("div");
    if (result?.content) body.innerHTML = result.content;
    else body.append(...article.childNodes);
    return body.textContent.trim() ? body : null;
}

function applySiteRule(doc, url, resources) {
    const rule = siteRules.find(rule => rule.matches(doc, url));
    const result = rule?.extract(doc, url, resources);
    if (!result) return null;
    if (result.needs) {
        const needs = result.needs.filter(need => new URL(need).origin === url.origin && !(need in resources));
        return needs.length ? { needs } : null;
    }
    const body = doc.createElement("div");
    if (result.description) {
        const paragraph = doc.createElement("p");
        paragraph.textContent = result.description;
        body.append(paragraph);
    }
    body.append(...result.content);
    body.querySelectorAll("a.anchor").forEach(link => link.remove());
    const textContent = body.textContent.trim();
    if (!textContent) return null;
    return { title: result.title, byline: null, publishedTime: null, excerpt: result.excerpt || result.description, content: body.innerHTML, textContent };
}
