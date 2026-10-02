// Pages Readability handles poorly, picked out by hand. A rule whose `matches(doc, url)` is true
// returns from `extract(doc, url, resources)` either:
//   { title, description?, content: [Node] }  — used instead of Readability's guess;
//   { needs: [url] }                          — same-origin JSON to fetch first; the extraction then
//                                               runs again with each response text in `resources[url]`;
//   null                                      — fall back to Readability.
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
    }
];

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
    return { title: result.title, byline: null, publishedTime: null, excerpt: result.description, content: body.innerHTML, textContent };
}
