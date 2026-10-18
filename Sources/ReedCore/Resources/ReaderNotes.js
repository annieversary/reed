// Notes on an article, in a page that slides over it from the right when swiping from right to left (or sideways on a
// trackpad): a note on the whole of it, then each noted sentence or picture, quoted, with the note under it.
// A swipe that starts on a sentence or picture adds it to the page, ready to write under; left unwritten, it's gone once
// the page closes. Noted sentences are underlined, and a line in the article's margin shows which passages have notes.
// Tapping a quote goes back to what it quotes.
window.reedNotes = (() => {
    const style = document.createElement('style');
    style.textContent = `
        .reed-noted { position: relative; }
        .reed-noted::after { content: ''; position: absolute; top: 0; bottom: 0; right: -14px; width: 2px; border-radius: 1px; background: var(--accent); }
        ::highlight(reed-noted) { text-decoration: underline 1.5px color-mix(in srgb, var(--accent) 55%, transparent); text-underline-offset: .22em; }
        ::highlight(reed-found) { background-color: color-mix(in srgb, var(--accent) 20%, transparent); }
        img.reed-found { outline: 3px solid color-mix(in srgb, var(--accent) 50%, transparent); outline-offset: 3px; }
        #reed-notes-page { position: fixed; inset: 0; z-index: 10; display: none; overflow-y: auto; overscroll-behavior: contain;
            background: var(--paper); color: var(--ink); font: calc(var(--font-size) * .85)/1.55 -apple-system, sans-serif;
            transform: translateX(100%); transition: transform .4s cubic-bezier(.2, .8, .2, 1); }
        .reed-notes-shown #reed-notes-page { display: block; }
        .reed-notes-open #reed-notes-page { transform: none; }
        #reed-notes-page > div { max-width: 640px; margin: 0 auto; padding: 40px 24px 100px; }
        #reed-notes-page small { display: block; margin-bottom: 12px; font: 11px -apple-system, sans-serif; font-weight: 600; letter-spacing: 2px; color: var(--accent); }
        .reed-overall { min-height: 6em; margin-bottom: 44px; outline: none; white-space: pre-wrap; cursor: text; }
        .reed-entry { margin-bottom: 30px; }
        .reed-entry blockquote { margin: 0 0 8px; padding-left: 14px; border-left: 2px solid var(--accent); cursor: pointer;
            font: italic calc(var(--font-size) * .9)/1.6 Georgia, serif; color: var(--muted); }
        .reed-entry img { display: block; max-width: 100%; max-height: 40vh; margin-bottom: 8px; border-radius: 6px; cursor: pointer; }
        .reed-entry div { outline: none; white-space: pre-wrap; cursor: text; }
        .reed-entry div:empty::before { content: 'Note'; color: var(--muted); }
        .reed-entries-empty { color: var(--muted); }`;
    document.head.appendChild(style);
    const root = document.documentElement;
    // The page sits beside the body, so it covers the article whatever the article's own layout.
    const page = document.createElement('div');
    page.id = 'reed-notes-page';
    const sheet = page.appendChild(document.createElement('div'));

    let open = false, ready = false, hiding, overall = '';
    // Whether the app last heard the page was open.
    let reportedOpen = false;
    // Each noted sentence and picture, and any just added to write under, in reading order.
    // A picture's entry holds its element; a sentence's is found by its passage and number there.
    let entries = [];
    // Zooming is held at 1 while the page is open, so its text doesn't zoom in when tapped.
    const viewport = document.querySelector('meta[name=viewport]') ?? document.head.appendChild(Object.assign(document.createElement('meta'),
        {name: 'viewport', content: 'width=device-width, initial-scale=1'}));
    const zoomable = viewport.content;
    const saves = new Map();
    let marked = new Set();

    const textOf = note => Array.from(note.childNodes, node =>
        node.nodeName === 'BR' ? '\n' : node.nodeName === 'DIV' ? '\n' + node.textContent : node.textContent).join('');
    const written = entry => entry.text.trim() !== '';
    const editable = className => Object.assign(document.createElement('div'), {className, contentEditable: 'plaintext-only'});
    // Saves wait for a pause in typing. Each waiting one is kept with its timer, so leaving the page can send it straight away.
    const save = (key, message, now) => {
        const send = () => {
            saves.delete(key);
            window.webkit.messageHandlers.noteChanged.postMessage(message());
        };
        if (now) { if (saves.has(key)) { clearTimeout(saves.get(key).timer); send(); } return; }
        clearTimeout(saves.get(key)?.timer);
        saves.set(key, {timer: setTimeout(send, 400), send});
    };
    const saveEntry = (entry, now) => entry.picture
        ? save(`picture:${entry.source}`, () => ({source: entry.source, alt: entry.alt, text: entry.text}), now)
        : save(`${entry.passage}:${entry.sentence}`, () => ({passage: entry.passage, sentence: entry.sentence, text: entry.text}), now);
    const saveOverall = now => save('overall', () => ({text: overall}), now);

    // A sentence's range, found once per passage for each use, since tinting what's read moves the text into new nodes.
    const rangeOf = (entry, found = new Map()) => {
        if (!found.has(entry.passage)) found.set(entry.passage, reedNarration.ranges(entry.passage) ?? []);
        return found.get(entry.passage)[entry.sentence] ?? null;
    };
    // What an entry quotes, as an element in the article.
    const elementOf = entry => entry.picture ?? reedNarration.elements[entry.passage];
    const inReadingOrder = (a, b) => {
        if (!a.picture && !b.picture) return a.passage - b.passage || a.sentence - b.sentence;
        const [x, y] = [elementOf(a), elementOf(b)];
        if (x === y) return 0;
        return x.compareDocumentPosition(y) & (Node.DOCUMENT_POSITION_FOLLOWING | Node.DOCUMENT_POSITION_CONTAINED_BY) ? -1 : 1;
    };
    // The picture saved under a file name, or failing that with the same alt text.
    const pictureSaved = (source, alt) => {
        const pictures = Array.from(document.body.querySelectorAll('img'));
        return pictures.find(img => img.getAttribute('src') === source) ?? (alt ? pictures.find(img => img.alt === alt) : null) ?? null;
    };
    const refresh = () => {
        const noted = new Set(entries.filter(written).map(entry => entry.picture
            ? entry.picture.closest('p, figure, li, blockquote, div') ?? entry.picture.parentElement
            : reedNarration.elements[entry.passage]).filter(Boolean));
        marked.forEach(element => { if (!noted.has(element)) element.classList.remove('reed-noted'); });
        noted.forEach(element => element.classList.add('reed-noted'));
        marked = noted;
        const found = new Map();
        window.CSS?.highlights?.set('reed-noted', new Highlight(...entries.filter(entry => written(entry) && !entry.picture)
            .map(entry => rangeOf(entry, found)).filter(Boolean)));
    };

    // The entry for a sentence or picture, added empty if it has none.
    const entryFor = place => {
        const same = place.picture ? entry => entry.picture === place.picture
            : entry => !entry.picture && entry.passage === place.passage && entry.sentence === place.sentence;
        let entry = entries.find(same);
        if (!entry) {
            entry = {...place, text: ''};
            entries.push(entry);
            entries.sort(inReadingOrder);
        }
        return entry;
    };
    const pictureEntry = img => ({picture: img, source: img.getAttribute('src'), alt: img.alt});

    const overallNote = editable('reed-overall');
    overallNote.addEventListener('input', () => { overall = textOf(overallNote); saveOverall(); });
    overallNote.addEventListener('blur', () => {
        saveOverall(true);
        if (!overall.trim()) overallNote.textContent = '';
    });
    const kicker = text => Object.assign(document.createElement('small'), {textContent: text});
    const build = () => {
        const shown = entries.map(entry => {
            const element = Object.assign(document.createElement('div'), {className: 'reed-entry'});
            let quote;
            if (entry.picture) {
                quote = Object.assign(new Image(), {src: entry.picture.src, alt: entry.alt});
            } else {
                quote = document.createElement('blockquote');
                quote.textContent = reedNarration.sentences[entry.passage]?.[entry.sentence] ?? '';
            }
            quote.addEventListener('click', () => goTo(entry));
            const note = editable('');
            note.textContent = entry.text;
            note.addEventListener('input', () => { entry.text = textOf(note); saveEntry(entry); });
            note.addEventListener('blur', () => saveEntry(entry, true));
            element.append(quote, note);
            entry.note = note;
            return element;
        });
        const none = Object.assign(document.createElement('p'), {className: 'reed-entries-empty',
            textContent: 'Swipe left from a sentence to write about it.'});
        sheet.replaceChildren(kicker('OVERALL'), overallNote, kicker('SENTENCES'), ...(shown.length ? shown : [none]));
    };
    // Shows the page with an entry in view, near the top.
    const reveal = entry => {
        root.classList.add('reed-notes-shown');
        clearTimeout(hiding);
        build();
        page.scrollTop = entry ? entry.note.parentElement.offsetTop - 60 : 0;
    };
    const write = entry => {
        entry.note.focus({preventScroll: true});
        getSelection().selectAllChildren(entry.note);
        getSelection().collapseToEnd();
    };
    // Back to the article, with what's quoted a little way down the screen, tinted for a moment.
    let foundTimer, foundPicture;
    const goTo = entry => {
        const range = entry.picture ? null : rangeOf(entry);
        const box = (range ?? elementOf(entry)).getBoundingClientRect();
        window.scrollTo(0, scrollY + box.top - innerHeight * .25);
        setOpen(false, true);
        clearTimeout(foundTimer);
        foundPicture?.classList.remove('reed-found');
        foundPicture = entry.picture;
        foundPicture?.classList.add('reed-found');
        if (range) window.CSS?.highlights?.set('reed-found', new Highlight(range));
        foundTimer = setTimeout(() => {
            foundPicture?.classList.remove('reed-found');
            window.CSS?.highlights?.delete('reed-found');
        }, 1500);
    };

    const setOpen = (value, report) => {
        if (!ready) return;
        if (!value && page.contains(document.activeElement)) document.activeElement.blur();
        if (value && !open && !root.classList.contains('reed-notes-shown')) reveal(null);
        open = value;
        // Sentences added but left unwritten aren't kept.
        if (!open) entries = entries.filter(written);
        root.classList.toggle('reed-notes-open', open);
        page.style.transform = '';
        viewport.content = open ? `${zoomable}, minimum-scale=1, maximum-scale=1` : zoomable;
        // Once slid away, the page leaves the layout.
        clearTimeout(hiding);
        if (!open) hiding = setTimeout(() => root.classList.remove('reed-notes-shown'), 400);
        refresh();
        if (report && reportedOpen !== open) {
            reportedOpen = open;
            window.webkit.messageHandlers.notesOpen.postMessage(open);
        }
    };
    // Opens the page, adding the picture or sentence at a point on screen to write under if there is one.
    const openAt = (x, y) => {
        const img = document.elementFromPoint(x, y)?.closest('img');
        const spot = img && document.body.contains(img) ? pictureEntry(img) : reedNarration.sentenceAt(x, y);
        const entry = spot ? entryFor(spot) : null;
        reveal(entry);
        return entry;
    };

    window.addEventListener('keydown', event => {
        if (event.key !== 'Escape' || !open) return;
        if (page.contains(document.activeElement)) document.activeElement.blur();
        else setOpen(false, true);
    });

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
        touch = event.touches.length === 1 && ready && !scrollsSideways(event.target)
            ? {x: point.clientX, y: point.clientY, dragging: false, wasOpen: open, dx: 0} : null;
    }, {passive: true});
    window.addEventListener('touchmove', event => {
        if (!touch) return;
        const dx = event.touches[0].clientX - touch.x, dy = event.touches[0].clientY - touch.y;
        if (!touch.dragging) {
            if (Math.hypot(dx, dy) < 10) return;
            if (Math.abs(dx) < Math.abs(dy) * 1.5 || (touch.wasOpen ? dx < 0 : dx > 0)) { touch = null; return; }
            touch.dragging = true;
            page.style.transition = 'none';
            if (!touch.wasOpen) touch.entry = openAt(touch.x, touch.y);
        }
        event.preventDefault();
        touch.dx = dx;
        page.style.transform = `translateX(${Math.max(0, touch.wasOpen ? dx : innerWidth + dx)}px)`;
    }, {passive: false});
    const endTouch = () => {
        if (!touch?.dragging) { touch = null; return; }
        const {wasOpen, dx, entry} = touch;
        touch = null;
        page.style.transition = '';
        // Past a third of the way, it carries on.
        const opening = wasOpen ? dx < innerWidth / 3 : -dx > innerWidth / 3;
        setOpen(opening, true);
        if (opening && entry) write(entry);
    };
    window.addEventListener('touchend', endTouch);
    window.addEventListener('touchcancel', endTouch);

    // A trackpad swipe arrives as sideways scrolling, and keeps arriving as it coasts, so each one toggles once.
    let swept = 0, sweepDone = false, sweepEnd, sweepFrom;
    window.addEventListener('wheel', event => {
        if (!ready || Math.abs(event.deltaX) <= Math.abs(event.deltaY) || scrollsSideways(event.target)) return;
        clearTimeout(sweepEnd);
        sweepEnd = setTimeout(() => { swept = 0; sweepDone = false; }, 200);
        if (sweepDone) return;
        if (!swept) sweepFrom = {x: event.clientX, y: event.clientY};
        swept += event.deltaX;
        if (Math.abs(swept) < 60) return;
        sweepDone = true;
        if (swept > 0 && !open) {
            const entry = openAt(sweepFrom.x, sweepFrom.y);
            // The page is laid out offscreen before it slides in.
            requestAnimationFrame(() => {
                setOpen(true, true);
                if (entry) write(entry);
            });
        } else if (swept < 0 && open) {
            setOpen(false, true);
        }
    }, {passive: true});

    return {
        setNotes(notes) {
            overall = notes.overall ?? '';
            overallNote.textContent = overall;
            entries = notes.sentences.filter(({passage}) => reedNarration.elements[passage])
                .map(({passage, sentence, text}) => ({passage, sentence, text}));
            for (const {source, alt, text} of notes.pictures ?? []) {
                const img = pictureSaved(source, alt);
                if (img && !entries.some(entry => entry.picture === img)) entries.push({...pictureEntry(img), source, text});
            }
            entries.sort(inReadingOrder);
            ready = reedNarration.elements.some(Boolean);
            if (!page.isConnected) root.append(page);
            if (open) build();
            refresh();
        },
        setOpen(value) {
            reportedOpen = value;
            if (value !== open) setOpen(value, false);
        },
        refresh() { if (ready) refresh(); },
        flush() {
            for (const {timer, send} of Array.from(saves.values())) { clearTimeout(timer); send(); }
        },
    };
})();
