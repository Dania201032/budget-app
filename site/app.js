// Сальдо — the site's behaviour: language, theme, the latest release from GitHub, and the motion.
// The only request to another site is the release lookup on api.github.com (cached for the session).
(() => {
  const REPO = 'Dania201032/saldo';
  const $ = (s, r = document) => r.querySelector(s);
  const $$ = (s, r = document) => [...r.querySelectorAll(s)];
  const store = {
    get(k) { try { return localStorage.getItem(k); } catch { return null; } },
    set(k, v) { try { localStorage.setItem(k, v); } catch { /* private mode */ } },
  };
  const reduced = matchMedia('(prefers-reduced-motion: reduce)').matches;

  // ---------- language ----------
  let li = 0;
  const tr = (key, args = []) => {
    const v = T[key];
    let s = v ? (v[li] ?? v[0]) : key;
    args.forEach((a, i) => { s = s.replace(`{${i}}`, a); });
    return s;
  };
  function pickLang() {
    const saved = store.get('lang');
    if (saved && LANGS.includes(saved)) return saved;
    for (const l of navigator.languages || [navigator.language || 'ru']) {
      const code = l.toLowerCase().slice(0, 2);
      if (LANGS.includes(code)) return code;
    }
    return 'ru';
  }
  const sel = $('#lang');
  LANGS.forEach((l, i) => sel.append(new Option(LANG_NAMES[i], l)));

  function applyLang(code) {
    li = Math.max(0, LANGS.indexOf(code));
    document.documentElement.lang = code;
    sel.value = code;
    $$('[data-i18n]').forEach((el) => { el.textContent = tr(el.dataset.i18n); });
    $$('[data-i18n-html]').forEach((el) => { el.innerHTML = tr(el.dataset.i18nHtml); });
    $$('[data-i18n-title]').forEach((el) => { el.title = tr(el.dataset.i18nTitle); });
    document.title = tr('title');
    $('meta[name="description"]').content = tr('description');
    buildHeadline();
    buildLists();
    buildScreens();
    renderRelease();
    resetDemo();
    renderPrice();
  }
  sel.addEventListener('change', () => { store.set('lang', sel.value); applyLang(sel.value); });

  // The headline, word by word, with the hand-drawn mark under one word.
  function buildHeadline() {
    const h1 = $('#h1');
    const text = tr('hero_q');
    const mark = tr('hero_mark');
    let parts;
    if (window.Intl && Intl.Segmenter) {
      parts = [...new Intl.Segmenter(LANGS[li], { granularity: 'word' }).segment(text)].map((s) => s.segment);
    } else {
      parts = text.split(/(\s+)/);
    }
    h1.textContent = '';
    let n = 0;
    parts.forEach((p) => {
      if (/^\s+$/.test(p)) { h1.append(' '); return; }
      const w = document.createElement('span');
      w.className = 'w';
      w.style.animationDelay = `${0.08 + n++ * 0.09}s`;
      if (p === mark) {
        w.classList.add('mark');
        w.innerHTML = `${p}<svg viewBox="0 0 200 20" preserveAspectRatio="none"><path d="M3,14 C50,4 120,4 197,11"/></svg>`;
      } else {
        w.textContent = p;
      }
      h1.append(w);
    });
  }

  // ---------- theme ----------
  const root = document.documentElement;
  const savedTheme = store.get('theme');
  if (savedTheme) root.dataset.theme = savedTheme;
  $('#theme').addEventListener('click', () => {
    const dark = root.dataset.theme ? root.dataset.theme === 'dark' : matchMedia('(prefers-color-scheme: dark)').matches;
    root.dataset.theme = dark ? 'light' : 'dark';
    store.set('theme', root.dataset.theme);
  });

  // ---------- header + reveal ----------
  const top = $('#top');
  addEventListener('scroll', () => top.classList.toggle('scrolled', scrollY > 8), { passive: true });
  const io = new IntersectionObserver((es) => es.forEach((e) => {
    if (e.isIntersecting) { e.target.classList.add('in'); io.unobserve(e.target); }
  }), { threshold: 0.18 });
  const observe = () => $$('.reveal:not(.in), .step:not(.in), #net:not(.in)').forEach((el) => io.observe(el));

  // ---------- generated lists ----------
  const ICONS = {
    today: '<path d="M12 3v18M5 8h11a3 3 0 0 1 0 6H8a3 3 0 0 0 0 6h11"/>',
    cats: '<rect x="3" y="4" width="18" height="17" rx="3"/><path d="M3 9h18M8 2v4M16 2v4"/>',
    forecast: '<path d="M3 17l5-5 4 3 8-8"/><path d="M15 7h5v5"/>',
    goals: '<circle cx="12" cy="12" r="9"/><circle cx="12" cy="12" r="5"/><circle cx="12" cy="12" r="1.5"/>',
    cur: '<circle cx="9" cy="9" r="6"/><path d="M14.5 4.5a6 6 0 1 1-4.9 15.4"/>',
    capital: '<path d="M3 21h18M5 21V10M10 21V10M14 21V10M19 21V10M2 10l10-6 10 6"/>',
    lock: '<rect x="4" y="10" width="16" height="11" rx="3"/><path d="M8 10V7a4 4 0 0 1 8 0v3"/>',
    devices: '<rect x="2" y="4" width="15" height="11" rx="2"/><path d="M6 19h7"/><rect x="17" y="8" width="5" height="12" rx="1.5"/>',
    check: '<path d="M4 12l5 5L20 6"/>',
  };
  const svg = (k) => `<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round">${ICONS[k]}</svg>`;

  function buildLists() {
    const feats = [['today', 'f1'], ['cats', 'f2'], ['forecast', 'f3'], ['goals', 'f4'], ['cur', 'f5'], ['capital', 'f6'], ['lock', 'f7'], ['devices', 'f8']];
    $('#feats').innerHTML = feats.map(([ic, k], i) =>
      `<div class="feat reveal" style="--delay:${(i % 4) * 0.08}s"><div class="fi">${svg(ic)}</div><h3>${tr(k + '_t')}</h3><p>${tr(k)}</p></div>`).join('');
    $('#checks').innerHTML = ['pv1', 'pv2', 'pv3', 'pv4'].map((k, i) =>
      `<li class="reveal" style="--delay:${i * 0.1}s"><div class="ck">${svg('check')}</div><div><h3>${tr(k + '_t')}</h3><p>${tr(k)}</p></div></li>`).join('');
    const pe = ['🔄', '👫', '📄', '✉️', '📈', '🧾', '📷'];
    $('#pf').innerHTML = pe.map((e, i) =>
      `<li><span class="pi">${e}</span><div><b>${tr(`p${i + 1}_t`)}</b><span>${tr(`p${i + 1}`)}</span></div></li>`).join('');
    buildNet();
    observe();
  }

  // The phone in the middle; every way out is crossed out.
  function buildNet() {
    const nodes = [
      { x: 70, y: 80, k: 'net_cloud', e: '☁️' }, { x: 430, y: 80, k: 'net_ads', e: '📢' },
      { x: 70, y: 420, k: 'net_track', e: '📊' }, { x: 430, y: 420, k: 'net_dev', e: '👤' },
    ];
    $('#links').innerHTML = nodes.map((n, i) => {
      const mx = 250 + (n.x - 250) * 0.55, my = 250 + (n.y - 250) * 0.55;
      const dx = (n.x - 250) * 0.5, dy = (n.y - 250) * 0.5;
      return `<line class="line" x1="250" y1="250" x2="${n.x}" y2="${n.y}"/>
        <circle class="pkt" r="6" cx="250" cy="250" style="--dx:${dx}px;--dy:${dy}px;animation:pkt 2.8s ${i * 0.7}s infinite cubic-bezier(.4,0,.2,1)"/>
        <path class="x" style="--xd:${0.6 + i * 0.25}s" d="M${mx - 13},${my - 13} L${mx + 13},${my + 13} M${mx + 13},${my - 13} L${mx - 13},${my + 13}"/>
        <circle class="cloud" cx="${n.x}" cy="${n.y}" r="40"/>
        <text x="${n.x}" y="${n.y + 9}" text-anchor="middle" font-size="26">${n.e}</text>
        <text class="lbl" x="${n.x}" y="${n.y + 62}">${tr(n.k)}</text>`;
    }).join('');
    $('#zero').textContent = tr('chip_zero');
  }

  // ---------- screens ----------
  const CATS = [
    { k: 'c_food', v: 9800, c: 'var(--accent)' }, { k: 'c_coffee', v: 3100, c: 'var(--gold)' },
    { k: 'c_metro', v: 2200, c: '#6BA6D6' }, { k: 'c_books', v: 1900, c: '#9C8CD0' }, { k: 'm_other', v: 2400, c: 'var(--rule)' },
  ];
  function buildScreens() {
    const total = CATS.reduce((a, c) => a + c.v, 0);
    const C = 2 * Math.PI * 52;
    let off = 0;
    $('#donut').innerHTML = CATS.map((c) => {
      const len = (c.v / total) * C;
      const s = `<circle cx="75" cy="75" r="52" style="stroke:${c.c};stroke-dashoffset:${-off};--len:${len - 2}"/>`;
      off += len;
      return s;
    }).join('') + `<text x="75" y="82" text-anchor="middle" class="mono" style="font:600 18px PlexMono,monospace;fill:var(--ink)">${fmt(total)}</text>`;
    $('#legend').innerHTML = CATS.map((c) => `<div><i style="background:${c.c}"></i><span>${tr(c.k)}</span><span class="mono">${fmt(c.v)}</span></div>`).join('');
    $('#miniList').innerHTML = DEMO.slice(0, 4).map(rowHtml).join('');
    $('#calMonth').textContent = new Intl.DateTimeFormat(LANGS[li], { month: 'long', year: 'numeric' }).format(new Date(2026, 9, 1));
    let cal = '';
    for (let d = 1; d <= 31; d++) {
      const h = [0, 1, 1, 2, 0, 1, 3, 1, 2, 0, 1][(d * 7) % 11];
      cal += `<div class="${h ? 'h' + h : ''}">${d}</div>`;
    }
    $('#cal').innerHTML = cal;
  }

  // ---------- the phone demo ----------
  const DEMO = [
    { app: 'Alipay', ic: '支', col: '#1677FF', who: 'Luckin Coffee', src: '¥38.00', rub: 390, cat: 'c_coffee', e: '☕' },
    { app: 'Т-Банк', ic: 'Т', col: '#2B2B2B', who: 'Пятёрочка', src: '860 ₽', rub: 860, cat: 'c_food', e: '🛒' },
    { app: 'WeChat Pay', ic: '微', col: '#07C160', who: 'Shanghai Metro', src: '¥4.00', rub: 41, cat: 'c_metro', e: '🚇' },
    { app: 'Сбер', ic: 'С', col: '#21A038', who: 'Столовая', src: '320 ₽', rub: 320, cat: 'c_lunch', e: '🍲' },
    { app: 'Alipay', ic: '支', col: '#1677FF', who: 'Book City', src: '¥59.00', rub: 605, cat: 'c_books', e: '📚' },
  ];
  function fmt(n) { return Math.round(n).toLocaleString('ru-RU').replace(/,/g, ' '); }
  function rowHtml(d) {
    return `<li><span class="cat">${d.e}</span><span><div class="t">${tr(d.cat)}</div><div class="s">${d.who} · ${d.app}</div></span><span class="a mono">−${fmt(d.rub)} ₽</span></li>`;
  }
  let step = 0, today = 1240, monthLeft = 18600, timer = 0;
  const todayEl = $('#today'), list = $('#list'), notif = $('#notif'), toast = $('#toast');

  function countTo(el, from, to, suffix) {
    if (reduced) { el.textContent = fmt(to) + suffix; return; }
    const t0 = performance.now(), dur = 900;
    const tick = (t) => {
      const k = Math.min(1, (t - t0) / dur), e = 1 - Math.pow(1 - k, 3);
      el.textContent = fmt(from + (to - from) * e) + suffix;
      if (k < 1) requestAnimationFrame(tick);
    };
    requestAnimationFrame(tick);
  }
  function resetDemo() {
    clearTimeout(timer);
    step = 3; today = 1240; monthLeft = 18600;
    list.innerHTML = DEMO.slice(0, 3).reverse().map(rowHtml).join('');
    todayEl.textContent = fmt(today) + ' ₽';
    $('#mleft').textContent = fmt(monthLeft) + ' ₽';
    $('#mbar').style.width = '62%';
    timer = setTimeout(play, reduced ? 4000 : 1600);
  }
  function play() {
    const d = DEMO[step++ % DEMO.length];
    $('#nIc').textContent = d.ic;
    $('#nIc').style.background = d.col;
    $('#nApp').textContent = d.app;
    $('#nBody').textContent = `${tr('demo_pay')} ${d.src} · ${d.who}`;
    notif.classList.remove('show'); void notif.offsetWidth; notif.classList.add('show');
    timer = setTimeout(() => {
      list.insertAdjacentHTML('afterbegin', rowHtml(d));
      list.firstElementChild.classList.add('new');
      while (list.children.length > 5) list.lastElementChild.remove();
      toast.textContent = tr('demo_recorded', [`${tr(d.cat)} −${fmt(d.rub)} ₽`]);
      toast.classList.remove('show'); void toast.offsetWidth; toast.classList.add('show');
      let next = today - d.rub;
      if (next < 150) next = 1240; // a new day
      countTo(todayEl, today, next, ' ₽');
      today = next;
      const ml = monthLeft - d.rub > 4000 ? monthLeft - d.rub : 18600;
      countTo($('#mleft'), monthLeft, ml, ' ₽');
      monthLeft = ml;
      $('#mbar').style.width = `${Math.round((1 - monthLeft / 30000) * 100)}%`;
      todayEl.classList.add('tick');
      setTimeout(() => todayEl.classList.remove('tick'), 900);
      timer = setTimeout(play, 3300);
    }, 2200);
  }
  const clock = () => { const n = new Date(); $('#clock').textContent = `${n.getHours()}:${String(n.getMinutes()).padStart(2, '0')}`; };
  clock(); setInterval(clock, 30000);

  // Currencies and moments running across the page.
  const tk = ['<b>₽</b> RUB', '<b>¥</b> CNY', '<b>$</b> USD', '<b>€</b> EUR', '<b>₸</b> KZT', '<b>£</b> GBP', '<b>₺</b> TRY', '<b>֏</b> AMD', '<b>₾</b> GEL', '<b>฿</b> THB', '<b>₩</b> KRW', '<b>Br</b> BYN'];
  $('#ticker').innerHTML = [...tk, ...tk].map((s) => `<span>${s}</span>`).join('');

  // ---------- install tabs ----------
  $$('.tabs button').forEach((b) => b.addEventListener('click', () => {
    $$('.tabs button').forEach((x) => x.setAttribute('aria-selected', x === b ? 'true' : 'false'));
    $$('.pane').forEach((p) => { p.hidden = p.dataset.pane !== b.dataset.tab; });
  }));
  if (/Windows NT/.test(navigator.userAgent) && !/Android/.test(navigator.userAgent)) $('[data-tab="windows"]').click();

  // ---------- Plus: month / year, SBP in rubles / Alipay in yuan ----------
  // A segmented control: the knob sits under the chosen button and follows it when the
  // buttons change width (another language, fonts loading).
  function seg(el, onPick) {
    const knob = $('.knob', el);
    const place = () => { const on = $('button.on', el); knob.style.left = on.offsetLeft + 'px'; knob.style.width = on.offsetWidth + 'px'; };
    $$('button', el).forEach((b) => b.addEventListener('click', () => {
      $$('button', el).forEach((x) => x.classList.toggle('on', x === b));
      place();
      onPick(b);
    }));
    new ResizeObserver(place).observe(el);
    $$('button', el).forEach((b) => new ResizeObserver(place).observe(b));
  }
  // Same prices as the buy page (buy.js) and the sales bot (saldo_shop/bin/bot.dart). The card shows
  // the language's usual currency; buying itself is on buy.html.
  const PRICES = { month: { sbp: 149, ali: 15, stars: 100 }, year: { sbp: 990, ali: 99, stars: 650 } };
  const CUR = { sbp: '₽', ali: '¥', stars: '⭐' };
  let per = 'year';
  function renderPrice() {
    const main = LANGS[li] === 'zh' ? 'ali' : 'sbp';
    const amount = PRICES[per][main];
    countTo($('#amt'), Number($('#amt').textContent.replace(/\D/g, '')) || amount, amount, '');
    $('#amtl').textContent = tr(per === 'year' ? 'pr_year' : 'pr_month', [CUR[main]]);
    $('#save').classList.toggle('off', per !== 'year');
    const others = Object.keys(CUR).filter((k) => k !== main).map((k) => `${PRICES[per][k]} ${CUR[k]}`).join(' · ');
    $('#altPrices').textContent = tr('pr_or', [others]);
    $('#buyBtn').href = `buy.html?plan=${per}`;
  }
  seg($('#period'), (b) => { per = b.dataset.per; renderPrice(); });

  // ---------- phones: the menu and the download dock ----------
  const menu = $('#menu'), nav = $('#nav');
  const setMenu = (open) => { nav.classList.toggle('open', open); menu.setAttribute('aria-expanded', String(open)); top.classList.toggle('menu-open', open); };
  menu.addEventListener('click', () => setMenu(!nav.classList.contains('open')));
  $$('a', nav).forEach((a) => a.addEventListener('click', () => setMenu(false)));
  addEventListener('keydown', (e) => { if (e.key === 'Escape') setMenu(false); });
  document.addEventListener('click', (e) => { if (!top.contains(e.target)) setMenu(false); });

  // Shown once the hero's buttons are out of sight, hidden again where buttons are on screen.
  const dock = $('#dock');
  const seen = new Set();
  const dockIo = new IntersectionObserver((es) => {
    es.forEach((e) => (e.isIntersecting ? seen.add(e.target) : seen.delete(e.target)));
    const past = $('.hero .btns').getBoundingClientRect().bottom < 0;
    dock.classList.toggle('show', past && seen.size === 0);
  });
  [$('.hero .btns'), $('.band'), $('#plus .price'), $('footer')].forEach((el) => dockIo.observe(el));

  // ---------- the latest release ----------
  let release = null;
  async function loadRelease() {
    try {
      const cached = sessionStorage.getItem('rel');
      if (cached) release = JSON.parse(cached);
    } catch { /* no storage */ }
    if (!release) {
      try {
        const r = await fetch(`https://api.github.com/repos/${REPO}/releases/latest`, { headers: { Accept: 'application/vnd.github+json' } });
        if (!r.ok) return;
        const j = await r.json();
        const find = (exact, re) => j.assets.find((a) => a.name === exact) || j.assets.find((a) => re.test(a.name));
        const apk = find('Saldo.apk', /\.apk$/i), win = find('Saldo-windows.zip', /windows\.zip$/i);
        release = {
          v: j.tag_name.replace(/^v/, ''), date: j.published_at, page: j.html_url,
          apk: apk && { url: apk.browser_download_url, size: apk.size },
          win: win && { url: win.browser_download_url, size: win.size },
        };
        try { sessionStorage.setItem('rel', JSON.stringify(release)); } catch { /* no storage */ }
      } catch { return; }
    }
    renderRelease();
  }
  function renderRelease() {
    if (!release) return;
    const mb = (b) => `${(b / 1048576).toFixed(0)} MB`;
    if (release.apk) $$('.dl-android').forEach((a) => { a.href = release.apk.url; });
    if (release.win) {
      $$('.dl-windows').forEach((a) => { a.href = release.win.url; });
      $('.size-win').textContent = `Windows 10/11 · ${mb(release.win.size)}`;
    }
    if (release.apk) $('.size-apk').textContent = `${tr('free_note')} · ${mb(release.apk.size)}`;
    const date = new Intl.DateTimeFormat(LANGS[li], { day: 'numeric', month: 'long', year: 'numeric' }).format(new Date(release.date));
    $('#release').innerHTML = `<a href="https://github.com/${REPO}/releases">${tr('release_line', [release.v, date])}</a>`;
  }

  applyLang(pickLang());
  loadRelease();
})();
