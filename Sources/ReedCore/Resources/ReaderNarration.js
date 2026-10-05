// Matches each passage read aloud to the element holding it, by text and in reading order. While narrating,
// the current sentence is tinted (or its whole passage, if the sentence can't be found) and kept in view;
// scrolling away stops that and reports which way it went.
// Tapping a paragraph asks to read from there.
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
