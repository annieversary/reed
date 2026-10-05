// Cards after the article, such as one that opens the next. Their elements are inline, so narration never takes them for passages.
window.reedCards = (() => {
    const style = document.createElement('style');
    style.textContent = `
        .reed-next { display: block; margin-top: 64px; padding: 22px 26px; border: 1px solid color-mix(in srgb, var(--muted) 30%, transparent);
                     border-radius: 10px; color: var(--ink); text-decoration: none; cursor: pointer; }
        .reed-next:hover { border-color: var(--accent); }
        .reed-next small { display: block; font: 11px -apple-system, sans-serif; font-weight: 600; letter-spacing: 2px; color: var(--accent); }
        .reed-next .reed-next-source { margin-top: 14px; font-weight: 500; letter-spacing: 1px; color: var(--muted); }
        .reed-next span { display: block; margin-top: 4px; font-size: 1.15em; line-height: 1.35; }
        .reed-next .reed-next-detail { margin-top: 8px; font-size: 12px; font-weight: normal; letter-spacing: 0; color: var(--muted); }
        .reed-next + .reed-next { margin-top: 14px; }`;
    document.head.appendChild(style);
    let shown = [];
    const line = (tag, className, text) => {
        const element = document.createElement(tag);
        if (className) element.className = className;
        element.textContent = text;
        return element;
    };
    return {
        set(cards) {
            shown.forEach(card => card.remove());
            shown = cards.map(next => {
                const card = document.createElement('a');
                card.className = 'reed-next';
                card.href = '#';
                card.append(line('small', '', next.kicker), line('small', 'reed-next-source', next.source), line('span', '', next.title));
                if (next.detail) card.append(line('small', 'reed-next-detail', next.detail));
                card.addEventListener('click', event => {
                    event.preventDefault();
                    window.webkit.messageHandlers.openCard.postMessage(next.id);
                });
                return card;
            });
            const main = document.querySelector('body > main');
            if (main) main.after(...shown); else document.body.append(...shown);
        },
    };
})();
