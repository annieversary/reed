// A margin of notes beside the article, one beside each passage, opened by swiping from right to left
// (or sideways on a trackpad). The article slides over only as far as the margin needs, dimmed when little of it is left.
// A note longer than its passage parts the article below it, so every note stays beside what it's about,
// and a line in the article's margin shows which passages have one.
// Tapping beside a passage writes there; tapping the dimmed article closes the margin.
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
    // Saves wait for a pause in typing. Each waiting one is kept with its timer, so leaving the page can send it straight away.
    const save = (index, note, now) => {
        const send = () => {
            saves.delete(index);
            window.webkit.messageHandlers.noteChanged.postMessage({passage: index, text: textOf(note)});
        };
        if (now) { if (saves.has(index)) { clearTimeout(saves.get(index).timer); send(); } return; }
        clearTimeout(saves.get(index)?.timer);
        saves.set(index, {timer: setTimeout(send, 400), send});
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
        flush() {
            for (const {timer, send} of Array.from(saves.values())) { clearTimeout(timer); send(); }
        },
    };
})();
