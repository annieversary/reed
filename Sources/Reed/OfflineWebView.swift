import SwiftUI
import WebKit
#if SWIFT_PACKAGE
import ReedCore
#endif

/// Lets the reader's owner ask the page about narration.
@MainActor final class ReaderProxy {
    fileprivate weak var webView: WKWebView?

    /// The first passage at least partly on screen.
    func visiblePassage() async -> Int? {
        let value = try? await webView?.callAsyncJavaScript("return reedNarration.visible()", contentWorld: .defaultClient)
        return (value as? NSNumber)?.intValue
    }

    /// Scrolls back to the passage being read and keeps following it.
    func followNarration() {
        webView?.evaluateJavaScript("reedNarration.follow()", in: nil, in: .defaultClient) { _ in }
    }
}

/// The sentence being read aloud, and the passage it's in.
struct NarrationPosition: Equatable {
    var passage: Int
    var sentence: Int
}

/// Where the passage being read is, once you've scrolled away from it.
enum NarrationDirection: String {
    case up, down
}

@MainActor struct OfflineWebView {
    let url: URL
    let fontSize: Double
    let progress: Double
    /// The article's text as narration reads it, sentence by sentence within each passage, so it can be found on the page.
    var passages: [[String]]?
    /// What's being read aloud, if this article is being narrated.
    var narrating: NarrationPosition?
    var proxy: ReaderProxy?
    /// The notes beside the article's passages, once loaded.
    var notes: [ArticleNote]?
    var notesOpen = false
    var onProgress: (Double) -> Void
    var onAddLink: (URL) -> Void
    var onNarrateFrom: (Int) -> Void = { _ in }
    var onNarrationAway: (NarrationDirection?) -> Void = { _ in }
    var onNotesOpen: (Bool) -> Void = { _ in }
    var onNoteChange: (Int, String) -> Void = { _, _ in }

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    @MainActor func makeWebView(coordinator: Coordinator) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        configuration.userContentController.add(coordinator, contentWorld: .defaultClient, name: "readingProgress")
        let script = WKUserScript(source: """
        // Throttled rather than debounced, so progress keeps updating during one long scroll.
        let lastReport = 0, trailing;
        const report = () => {
            lastReport = Date.now();
            const distance = document.documentElement.scrollHeight - window.innerHeight;
            if (distance > 0) window.webkit.messageHandlers.readingProgress.postMessage(window.scrollY / distance);
        };
        window.addEventListener('scroll', () => {
            clearTimeout(trailing);
            if (Date.now() - lastReport >= 150) report();
            else trailing = setTimeout(report, 150);
        }, {passive:true});
        """, injectionTime: .atDocumentEnd, forMainFrameOnly: true, in: .defaultClient)
        configuration.userContentController.addUserScript(script)
        // Articles saved with an older template carry their own background.
        let paper = WKUserScript(source: """
        const style = document.createElement('style');
        style.textContent = ':root{--paper:#fff}@media(prefers-color-scheme:dark){:root{--paper:#000}}';
        document.head.appendChild(style);
        """, injectionTime: .atDocumentEnd, forMainFrameOnly: true, in: .defaultClient)
        configuration.userContentController.addUserScript(paper)
        // While narrating, the reader follows the narration rather than returning to where it was left.
        if narrating == nil, progress > 0 {
            configuration.userContentController.addUserScript(WKUserScript(source: Self.restoreScript(progress), injectionTime: .atDocumentEnd,
                                                                           forMainFrameOnly: true, in: .defaultClient))
        }
        configuration.userContentController.addUserScript(WKUserScript(source: Self.narrationScript, injectionTime: .atDocumentEnd,
                                                                       forMainFrameOnly: true, in: .defaultClient))
        configuration.userContentController.add(coordinator, contentWorld: .defaultClient, name: "narrationJump")
        configuration.userContentController.add(coordinator, contentWorld: .defaultClient, name: "narrationAway")
        configuration.userContentController.addUserScript(WKUserScript(source: Self.notesScript, injectionTime: .atDocumentEnd,
                                                                       forMainFrameOnly: true, in: .defaultClient))
        configuration.userContentController.add(coordinator, contentWorld: .defaultClient, name: "notesOpen")
        configuration.userContentController.add(coordinator, contentWorld: .defaultClient, name: "noteChanged")
        #if os(macOS)
        // AppKit's menu hook doesn't say which link was clicked, so the page reports it first.
        configuration.userContentController.add(coordinator, contentWorld: .defaultClient, name: "contextLink")
        let contextLink = WKUserScript(source: """
        document.addEventListener('contextmenu', event => {
            const link = event.target.closest && event.target.closest('a[href]');
            window.webkit.messageHandlers.contextLink.postMessage(link ? link.href : '');
        }, true);
        """, injectionTime: .atDocumentEnd, forMainFrameOnly: true, in: .defaultClient)
        configuration.userContentController.addUserScript(contextLink)
        let webView = ReaderWebView(frame: .zero, configuration: configuration)
        webView.coordinator = coordinator
        #else
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.uiDelegate = coordinator
        #endif
        webView.navigationDelegate = coordinator
        #if os(macOS)
        webView.setValue(false, forKey: "drawsBackground")
        #else
        webView.isOpaque = false
        webView.backgroundColor = .clear
        #endif
        webView.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
        proxy?.webView = webView
        return webView
    }

    @MainActor func update(_ webView: WKWebView, coordinator: Coordinator) {
        coordinator.parent = self
        guard coordinator.loaded else { return }
        coordinator.applyFont(webView)
        coordinator.applyPassages(webView)
        coordinator.applyNarration(webView)
        coordinator.applyNotesOpen(webView)
        #if os(iOS)
        // Swiping back from the screen's edge closes the margin, rather than leaving the article.
        if coordinator.backSwipeDisabled != notesOpen { coordinator.setBackSwipe(enabled: !notesOpen, from: webView) }
        #endif
    }

    /// Returns to where reading left off before the text fades in, so it doesn't appear at the top first.
    /// Images change the page's height as they load, so it's restored again once they have, unless you've started scrolling;
    /// a slow image only keeps the page hidden briefly.
    private static func restoreScript(_ progress: Double) -> String {
        """
        (() => {
            const root = document.documentElement;
            const restore = () => window.scrollTo(0, \(min(max(progress, 0), 1)) * Math.max(0, root.scrollHeight - window.innerHeight));
            let moved = false;
            for (const type of ['touchstart', 'wheel', 'keydown']) window.addEventListener(type, () => { moved = true; }, {passive: true, once: true});
            const images = Promise.all(Array.from(document.images, img => img.complete ? null
                : new Promise(resolve => { img.addEventListener('load', resolve); img.addEventListener('error', resolve); })));
            const body = document.body;
            body.style.opacity = '0';
            restore();
            Promise.race([images, new Promise(resolve => setTimeout(resolve, 400))]).then(() => {
                restore();
                body.style.transition = 'opacity .25s ease-out';
                body.style.opacity = '';
                body.addEventListener('transitionend', () => { body.style.transition = ''; }, {once: true});
            });
            images.then(() => { if (!moved) restore(); });
        })();
        """
    }

    /// Matches each passage read aloud to the element holding it, by text and in reading order. While narrating,
    /// the current sentence is tinted (or its whole passage, if the sentence can't be found) and kept in view;
    /// scrolling away stops that and reports which way it went.
    /// Tapping a paragraph asks to read from there.
    private static let narrationScript = #"""
    window.reedNarration = (() => {
        const blocks = 'p,h1,h2,h3,h4,h5,h6,li,dt,dd,blockquote,div,section,article,header,footer,aside,main';
        const squash = text => text.replace(/\s+/g, '');
        // Narration reads a formula as ArticleText does: by its spoken label, as its text when that's plain,
        // or not at all. Each is read whole, so a sentence can only start or end beside one.
        const formulaText = math => math.getAttribute('aria-label')
            ?? (/^[^\\^_{]*$/.test(math.getAttribute('alttext') ?? '\\') ? math.textContent : '');
        // The text nodes and formulas narration reads within `element`, in order.
        const spokenParts = element => {
            const walker = document.createTreeWalker(element, NodeFilter.SHOW_ELEMENT | NodeFilter.SHOW_TEXT, {
                acceptNode: node => node.localName === 'math' || (node.nodeType === Node.TEXT_NODE && !node.parentElement.closest('math'))
                    ? NodeFilter.FILTER_ACCEPT : NodeFilter.FILTER_SKIP
            });
            const parts = [];
            for (let node; (node = walker.nextNode());) parts.push(node);
            return parts;
        };
        const partText = part => part.nodeType === Node.TEXT_NODE ? part.data : formulaText(part);
        const spokenText = element => spokenParts(element).map(partText).join('');
        const style = document.createElement('style');
        style.textContent = `
            :root { --narrating: color-mix(in srgb, var(--accent) 9%, transparent); }
            @media (prefers-color-scheme: dark) { :root { --narrating: color-mix(in srgb, var(--accent) 15%, transparent); } }
            :where(${blocks}) { transition: background-color .5s, box-shadow .5s; }
            :root { --narrating-sentence: color-mix(in srgb, var(--accent) 20%, transparent); }
            @media (prefers-color-scheme: dark) { :root { --narrating-sentence: color-mix(in srgb, var(--accent) 32%, transparent); } }
            .reed-narrating { background-color: var(--narrating); box-shadow: 0 0 0 .4em var(--narrating); border-radius: .25em; }
            .reed-sentence { background-color: var(--narrating-sentence); }
            .reed-narration-active .reed-passage { cursor: pointer; }`;
        document.head.appendChild(style);
        const imagesLoaded = Promise.all(Array.from(document.images).map(img => img.complete ? null
            : new Promise(resolve => { img.addEventListener('load', resolve); img.addEventListener('error', resolve); })));

        let elements = [], sentences = [], firstPassage = new Map();
        let current = null, currentIndex = null, following = true, leftView = false, reportedAway = '';
        // What's being read: the sentence's range when it was found, otherwise its passage's element.
        let target = null, marks = [], tintedFormulas = [];

        const locate = passages => {
            const all = Array.from(document.body.querySelectorAll(blocks));
            const texts = new Map(all.map(element => [element, squash(spokenText(element))]));
            let cursor = 0;
            return passages.map(text => {
                const target = squash(text);
                const contains = element => texts.get(element).includes(target);
                let at = all.findIndex((element, index) => index >= cursor && contains(element));
                if (at < 0) at = all.findIndex(contains);
                if (at < 0) return null;
                let found = all[at];
                for (let child; (child = Array.from(found.children).find(c => texts.has(c) && contains(c)));) found = child;
                cursor = all.indexOf(found);
                return found;
            });
        };
        // The range of the `number`th sentence within `element`, matching text the same way passages are matched.
        const sentenceRange = (element, list, number) => {
            // Each character's range: within its text node, or around its whole formula.
            const characters = [];
            let text = '';
            for (const part of spokenParts(element)) {
                const content = partText(part);
                const formulaAt = part.nodeType === Node.TEXT_NODE ? null : Array.prototype.indexOf.call(part.parentNode.childNodes, part);
                for (let offset = 0; offset < content.length; offset++) {
                    if (/\s/.test(content[offset])) continue;
                    characters.push(formulaAt === null ? [part, offset, part, offset + 1] : [part.parentNode, formulaAt, part.parentNode, formulaAt + 1]);
                    text += content[offset];
                }
            }
            let from = 0, at = -1, length = 0;
            for (let index = 0; index <= number; index++) {
                const sentence = squash(list[index] ?? '');
                at = sentence ? text.indexOf(sentence, from) : -1;
                if (at < 0) return null;
                length = sentence.length;
                from = at + length;
            }
            const range = document.createRange();
            range.setStart(characters[at][0], characters[at][1]);
            range.setEnd(characters[at + length - 1][2], characters[at + length - 1][3]);
            return range;
        };
        // Wraps the text in `range` in tinted spans, one per text node, so it can cross inline elements like links.
        // Formulas are tinted whole, since spans inside one would break its layout.
        const mark = range => {
            const container = range.commonAncestorContainer;
            tintedFormulas = container.nodeType === Node.ELEMENT_NODE
                ? Array.from(container.querySelectorAll('math')).filter(math => range.intersectsNode(math)) : [];
            tintedFormulas.forEach(math => math.classList.add('reed-sentence'));
            const pieces = [];
            const walker = document.createTreeWalker(range.commonAncestorContainer, NodeFilter.SHOW_TEXT);
            for (let node = walker.currentNode.nodeType === Node.TEXT_NODE ? walker.currentNode : walker.nextNode(); node; node = walker.nextNode()) {
                if (!range.intersectsNode(node) || node.parentElement?.closest('math')) continue;
                const start = node === range.startContainer ? range.startOffset : 0;
                const end = node === range.endContainer ? range.endOffset : node.length;
                if (start < end) pieces.push([node, start, end]);
            }
            marks = pieces.map(([node, start, end]) => {
                if (end < node.length) node.splitText(end);
                if (start > 0) node = node.splitText(start);
                const span = document.createElement('span');
                span.className = 'reed-sentence';
                node.parentNode.insertBefore(span, node);
                span.appendChild(node);
                return span;
            });
            const tinted = [...marks, ...tintedFormulas].sort((a, b) => a.compareDocumentPosition(b) & Node.DOCUMENT_POSITION_FOLLOWING ? -1 : 1);
            if (!tinted.length) return null;
            const marked = document.createRange();
            marked.setStartBefore(tinted[0]);
            marked.setEndAfter(tinted[tinted.length - 1]);
            return marked;
        };
        const unmark = () => {
            for (const span of marks) {
                const parent = span.parentNode;
                if (!parent) continue;
                while (span.firstChild) parent.insertBefore(span.firstChild, span);
                span.remove();
                parent.normalize();
            }
            marks = [];
            tintedFormulas.forEach(math => math.classList.remove('reed-sentence'));
            tintedFormulas = [];
        };
        const inView = element => {
            const box = element.getBoundingClientRect();
            return box.bottom > 0 && box.top < innerHeight;
        };
        const scrollToCurrent = always => imagesLoaded.then(() => {
            if (!target) return;
            const box = target.getBoundingClientRect();
            if (!always && box.top >= 0 && box.bottom <= innerHeight * 0.75) return;
            window.scrollTo({top: scrollY + box.top - innerHeight * 0.2, behavior: 'smooth'});
        });
        // Tells the app whether what's being read is above or below the screen, or '' when it's in view.
        const reportAway = () => {
            let away = '';
            if (!following && target && !inView(target)) {
                leftView = true;
                away = target.getBoundingClientRect().top < 0 ? 'up' : 'down';
            }
            if (away === reportedAway) return;
            reportedAway = away;
            window.webkit.messageHandlers.narrationAway.postMessage(away);
        };

        for (const type of ['wheel', 'touchmove', 'keydown']) {
            window.addEventListener(type, () => { if (currentIndex !== null) { following = false; leftView = false; } }, {passive: true});
        }
        window.addEventListener('scroll', () => {
            if (following || !target) return;
            // Scrolling back to what's being read picks following up again.
            if (leftView && inView(target)) following = true;
            reportAway();
        }, {passive: true});
        document.addEventListener('click', event => {
            if (currentIndex === null || event.target.closest('a, button') || !getSelection().isCollapsed) return;
            for (let element = event.target; element; element = element.parentElement) {
                if (!firstPassage.has(element)) continue;
                const index = firstPassage.get(element);
                if (index !== currentIndex) window.webkit.messageHandlers.narrationJump.postMessage(index);
                return;
            }
        });

        return {
            // The element holding each passage, or null where it wasn't found.
            get elements() { return elements; },
            setPassages(passages) {
                sentences = passages;
                elements = locate(passages.map(list => list.join(' ')));
                firstPassage = new Map();
                elements.forEach((element, index) => {
                    if (!element || firstPassage.has(element)) return;
                    firstPassage.set(element, index);
                    element.classList.add('reed-passage');
                });
            },
            // The first passage at least partly on screen.
            visible() {
                const index = elements.findIndex(element => element && element.getBoundingClientRect().bottom > 4);
                return index < 0 ? null : index;
            },
            show(index, sentence) {
                document.documentElement.classList.add('reed-narration-active');
                currentIndex = index;
                current?.classList.remove('reed-narrating');
                unmark();
                current = elements[index] ?? null;
                const range = current ? sentenceRange(current, sentences[index] ?? [], sentence) : null;
                const marked = range ? mark(range) : null;
                if (!marked) current?.classList.add('reed-narrating');
                target = marked ?? current;
                if (following) scrollToCurrent(false);
                reportAway();
            },
            // Back to what's being read, following it again.
            follow() {
                following = true;
                reportAway();
                scrollToCurrent(true);
            },
            clear() {
                document.documentElement.classList.remove('reed-narration-active');
                current?.classList.remove('reed-narrating');
                unmark();
                current = null;
                target = null;
                currentIndex = null;
                following = true;
                reportAway();
            },
        };
    })();
    """#

    /// A margin of notes beside the article, one beside each passage, opened by swiping from right to left
    /// (or sideways on a trackpad). The article slides over only as far as the margin needs, dimmed when little of it is left.
    /// A note longer than its passage parts the article below it, so every note stays beside what it's about,
    /// and a line in the article's margin shows which passages have one.
    /// Tapping beside a passage writes there; tapping the dimmed article closes the margin.
    private static let notesScript = #"""
    window.reedNotes = (() => {
        const gutter = 28, edge = 20, spacing = 16;
        const style = document.createElement('style');
        style.textContent = `
            .reed-notes-shown { overflow-x: hidden; }
            .reed-notes-shown body { position: relative; }
            body { transition: transform .4s cubic-bezier(.2, .8, .2, 1); }
            main { transition: opacity .4s; }
            .reed-notes-dim main { opacity: .3; }
            #reed-notes { position: absolute; top: 0; display: none; opacity: 0; transition: opacity .3s;
                font: calc(var(--font-size) * .8)/1.55 -apple-system, sans-serif; color: var(--ink); }
            .reed-notes-shown #reed-notes { display: block; }
            .reed-notes-open #reed-notes { opacity: 1; }
            @starting-style { .reed-notes-open #reed-notes { opacity: 0; } }
            .reed-note { position: absolute; left: 0; right: 0; outline: none; white-space: pre-wrap; cursor: text; }
            .reed-noted { position: relative; }
            .reed-noted::after { content: ''; position: absolute; top: 0; bottom: 0; right: -14px; width: 2px; border-radius: 1px; background: var(--accent); }
            .reed-note:focus:empty::before { content: 'Note'; color: var(--muted); }`;
        document.head.appendChild(style);
        const column = document.createElement('div');
        column.id = 'reed-notes';

        let open = false, shift = 0, slots = [], scheduled = false, hiding;
        // Zooming is held at 1 while the margin is open: the page is wider than the screen then, and a note's
        // small text would otherwise zoom in when tapped.
        const viewport = document.querySelector('meta[name=viewport]') ?? document.head.appendChild(Object.assign(document.createElement('meta'),
            {name: 'viewport', content: 'width=device-width, initial-scale=1'}));
        const zoomable = viewport.content;
        // Each parted passage's extra space, and its own margin before it was parted.
        const gaps = new Map(), margins = new Map(), saves = new Map();

        const textOf = note => Array.from(note.childNodes, node =>
            node.nodeName === 'BR' ? '\n' : node.nodeName === 'DIV' ? '\n' + node.textContent : node.textContent).join('');
        const writing = note => note === document.activeElement || textOf(note).trim() !== '';
        const save = (index, note, now) => {
            const send = () => {
                saves.delete(index);
                window.webkit.messageHandlers.noteChanged.postMessage({passage: index, text: textOf(note)});
            };
            if (now) { if (saves.has(index)) { clearTimeout(saves.get(index)); send(); } return; }
            clearTimeout(saves.get(index));
            saves.set(index, setTimeout(send, 400));
        };
        const setGap = (element, gap) => {
            if (gap < .5) {
                if (margins.has(element)) element.style.marginBottom = margins.get(element)[0];
                gaps.delete(element);
                margins.delete(element);
                return;
            }
            if (!margins.has(element)) margins.set(element, [element.style.marginBottom, parseFloat(getComputedStyle(element).marginBottom) || 0]);
            gaps.set(element, gap);
            element.style.marginBottom = `${margins.get(element)[1] + gap}px`;
        };
        // Where the margin goes beside the article, and how far the article must slide for it to fit.
        const geometry = () => {
            const width = document.documentElement.clientWidth;
            const main = document.querySelector('main') ?? document.body;
            const columnWidth = Math.min(340, width * .78);
            const box = main.getBoundingClientRect();
            const left = box.right - document.body.getBoundingClientRect().left + gutter;
            const bodyLeft = Math.max(0, (width - document.body.offsetWidth) / 2);
            return {columnWidth, left, articleWidth: box.width, shift: Math.max(0, bodyLeft + left + columnWidth + edge - width)};
        };
        // Puts each note beside its passage, and parts the article below each note that's longer than its passage.
        // Growing one gap moves everything below it, so the rest are worked out from the first measurement.
        const place = () => {
            const bodyTop = document.body.getBoundingClientRect().top;
            const boxes = slots.map(slot => slot.element.getBoundingClientRect());
            slots.forEach((slot, k) => { slot.note.style.minHeight = `${boxes[k].height}px`; });
            const heights = slots.map(slot => slot.note.offsetHeight);
            let moved = 0, changed = false;
            slots.forEach((slot, k) => {
                const top = boxes[k].top + moved, gap = gaps.get(slot.element) ?? 0;
                slot.note.style.top = `${top - bodyTop}px`;
                const next = boxes[k + 1];
                // A passage holding the next one can't be parted from it.
                const wanted = next && next.top >= boxes[k].bottom - 1 && writing(slot.note)
                    ? Math.max(0, gap + top + heights[k] + spacing - (next.top + moved)) : 0;
                if (Math.abs(wanted - gap) < .5) return;
                setGap(slot.element, wanted);
                moved += wanted - gap;
                changed = true;
            });
            return changed;
        };
        const layout = () => {
            scheduled = false;
            if (!slots.length) return;
            // Keeps what's at the top of the screen where it is while passages part or close up.
            const anchor = slots.find(slot => slot.element.getBoundingClientRect().bottom > 0)?.element;
            const before = anchor?.getBoundingClientRect().top;
            if (open) {
                const {columnWidth, left} = geometry();
                column.style.left = `${left}px`;
                column.style.width = `${columnWidth}px`;
                // Collapsing margins can swallow some of a gap, so it's measured again.
                for (let pass = 0; pass < 4 && place(); pass++);
            } else {
                Array.from(gaps.keys()).forEach(element => setGap(element, 0));
            }
            if (anchor) {
                const after = anchor.getBoundingClientRect().top;
                if (Math.abs(after - before) > .5) window.scrollBy(0, after - before);
            }
        };
        const schedule = () => {
            if (scheduled) return;
            scheduled = true;
            requestAnimationFrame(layout);
        };
        // The article only gets a transform while it's slid over, since one repaints the whole page onto its own layer.
        const slide = offset => { document.body.style.transform = offset ? `translateX(${-offset}px)` : ''; };
        const setOpen = (value, report) => {
            if (!slots.length) return;
            if (!value && column.contains(document.activeElement)) document.activeElement.blur();
            open = value;
            document.documentElement.classList.toggle('reed-notes-open', open);
            viewport.content = open ? `${zoomable}, minimum-scale=1, maximum-scale=1` : zoomable;
            // Once faded out, the margin leaves the layout, so the page is no wider than the screen.
            clearTimeout(hiding);
            if (open) document.documentElement.classList.add('reed-notes-shown');
            else hiding = setTimeout(() => document.documentElement.classList.remove('reed-notes-shown'), 400);
            layout();
            const geometryNow = geometry();
            shift = open ? geometryNow.shift : 0;
            slide(shift);
            document.documentElement.classList.toggle('reed-notes-dim', open && shift > geometryNow.articleWidth / 2);
            if (report) window.webkit.messageHandlers.notesOpen.postMessage(open);
        };

        new ResizeObserver(schedule).observe(document.querySelector('main') ?? document.body);
        window.addEventListener('resize', () => { if (open) setOpen(true); });
        window.addEventListener('click', event => {
            if (!document.documentElement.classList.contains('reed-notes-dim') || column.contains(event.target)) return;
            event.preventDefault();
            event.stopPropagation();
            setOpen(false, true);
        }, true);

        // Swipes that start on something scrolling sideways, like a wide table or code, scroll it instead.
        const scrollsSideways = target => {
            for (let element = target instanceof Element ? target : target.parentElement; element && element !== document.body; element = element.parentElement) {
                if (element.scrollWidth > element.clientWidth + 1 && getComputedStyle(element).overflowX !== 'visible') return true;
            }
            return false;
        };
        let touch = null;
        window.addEventListener('touchstart', event => {
            const point = event.touches[0];
            touch = event.touches.length === 1 && slots.length && !scrollsSideways(event.target)
                ? {x: point.clientX, y: point.clientY, dragging: false, wasOpen: open, offset: shift} : null;
        }, {passive: true});
        window.addEventListener('touchmove', event => {
            if (!touch) return;
            const dx = event.touches[0].clientX - touch.x, dy = event.touches[0].clientY - touch.y;
            if (!touch.dragging) {
                if (Math.hypot(dx, dy) < 10) return;
                if (Math.abs(dx) < Math.abs(dy) * 1.5 || (open ? dx < 0 : dx > 0)) { touch = null; return; }
                touch.dragging = true;
                document.body.style.transition = 'none';
                if (!open) setOpen(true);
            }
            event.preventDefault();
            touch.offset = Math.min(Math.max((touch.wasOpen ? shift : 0) - dx, 0), shift);
            slide(touch.offset);
            touch.dx = dx;
        }, {passive: false});
        const endTouch = () => {
            if (!touch?.dragging) { touch = null; return; }
            document.body.style.transition = '';
            // Past a third of the way, it carries on; a margin that needs no sliding goes by the swipe's length.
            const opening = shift > 0 ? touch.offset > shift * (touch.wasOpen ? 2 / 3 : 1 / 3) : (touch.wasOpen ? touch.dx < 40 : true);
            touch = null;
            setOpen(opening, true);
        };
        window.addEventListener('touchend', endTouch);
        window.addEventListener('touchcancel', endTouch);

        // A trackpad swipe arrives as sideways scrolling, and keeps arriving as it coasts, so each one toggles once.
        let swept = 0, sweepDone = false, sweepEnd;
        window.addEventListener('wheel', event => {
            if (!slots.length || Math.abs(event.deltaX) <= Math.abs(event.deltaY) || scrollsSideways(event.target)) return;
            clearTimeout(sweepEnd);
            sweepEnd = setTimeout(() => { swept = 0; sweepDone = false; }, 200);
            if (sweepDone) return;
            swept += event.deltaX;
            if (Math.abs(swept) < 60) return;
            sweepDone = true;
            if ((swept > 0) !== open) setOpen(swept > 0, true);
        }, {passive: true});

        return {
            setNotes(notes) {
                const written = new Map(notes.map(note => [note.passage, note.text]));
                const seen = new Set();
                column.replaceChildren();
                slots = [];
                reedNarration.elements.forEach((element, index) => {
                    if (!element || seen.has(element)) return;
                    seen.add(element);
                    const note = document.createElement('div');
                    note.className = 'reed-note';
                    note.contentEditable = 'plaintext-only';
                    note.textContent = written.get(index) ?? '';
                    const mark = () => element.classList.toggle('reed-noted', textOf(note).trim() !== '');
                    mark();
                    note.addEventListener('input', () => { mark(); schedule(); save(index, note); });
                    note.addEventListener('focus', schedule);
                    note.addEventListener('blur', () => {
                        save(index, note, true);
                        if (!textOf(note).trim()) note.textContent = '';
                        schedule();
                    });
                    column.appendChild(note);
                    slots.push({element, note});
                });
                if (!column.isConnected) document.body.appendChild(column);
                slide(shift);
                schedule();
            },
            setOpen(value) { setOpen(value, false); },
        };
    })();
    """#

    @MainActor final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler {
        var parent: OfflineWebView
        var loaded = false
        var contextLink: URL?
        private var currentFontSize: Double?
        private var sentPassages: [[String]]?
        private var shownNarration: NarrationPosition?
        private var sentNotes = false
        private var shownNotesOpen = false
        init(parent: OfflineWebView) { self.parent = parent }

        func applyFont(_ webView: WKWebView) {
            guard currentFontSize != parent.fontSize else { return }
            currentFontSize = parent.fontSize
            webView.evaluateJavaScript("document.documentElement.style.setProperty('--font-size', '\(parent.fontSize)px')", in: nil, in: .defaultClient) { _ in }
        }

        func applyPassages(_ webView: WKWebView) {
            guard let passages = parent.passages, let notes = parent.notes, passages != sentPassages || !sentNotes else { return }
            sentPassages = passages
            sentNotes = true
            shownNarration = nil
            let written = notes.map { ["passage": $0.passage, "text": $0.text] as [String: Any] }
            webView.callAsyncJavaScript("reedNarration.setPassages(passages); reedNotes.setNotes(notes)",
                                        arguments: ["passages": passages, "notes": written], in: nil, in: .defaultClient) { _ in }
        }

        func applyNotesOpen(_ webView: WKWebView) {
            guard sentNotes, shownNotesOpen != parent.notesOpen else { return }
            shownNotesOpen = parent.notesOpen
            webView.evaluateJavaScript("reedNotes.setOpen(\(parent.notesOpen))", in: nil, in: .defaultClient) { _ in }
        }

        func applyNarration(_ webView: WKWebView) {
            guard sentPassages != nil, shownNarration != parent.narrating else { return }
            shownNarration = parent.narrating
            if let position = parent.narrating {
                webView.callAsyncJavaScript("reedNarration.show(index, sentence)", arguments: ["index": position.passage, "sentence": position.sentence],
                                            in: nil, in: .defaultClient) { _ in }
            } else {
                webView.evaluateJavaScript("reedNarration.clear()", in: nil, in: .defaultClient) { _ in }
            }
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            loaded = true
            applyFont(webView)
            applyPassages(webView)
            applyNotesOpen(webView)
            if parent.narrating != nil { applyNarration(webView) }
        }

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            if message.name == "contextLink" {
                contextLink = (message.body as? String).flatMap(URL.init(string:)).flatMap { Self.isWeb($0) ? $0 : nil }
                return
            }
            if message.name == "narrationJump" {
                if let index = message.body as? Int { parent.onNarrateFrom(index) }
                return
            }
            if message.name == "notesOpen" {
                guard let open = message.body as? Bool else { return }
                shownNotesOpen = open
                parent.onNotesOpen(open)
                return
            }
            if message.name == "noteChanged" {
                guard let body = message.body as? [String: Any], let passage = body["passage"] as? Int, let text = body["text"] as? String else { return }
                parent.onNoteChange(passage, text)
                return
            }
            if message.name == "narrationAway" {
                parent.onNarrationAway((message.body as? String).flatMap(NarrationDirection.init(rawValue:)))
                return
            }
            guard loaded, let number = message.body as? Double else { return }
            parent.onProgress(number)
        }

        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
            guard let url = navigationAction.request.url else { return .cancel }
            if navigationAction.navigationType == .linkActivated {
                if Self.isWeb(url) {
                    #if os(macOS)
                    NSWorkspace.shared.open(url)
                    #else
                    _ = await UIApplication.shared.open(url)
                    #endif
                }
                return .cancel
            } else {
                return url.isFileURL && url.deletingLastPathComponent().standardizedFileURL == parent.url.deletingLastPathComponent().standardizedFileURL ? .allow : .cancel
            }
        }

        #if os(iOS)
        private(set) var backSwipeDisabled = false

        func setBackSwipe(enabled: Bool, from view: UIView) {
            var responder: UIResponder? = view
            while let next = responder, !(next is UIViewController) { responder = next.next }
            guard let navigation = (responder as? UIViewController)?.navigationController else { return }
            backSwipeDisabled = !enabled
            navigation.interactivePopGestureRecognizer?.isEnabled = enabled
            if #available(iOS 26, *) { navigation.interactiveContentPopGestureRecognizer?.isEnabled = enabled }
        }
        #endif

        static func isWeb(_ url: URL) -> Bool { ["https", "http"].contains(url.scheme?.lowercased() ?? "") }

        #if os(iOS)
        func webView(_ webView: WKWebView, contextMenuConfigurationForElement elementInfo: WKContextMenuElementInfo) async -> UIContextMenuConfiguration? {
            guard let url = elementInfo.linkURL, Self.isWeb(url) else { return nil }
            return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { [weak self] suggested in
                let add = UIAction(title: "Add to Reed", image: UIImage(systemName: "plus")) { _ in self?.parent.onAddLink(url) }
                return UIMenu(children: [add] + suggested)
            }
        }
        #endif
    }
}

#if os(macOS)
final class ReaderWebView: WKWebView {
    weak var coordinator: OfflineWebView.Coordinator?

    override func willOpenMenu(_ menu: NSMenu, with event: NSEvent) {
        super.willOpenMenu(menu, with: event)
        guard let coordinator, let url = coordinator.contextLink else { return }
        let item = NSMenuItem(title: "Add to Reed", action: #selector(addLink(_:)), keyEquivalent: "")
        item.target = self
        item.representedObject = url
        menu.insertItem(item, at: 0)
        menu.insertItem(.separator(), at: 1)
    }

    @objc private func addLink(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        coordinator?.parent.onAddLink(url)
    }
}

extension OfflineWebView: NSViewRepresentable {
    func makeNSView(context: Context) -> WKWebView { makeWebView(coordinator: context.coordinator) }
    func updateNSView(_ nsView: WKWebView, context: Context) { update(nsView, coordinator: context.coordinator) }
    static func dismantleNSView(_ nsView: WKWebView, coordinator: Coordinator) {
        nsView.configuration.userContentController.removeScriptMessageHandler(forName: "readingProgress", contentWorld: .defaultClient)
        nsView.configuration.userContentController.removeScriptMessageHandler(forName: "contextLink", contentWorld: .defaultClient)
        nsView.configuration.userContentController.removeScriptMessageHandler(forName: "narrationJump", contentWorld: .defaultClient)
        nsView.configuration.userContentController.removeScriptMessageHandler(forName: "narrationAway", contentWorld: .defaultClient)
        nsView.configuration.userContentController.removeScriptMessageHandler(forName: "notesOpen", contentWorld: .defaultClient)
        nsView.configuration.userContentController.removeScriptMessageHandler(forName: "noteChanged", contentWorld: .defaultClient)
        nsView.navigationDelegate = nil
    }
}
#else
extension OfflineWebView: UIViewRepresentable {
    func makeUIView(context: Context) -> WKWebView { makeWebView(coordinator: context.coordinator) }
    func updateUIView(_ uiView: WKWebView, context: Context) { update(uiView, coordinator: context.coordinator) }
    static func dismantleUIView(_ uiView: WKWebView, coordinator: Coordinator) {
        uiView.configuration.userContentController.removeScriptMessageHandler(forName: "readingProgress", contentWorld: .defaultClient)
        uiView.configuration.userContentController.removeScriptMessageHandler(forName: "narrationJump", contentWorld: .defaultClient)
        uiView.configuration.userContentController.removeScriptMessageHandler(forName: "narrationAway", contentWorld: .defaultClient)
        uiView.configuration.userContentController.removeScriptMessageHandler(forName: "notesOpen", contentWorld: .defaultClient)
        uiView.configuration.userContentController.removeScriptMessageHandler(forName: "noteChanged", contentWorld: .defaultClient)
        uiView.navigationDelegate = nil
        uiView.uiDelegate = nil
        if coordinator.backSwipeDisabled { coordinator.setBackSwipe(enabled: true, from: uiView) }
    }
}
#endif
