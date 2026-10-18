(() => {
  'use strict';
  const assets = [...document.querySelectorAll('.asset')];
  const search = document.querySelector('#search');
  const filterButtons = [...document.querySelectorAll('[data-filter]')];
  const viewer = document.querySelector('#viewer');
  const original = document.querySelector('#viewer-original');
  let filter = 'all';
  let current = null;
  let opener = null;
  const normalize = s => s.toLocaleLowerCase('ru').replaceAll('ё','е').trim();
  function update() {
    const terms = normalize(search.value).split(/\s+/).filter(Boolean);
    let count = 0;
    assets.forEach(asset => {
      const text = normalize(asset.dataset.search);
      asset.hidden = !(filter === 'all' || asset.dataset.kind === filter) || !terms.every(term => text.includes(term));
      document.querySelector(`[data-nav="${asset.id}"]`).hidden = asset.hidden;
      if (!asset.hidden) count++;
    });
    document.querySelectorAll('[data-nav-group]').forEach(group => {
      group.hidden = ![...group.querySelectorAll('li')].some(li => !li.hidden);
    });
    filterButtons.forEach(button => button.setAttribute('aria-pressed', String(button.dataset.filter === filter)));
    document.querySelector('#result-count').textContent = `Показано ${count} из 48`;
    document.querySelector('#empty').hidden = count !== 0;
  }
  search.addEventListener('input', update);
  document.querySelector('#clear').addEventListener('click', () => { search.value=''; update(); search.focus(); });
  document.querySelector('#reset').addEventListener('click', () => { search.value=''; filter='all'; update(); search.focus(); });
  filterButtons.forEach(button => button.addEventListener('click', () => { filter=button.dataset.filter; update(); }));
  function show(asset) {
    current = asset;
    const list = assets.filter(a => !a.hidden);
    const position = list.indexOf(asset);
    document.querySelector('#viewer-title').textContent = asset.querySelector('h3').textContent;
    document.querySelector('#viewer-caption').textContent = `${position+1} из ${list.length} · ${asset.querySelector('.meta').innerText.replace(/\s+/g,' ')}`;
    const image = document.querySelector('#viewer-image');
    image.src = asset.querySelector('img').getAttribute('src');
    image.alt = asset.querySelector('img').alt;
    original.href = asset.querySelector('.original').getAttribute('href');
    document.querySelector('#viewer-panels').textContent = [...asset.querySelectorAll('.panels li')].map(li => li.textContent.replace(/^(\d+\.\d)/,'$1 · ')).join('   /   ');
    document.querySelector('#prev').disabled = position <= 0;
    document.querySelector('#next').disabled = position === list.length-1;
    if (!viewer.open) { viewer.showModal(); document.querySelector('#close').focus(); }
    viewer.scrollTop=0;
  }
  document.querySelectorAll('[data-open]').forEach(link => link.addEventListener('click', event => {
    if (event.ctrlKey || event.metaKey || event.shiftKey || event.altKey || !viewer.showModal) return;
    event.preventDefault(); opener=link; show(document.getElementById(link.dataset.open));
  }));
  function step(delta) {
    const list=assets.filter(a => !a.hidden);
    const next=list[list.indexOf(current)+delta];
    if (next) show(next);
  }
  document.querySelector('#prev').addEventListener('click', () => step(-1));
  document.querySelector('#next').addEventListener('click', () => step(1));
  document.querySelector('#close').addEventListener('click', () => viewer.close());
  viewer.addEventListener('close', () => { if(opener) opener.focus(); });
  viewer.addEventListener('keydown', event => {
    if (event.key==='ArrowLeft') { event.preventDefault(); step(-1); }
    if (event.key==='ArrowRight') { event.preventDefault(); step(1); }
  });
  // Direct hash navigation should reveal a target hidden by the current search.
  function revealHash() {
    const target=document.getElementById(location.hash.slice(1));
    if (target?.classList.contains('asset') && target.hidden) {
      search.value=''; filter='all'; update(); target.scrollIntoView();
    }
  }
  window.addEventListener('hashchange',revealHash);
  update(); revealHash();
})();
