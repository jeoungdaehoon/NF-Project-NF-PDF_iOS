import assert from 'node:assert/strict';
import { readFileSync, mkdtempSync, writeFileSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { spawnSync } from 'node:child_process';

const root = new URL('../', import.meta.url);
const source = readFileSync(new URL('NFMac/MacPortalWebView.swift', root), 'utf8');
const views = readFileSync(new URL('NFMac/MacPortalViews.swift', root), 'utf8');
assert(!views.includes('MacBreadcrumbBar'), 'native overlay would cover web fullscreen');
assert(!source.includes('NFPortalMacLinkedDocumentPanel'), 'slide width must not resize history');
const bootstrap = source.match(/private static let bootstrapScript = #"""\n([\s\S]*?)\n    """#/)[1];
const script = `
window.__testMacHandlers = new Proxy({}, { get: () => ({postMessage() {}}) });
${bootstrap.replaceAll('window.webkit.messageHandlers.', 'window.__testMacHandlers.')}
const assert = (value, message) => { if (!value) throw new Error(message); };
const wait = () => new Promise(resolve => setTimeout(resolve, 300));
const report = result => {
  document.getElementById('results').textContent = JSON.stringify(result);
  window.webkit?.messageHandlers.testResult.postMessage(JSON.stringify(result));
};
(async () => { try {
  window.__nfMacSetSidebarHidden(true);
  await wait();
  const bar = document.getElementById('__nfMacBreadcrumbBar');
  const content = document.getElementById('portal-content');
  // Isolated/offscreen WebKit cannot reliably advance compositor animations.
  [bar, content, document.getElementById('portal-navigation')].forEach(element => element.style.setProperty('transition', 'none', 'important'));
  await wait();
  const width = content.getBoundingClientRect().width;
  assert(bar?.parentElement === document.body, 'history is not a body web layer');
  assert(getComputedStyle(bar).display === 'flex', 'collapsed-sidebar history is missing');
  assert(bar.getAttribute('aria-label') === '페이지 히스토리', 'history is not accessible');
  assert(bar.querySelector('a')?.textContent === 'NF Portal', 'breadcrumb links lost');
  assert(document.elementFromPoint(14, 12).closest('#__nfMacBreadcrumbBar'), 'history is not visible on normal page: ' + JSON.stringify({hit:document.elementFromPoint(14,12).outerHTML.slice(0,300),bar:bar.getBoundingClientRect().toJSON(),scroll:scrollY,nav:getComputedStyle(document.getElementById('portal-navigation')).transform}));
  const historyWidth = bar.getBoundingClientRect().width;
  const slide = document.createElement('section');
  slide.dataset.linkedDocumentPanel = 'true';
  slide.style.cssText = 'position:fixed;z-index:240;inset:0 0 0 auto;width:50%;background:#17302d;color:white;padding:24px;box-sizing:border-box';
  slide.textContent = '오른쪽 슬라이드 — 히스토리는 이 문서 뒤에 표시됩니다.';
  document.body.append(slide);
  await wait();
  assert(bar.getBoundingClientRect().width === historyWidth, 'slide changed history width');
  assert(content.getBoundingClientRect().width === width, 'slide changed page width');
  assert(slide.contains(document.elementFromPoint(innerWidth - 14, 12)), 'history covers right slide');
  assert(document.elementFromPoint(14, 12).closest('#__nfMacBreadcrumbBar'), 'uncovered history disappeared');
  slide.style.width = '80%';
  await wait();
  assert(bar.getBoundingClientRect().width === historyWidth, 'resizing slide resized history');
  const fullscreen = document.createElement('section');
  fullscreen.dataset.periodFullscreen = 'true';
  fullscreen.style.cssText = 'position:fixed;z-index:10000;inset:0;background:#191919;color:white;padding:24px;box-sizing:border-box';
  fullscreen.innerHTML = '<h2>전체 일정 · 5개</h2><p>히스토리와 슬라이드는 전체화면 뒤에 있습니다.</p>';
  document.body.append(fullscreen);
  await wait();
  assert(fullscreen.contains(document.elementFromPoint(14, 12)), 'history covers fullscreen calendar');
  assert(fullscreen.contains(document.elementFromPoint(innerWidth - 14, 12)), 'slide covers fullscreen calendar');
  assert(fullscreen.getBoundingClientRect().width === innerWidth, 'fullscreen no longer fills viewport');
  assert(bar.getBoundingClientRect().width === historyWidth, 'fullscreen resized history');
  fullscreen.remove(); slide.remove();
  await wait();
  assert(document.elementFromPoint(14, 12).closest('#__nfMacBreadcrumbBar'), 'history did not return after closing fullscreen');
  window.__nfMacSetSidebarPreviewVisible(true, 276);
  await wait();
  assert(Math.abs(bar.getBoundingClientRect().left - 275) < 1, 'sidebar hover covers history: ' + JSON.stringify({left:bar.getBoundingClientRect().left,style:getComputedStyle(bar).left,preview:document.documentElement.dataset.nfMacSidebarPreview}));
  window.__nfMacSetSidebarPreviewVisible(false);
  window.__nfMacSetSidebarHidden(false);
  await wait();
  assert(getComputedStyle(bar).display === 'none', 'pinned-sidebar mode shows duplicate history');
  window.__nfMacSetSidebarHidden(true);
  await wait();
  assert(document.querySelectorAll('#__nfMacBreadcrumbBar').length === 1, 'history duplicated on toggle');
  const title = document.createElement('button');
  title.setAttribute('aria-label', '두 번 선택하면 페이지 최상단으로 이동');
  title.textContent = '변경된 페이지';
  document.querySelector('.portal-titlebar').append(title);
  await wait();
  assert(bar.textContent.includes('변경된 페이지'), 'history does not update after SPA title changes');
  report({ok: true, historyWidth, pageWidth: width});
} catch(error) { report({error: String(error)}); } })(); void 0;`;
const html = `<html><meta charset="utf-8"><style>
:root{--background:#191919;--foreground:#eee;--sidebar-background:#111}
body{margin:0;background:var(--background);color:var(--foreground);font-family:Arial}
#portal-content{height:100vh}.portal-titlebar{height:40px}#results{display:block;margin:40px}
/* Virtual-time Chrome does not advance compositor animations. Test final geometry. */
#__nfMacBreadcrumbBar,#portal-navigation,#portal-content{transition:none!important}
</style><div><aside id="portal-navigation"></aside><div id="portal-content"><header class="portal-titlebar"></header><main><h1>프로젝트 페이지</h1></main></div></div><output id="results"></output></html>`;
const temp = mkdtempSync(path.join(tmpdir(), 'nf-mac-history-'));
try {
  for (const browser of ['chrome', 'webkit']) {
    let result;
    if (browser === 'webkit') {
      const run = spawnSync('/usr/bin/swift', ['-module-cache-path', temp, new URL('test-webkit-dom.swift', import.meta.url).pathname], { input: JSON.stringify({html, script}), encoding: 'utf8', timeout: 55000 });
      assert.equal(run.status, 0, run.stderr || run.stdout); result = JSON.parse(run.stdout.trim());
    } else {
      const fixture = path.join(temp, 'fixture.html');
      writeFileSync(fixture, html + '<script>' + script.replaceAll('</script', '<\\/script') + '</script>');
      const run = spawnSync('/Applications/Google Chrome.app/Contents/MacOS/Google Chrome', ['--headless=new', '--no-sandbox', '--disable-gpu', '--virtual-time-budget=5000', '--window-size=1000,900', '--user-data-dir=' + temp + '/profile', '--dump-dom', 'file://' + fixture], { encoding: 'utf8', timeout: 30000 });
      assert.equal(run.status, 0, run.stderr);
      result = JSON.parse(run.stdout.match(/<output id="results">([^<]+)<\/output>/)[1]);
    }
    assert.equal(result.ok, true, JSON.stringify(result));
    console.log(browser + ': ' + JSON.stringify(result));
  }
} finally { rmSync(temp, {recursive: true, force: true}); }
