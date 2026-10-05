// Progress runs to the end of the article rather than the page, so what's added after it once it's open,
// such as the cards that follow it, doesn't move a position already saved.
window.reedProgress = {
    distance() {
        const main = document.querySelector('main');
        const end = main ? main.getBoundingClientRect().bottom + window.scrollY : document.documentElement.scrollHeight;
        return end - window.innerHeight;
    },
    // Images change the page's height as they load, so it's restored again once they have, unless you've started
    // scrolling; a slow image only keeps the page hidden briefly.
    restore(progress) {
        const restore = () => window.scrollTo(0, progress * Math.max(0, reedProgress.distance()));
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
    },
};
// Throttled rather than debounced, so progress keeps updating during one long scroll.
let lastReport = 0, trailing;
const report = () => {
    lastReport = Date.now();
    const distance = reedProgress.distance();
    if (distance > 0) window.webkit.messageHandlers.readingProgress.postMessage(Math.min(window.scrollY / distance, 1));
};
window.addEventListener('scroll', () => {
    clearTimeout(trailing);
    if (Date.now() - lastReport >= 150) report();
    else trailing = setTimeout(report, 150);
}, {passive:true});
