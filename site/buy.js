// Сальдо — the buy page. No server here either: the page makes the order code itself (W + 5 digits),
// the buyer pays by the QR with that code in the transfer comment, and the sales bot (saldo_shop)
// recognises the code in the bank's e-mail or when the buyer opens it from the "Get the key" button.
(() => {
  const $ = (s, r = document) => r.querySelector(s);
  const $$ = (s, r = document) => [...r.querySelectorAll(s)];
  const store = {
    get(k, s = localStorage) { try { return s.getItem(k); } catch { return null; } },
    set(k, v, s = localStorage) { try { s.setItem(k, v); } catch { /* private mode */ } },
  };

  // Same prices as the sales bot (saldo_shop/bin/bot.dart) and the main page.
  const PRICES = { month: { sbp: 149, ali: 15, stars: 100 }, year: { sbp: 990, ali: 99, stars: 650 } };
  const CUR = { sbp: '₽', ali: '¥', stars: '⭐' };
  const QR = { sbp: 'sbp-qr.png', ali: 'alipay-qr.png' };
  const BOT = 'https://t.me/Saldobudget_bot';
  const mailRe = /^[^@\s]+@[^@\s]+\.[^@\s]{2,}$/;
  const esc = (s) => s.replace(/[&<>"]/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' })[c]);

  // ---------- language and theme (as on the main page) ----------
  let li = 0;
  const tr = (key, args = []) => {
    const v = T[key];
    let s = v ? (v[li] ?? v[0]) : key;
    args.forEach((a, i) => { s = s.replaceAll(`{${i}}`, a); });
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
  const root = document.documentElement;
  const savedTheme = store.get('theme');
  if (savedTheme) root.dataset.theme = savedTheme;
  $('#theme').addEventListener('click', () => {
    const dark = root.dataset.theme ? root.dataset.theme === 'dark' : matchMedia('(prefers-color-scheme: dark)').matches;
    root.dataset.theme = dark ? 'light' : 'dark';
    store.set('theme', root.dataset.theme);
  });
  addEventListener('scroll', () => $('#top').classList.toggle('scrolled', scrollY > 8), { passive: true });
  const botLang = () => ({ ru: 'ru', kk: 'ru', zh: 'zh' })[LANGS[li]] || 'en';

  // ---------- the order ----------
  // One code per visit, kept across reloads of this tab so a buyer who already paid sees the same one.
  let code = store.get('buyCode', sessionStorage);
  if (!/^W\d{5}$/.test(code || '')) {
    code = 'W' + (10000 + (crypto.getRandomValues(new Uint32Array(1))[0] % 90000));
    store.set('buyCode', code, sessionStorage);
  }
  const q = new URLSearchParams(location.search);
  const st = {
    plan: PRICES[q.get('plan')] ? q.get('plan') : 'year',
    pay: CUR[q.get('pay')] ? q.get('pay') : null,
    to: store.get('buyTo') === 'mail' ? 'mail' : 'tg',
  };
  const open = { stars: true, sbp: false, ali: false }; // SBP and Alipay open when their QR is on the site
  const qrImg = {};
  $('#mail').value = store.get('buyMail') || '';

  function defaultPay() {
    const want = { ru: 'sbp', kk: 'sbp', zh: 'ali' }[LANGS[li]] || 'stars';
    return open[want] ? want : 'stars';
  }

  function pick(group, attr, value) {
    $$(`[data-${attr}]`, group).forEach((b) => {
      const on = b.dataset[attr] === value;
      b.classList.toggle('on', on);
      b.setAttribute('aria-checked', String(on));
    });
  }

  function render() {
    // The chosen way, or the language's usual one, once it is open; Stars until then.
    const pay = st.pay && open[st.pay] ? st.pay : defaultPay();
    const { plan, to } = st;
    const amount = `${PRICES[plan][pay]} ${CUR[pay]}`;
    pick($('#s-plan'), 'plan', plan);
    pick($('#s-pay'), 'pay', pay);
    pick($('#s-to'), 'to', to);
    $$('[data-price]').forEach((el) => { el.textContent = `${PRICES[el.dataset.price][pay]} ${CUR[pay]}`; });
    $$('#s-pay [data-pay]').forEach((b) => {
      b.disabled = !open[b.dataset.pay];
      b.classList.toggle('closed', !open[b.dataset.pay]);
    });

    const qr = pay !== 'stars';
    $('#s-stars').hidden = qr;
    $('#s-to').hidden = !qr;
    $('#s-qr').hidden = !qr;
    if (!qr) {
      $('#starsBtn').href = `${BOT}?start=${plan}_stars_${botLang()}`;
      $('#starsLbl').textContent = tr('b_stars_btn', [amount]);
      return;
    }

    const mail = $('#mail').value.trim();
    const mailOk = mailRe.test(mail);
    $('#mailField').hidden = to !== 'mail';
    $('#mail').classList.toggle('bad', to === 'mail' && mail !== '' && !mailOk);
    const ready = to === 'tg' || mailOk;
    $('#needMail').hidden = ready;
    $('#paycard').classList.toggle('locked', !ready);

    const box = $('#qr');
    box.innerHTML = '';
    if (qrImg[pay]) box.append(qrImg[pay]);
    $('#saveQr').href = QR[pay];
    $('#saveQr').setAttribute('download', `saldo-${pay === 'ali' ? 'alipay' : 'sbp'}-qr.png`);
    $('#sum').textContent = amount;
    $('#comment').textContent = to === 'mail' && mailOk ? `${code} ${mail}` : code;

    const steps = [tr(pay === 'ali' ? 'b_ali1' : 'b_sbp1'), tr(pay === 'ali' ? 'b_ali2' : 'b_sbp2', [amount])];
    if (to === 'tg') steps.push(tr(pay === 'ali' ? 'b_tg_ali' : 'b_tg_sbp'));
    else steps.push(tr(pay === 'ali' ? 'b_mail_ali' : 'b_mail_sbp', [esc(mailOk ? mail : tr('b_to_mail').toLowerCase())]));
    $('#howpay').innerHTML = steps.map((s) => `<li>${s}</li>`).join('');
    $('#claimBtn').hidden = to !== 'tg';
    $('#claimBtn').href = `${BOT}?start=get_${code}_${plan}_${pay}_${botLang()}`;
  }

  $$('#s-plan [data-plan]').forEach((b) => b.addEventListener('click', () => { st.plan = b.dataset.plan; render(); }));
  $$('#s-pay [data-pay]').forEach((b) => b.addEventListener('click', () => {
    if (!open[b.dataset.pay]) return;
    st.pay = b.dataset.pay;
    render();
  }));
  $$('#s-to [data-to]').forEach((b) => b.addEventListener('click', () => {
    st.to = b.dataset.to;
    store.set('buyTo', st.to);
    render();
    if (st.to === 'mail') $('#mail').focus();
  }));
  $('#mail').addEventListener('input', () => { store.set('buyMail', $('#mail').value.trim()); render(); });

  $('#copy').addEventListener('click', async () => {
    const text = $('#comment').textContent;
    try {
      await navigator.clipboard.writeText(text);
    } catch {
      const r = document.createRange(); r.selectNodeContents($('#comment'));
      getSelection().removeAllRanges(); getSelection().addRange(r);
      return;
    }
    $('#copy').textContent = tr('b_copied');
    setTimeout(() => { $('#copy').textContent = tr('b_copy'); }, 1600);
  });

  // The QR images decide which ways are open.
  Object.entries(QR).forEach(([k, src]) => {
    const img = new Image();
    img.alt = 'QR ' + (k === 'ali' ? 'Alipay' : 'СБП');
    img.onload = () => { qrImg[k] = img; open[k] = true; render(); };
    img.src = src;
  });

  function applyLang(lang) {
    li = Math.max(0, LANGS.indexOf(lang));
    root.lang = lang;
    sel.value = lang;
    $$('[data-i18n]').forEach((el) => { el.textContent = tr(el.dataset.i18n); });
    $$('[data-i18n-title]').forEach((el) => { el.title = tr(el.dataset.i18nTitle); });
    document.title = tr('b_page');
    render();
  }
  sel.addEventListener('change', () => { store.set('lang', sel.value); applyLang(sel.value); });
  applyLang(pickLang());
})();
