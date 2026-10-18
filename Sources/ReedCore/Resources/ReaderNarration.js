// Matches each passage read aloud to the element holding it, by text and in reading order. While narrating,
// the current sentence is tinted (or its whole passage, if the sentence can't be found) and kept in view;
// scrolling away stops that and reports which way it went.
// Tapping a sentence asks to read from there.
window.reedNarration = (() => {
    const blocks = 'p,h1,h2,h3,h4,h5,h6,li,dt,dd,blockquote,div,section,article,header,footer,aside,main,figure,img';
    const squash = text => text.replace(/\s+/g, '');
    // Narration reads a formula as ArticleText does: by its spoken label, as its text when that's plain,
    // or not at all. Each is read whole, so a sentence can only start or end beside one.
    const formulaText = math => math.getAttribute('aria-label')
        ?? (/^[^\\^_{]*$/.test(math.getAttribute('alttext') ?? '\\') ? math.textContent : '');
    // A picture reads as ArticleSpeech reads it: by its alt text, as a passage of its own, unless it sits beside text,
    // or its alt text is TeX, a file name, or a word like "image".
    const breaks = 'p,div,h1,h2,h3,h4,h5,h6,li,ul,ol,dl,dt,dd,blockquote,section,article,header,footer,aside,main,hr,br,'
        + 'figure,pre,table,svg,script,style,span.missing-image';
    const worthReading = alt => /[\p{L}\p{N}]/u.test(alt) && !/[\\^_{]/.test(alt)
        && !/^.*\.(jpe?g|png|gif|webp|avif|svg|bmp|tiff?|heic)$/i.test(alt)
        && !/^(image|img|picture|pic|photo|figure|graphic|untitled|null|undefined)\s*\d*$/i.test(alt);
    // The text between the block boundaries either side of `img`, which ArticleSpeech reads as one passage.
    const besideText = img => {
        if (img.closest('figure')) return false;
        let inline = img;
        while (inline.parentElement && !inline.parentElement.matches(breaks)) inline = inline.parentElement;
        const isBreak = node => node.nodeType === Node.ELEMENT_NODE && (node.matches(breaks) || node.querySelector(breaks));
        const run = [inline];
        for (let node = inline.previousSibling; node && !isBreak(node); node = node.previousSibling) run.push(node);
        for (let node = inline.nextSibling; node && !isBreak(node); node = node.nextSibling) run.push(node);
        return run.some(node => /[\p{L}\p{N}]/u.test(node.textContent));
    };
    const imageText = img => {
        const alt = img.alt.trim().replace(/\s+/g, ' ');
        return worthReading(alt) && !img.closest('figure.equation') && !besideText(img) ? `Image: ${alt}` : '';
    };
    // Footnote markers, which ArticleSpeech leaves out: a superscript holding just a number, letter or symbol,
    // unless it follows a digit as an exponent would, or an in-page link holding just a number or symbol.
    const isFootnote = element => {
        const text = element.textContent.trim();
        if (element.localName === 'sup') {
            return /^\[?(\d{1,3}|[a-z]|[*†‡§]{1,3})\]?$/u.test(text) && !/\d$/.test(element.previousSibling?.textContent ?? '');
        }
        return /^\[?(\d{1,3}|[*†‡§]{1,3}|↩[︎️]?)\]?$/u.test(text);
    };
    const markers = 'sup, a[href^="#"]';
    const inFootnote = node => {
        for (let element = node.parentElement.closest(markers); element; element = element.parentElement?.closest(markers)) {
            if (isFootnote(element)) return true;
        }
        return false;
    };
    // The text nodes, formulas and pictures narration reads within `element`, in order.
    const spokenParts = element => {
        const walker = document.createTreeWalker(element, NodeFilter.SHOW_ELEMENT | NodeFilter.SHOW_TEXT, {
            acceptNode: node => node.localName === 'math' || (node.localName === 'img' && imageText(node))
                || (node.nodeType === Node.TEXT_NODE && !node.parentElement.closest('math') && !inFootnote(node))
                ? NodeFilter.FILTER_ACCEPT : NodeFilter.FILTER_SKIP
        });
        const parts = [];
        for (let node; (node = walker.nextNode());) parts.push(node);
        return parts;
    };
    const partText = part => part.nodeType === Node.TEXT_NODE ? part.data : part.localName === 'img' ? imageText(part) : formulaText(part);
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
    // Pictures are local files, so they load at once rather than lazily as they near the screen; following waits for them
    // so the page doesn't shift under what's being read, but not for long, in case one never settles.
    for (const img of document.images) img.loading = 'eager';
    const imagesLoaded = Promise.race([
        Promise.all(Array.from(document.images).map(img => img.complete ? null
            : new Promise(resolve => { img.addEventListener('load', resolve); img.addEventListener('error', resolve); }))),
        new Promise(resolve => setTimeout(resolve, 1500)),
    ]);

    let elements = [], sentences = [], passagesOf = new Map();
    let current = null, currentIndex = null, currentSentence = null, following = true, leftView = false, reportedAway = '', lastScrolled = 0;
    // What's being read: the sentence's range when it was found, otherwise its passage's element.
    let target = null, marks = [], tintedFormulas = [];

    // The page's spoken text, without whitespace, is read through once in order: each passage is found after the one
    // before it, so text that repeats is matched where it's read. Its element is the innermost block holding all of it.
    // A passage not found from there is looked for from the start, leaving where the next is looked for unchanged,
    // as does one found far out of place.
    const locate = passages => {
        let text = '';
        // The part holding each character, and the span of characters each block holds.
        const owners = [], spans = new Map();
        for (const part of spokenParts(document.body)) {
            const start = text.length;
            text += squash(partText(part));
            if (text.length === start) continue;
            owners.length = text.length;
            owners.fill(part, start);
            for (let element = part.nodeType === Node.ELEMENT_NODE ? part : part.parentElement;
                 element && element !== document.body; element = element.parentElement) {
                if (!element.matches(blocks)) continue;
                const span = spans.get(element);
                if (span) span[1] = text.length; else spans.set(element, [start, text.length]);
            }
        }
        const targets = passages.map(squash);
        const onPage = targets.map(target => Boolean(target) && text.includes(target));
        let read = 0;
        return targets.map((target, index) => {
            if (!onPage[index]) return null;
            let at = text.indexOf(target, read);
            const ordered = at >= 0;
            if (!ordered) at = text.indexOf(target);
            const end = at + target.length;
            // A passage found out of place, far ahead, would leave the ones after it behind; one of the next few
            // being found only between here and there gives it away.
            const following = [];
            for (let after = index + 1; after < targets.length && following.length < 3; after++) {
                if (onPage[after]) following.push(targets[after]);
            }
            const ahead = ordered && following.some(next => text.includes(next, read) && !text.includes(next, end));
            const part = owners[at];
            let found = part.nodeType === Node.ELEMENT_NODE ? part : part.parentElement;
            for (; found && found !== document.body; found = found.parentElement) {
                const span = spans.get(found);
                if (span && span[1] >= end) break;
            }
            if (ordered && !ahead) read = end;
            return found === document.body ? null : found;
        });
    };
    // The range of each sentence of the passages at `indexes`, all held by `element`, matching text the same way passages
    // are matched and each sentence after the one before; null where a sentence can't be found.
    const sentenceRanges = (element, indexes) => {
        // Each character's range: within its text node, or around its whole formula or picture.
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
        let from = 0;
        return indexes.map(index => (sentences[index] ?? []).map(sentence => {
            sentence = squash(sentence);
            const at = sentence ? text.indexOf(sentence, from) : -1;
            if (at < 0) return null;
            from = at + sentence.length;
            const range = document.createRange();
            range.setStart(characters[at][0], characters[at][1]);
            range.setEnd(characters[from - 1][2], characters[from - 1][3]);
            return range;
        }));
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

    const scrollKeys = ['ArrowUp', 'ArrowDown', 'PageUp', 'PageDown', 'Home', 'End', ' '];
    const scrolledByHand = event => {
        if (currentIndex === null || (event.type === 'keydown' && !scrollKeys.includes(event.key))) return;
        following = false;
        lastScrolled = Date.now();
    };
    for (const type of ['wheel', 'touchmove', 'keydown']) window.addEventListener(type, scrolledByHand, {passive: true});
    window.addEventListener('scroll', () => {
        if (following || !target) return;
        lastScrolled = Date.now();
        // Scrolling back to what's being read picks following up again.
        if (leftView && inView(target)) { following = true; leftView = false; }
        reportAway();
    }, {passive: true});
    // Reads from the sentence tapped, found by where the caret would go.
    document.addEventListener('click', event => {
        if (currentIndex === null || event.target.closest('a, button') || !getSelection().isCollapsed) return;
        let element = event.target;
        while (element && !passagesOf.has(element)) element = element.parentElement;
        if (!element) return;
        const indexes = passagesOf.get(element);
        let passage = indexes[0], sentence = 0;
        const caret = document.caretRangeFromPoint?.(event.clientX, event.clientY);
        if (caret && element.contains(caret.startContainer)) {
            sentenceRanges(element, indexes).forEach((ranges, at) => ranges.forEach((range, number) => {
                if (range && range.comparePoint(caret.startContainer, caret.startOffset) >= 0) [passage, sentence] = [indexes[at], number];
            }));
        }
        if (passage !== currentIndex || sentence !== currentSentence) {
            window.webkit.messageHandlers.narrationJump.postMessage({passage, sentence});
        }
    });

    return {
        // The element holding each passage, or null where it wasn't found.
        get elements() { return elements; },
        setPassages(passages) {
            sentences = passages;
            elements = locate(passages.map(list => list.join(' ')));
            passagesOf = new Map();
            elements.forEach((element, index) => {
                if (!element) return;
                if (!passagesOf.has(element)) passagesOf.set(element, []);
                passagesOf.get(element).push(index);
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
            currentSentence = sentence;
            // A scroll that left what was being read on screen, and has settled, didn't mean to stop following it.
            if (!following && target && inView(target) && Date.now() - lastScrolled > 1000) following = true;
            current?.classList.remove('reed-narrating');
            unmark();
            current = elements[index] ?? null;
            const shared = current ? passagesOf.get(current) : [];
            const range = current ? sentenceRanges(current, shared)[shared.indexOf(index)]?.[sentence] : null;
            const marked = range ? mark(range) : null;
            if (!marked) current?.classList.add('reed-narrating');
            target = marked ?? current;
            if (following) scrollToCurrent(false);
            reportAway();
        },
        // Back to what's being read, following it again.
        follow() {
            following = true;
            leftView = false;
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
            currentSentence = null;
            following = true;
            leftView = false;
            reportAway();
        },
    };
})();
