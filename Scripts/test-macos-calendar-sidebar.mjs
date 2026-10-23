import assert from 'node:assert/strict';
import { readFileSync, mkdtempSync, writeFileSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { spawnSync } from 'node:child_process';

const root = new URL('../', import.meta.url);
const source = readFileSync(new URL('NFMac/MacPortalWebView.swift', root), 'utf8');
const bootstrap = source.match(/private static let bootstrapScript = #"""\n([\s\S]*?)\n    """#/)[1]
  .replaceAll('window.webkit.messageHandlers.', 'window.__testMacHandlers.');
// Cross-repository integration: use the web calendar's real portal CSS rather
// than copying its z-index into this native regression test.
const webRoot = process.env.NF_PORTAL_WEB_ROOT
  ? new URL('file://' + path.resolve(process.env.NF_PORTAL_WEB_ROOT) + '/')
  : new URL('../nf-project-portal/', root);
const calendarCSS = readFileSync(new URL('src/components/project-month-calendar.css', webRoot), 'utf8');
const frameHTML = `<html><meta charset="utf-8"><style>
:root{--background:#111;--foreground:#eee;--sidebar-background:#222}
body{margin:0;background:#111;color:#eee;font:14px Arial}
#shell{height:100vh}#portal-content{height:100vh}
#portal-navigation{position:fixed;inset:0 auto 0 0;z-index:90;width:276px;height:100vh;background:#222;overflow:auto}
#menu-item{display:block;width:240px;height:240px;padding:0;border:0;background:#222;color:white}
#portal-navigation, #portal-content, #__nfMacBreadcrumbBar{transition:none!important}
</style><style>${calendarCSS}</style><div id="shell"><aside id="portal-navigation"><button id="menu-item">전체 메뉴 항목</button></aside><div id="portal-content"><header class="portal-titlebar"><button aria-controls="portal-navigation" aria-expanded="false">열기</button></header><main>본문</main></div></div></html>`;
const script = `
let stage='initial';
const report=result=>{document.getElementById('results').textContent=JSON.stringify(result);window.webkit?.messageHandlers.testResult.postMessage(JSON.stringify(result))};
const deadline=setTimeout(()=>report({error:'Fixture timed out at '+stage}),14000);
(async()=>{try{
  let checks=0,clicks=0;const assert=(value,message)=>{if(!value)throw Error(message);checks++};
  const wait=()=>new Promise(resolve=>setTimeout(resolve,300));
  // Two independent documents model the two WKWebViews, so a left-pane style
  // must not change right-pane geometry, hit targets or sidebar state. Offscreen
  // WKWebView does not reliably run child-frame timers, so validate its actual
  // host CSS in the main document; Chrome also covers split widths/isolation.
  const splitDocuments=!!document.getElementById('left');
  const setup=win=>{win.__testMacHandlers=new Proxy({},{get:()=>({postMessage(){}})});win.eval(${JSON.stringify(bootstrap)});for(const name of ['portal-navigation','portal-content','__nfMacBreadcrumbBar'])win.document.getElementById(name)?.style.setProperty('transition','none','important');return win};
  const create=id=>{const win=document.getElementById(id).contentWindow;win.document.open();win.document.write(${JSON.stringify(frameHTML)});win.document.close();return setup(win)};
  stage='create left';const left=splitDocuments?create('left'):setup(window);stage='create right';const right=splitDocuments?create('right'):null;stage='initial wait';await wait();
  const doc=left.document,nav=doc.getElementById('portal-navigation');
  const hit=()=>doc.elementFromPoint(80,120);
  const isMenu=()=>Boolean(hit()?.closest('#portal-navigation'));
  const rightSnapshot=()=>right?JSON.stringify({sidebar:right.getComputedStyle(right.document.getElementById('portal-navigation')).zIndex,preview:right.document.documentElement.dataset.nfMacSidebarPreview,hidden:right.__nfMacSidebarHidden,width:right.document.getElementById('portal-content').getBoundingClientRect().width}):null;
  const rightBefore=rightSnapshot();
  doc.getElementById('menu-item').onclick=()=>clicks++;
  for(const width of splitDocuments?[480,760]:[innerWidth]) {
    stage='width '+width;
    if(splitDocuments)document.getElementById('left').style.width=width+'px';await wait();
    left.__nfMacSetSidebarHidden(true);left.__nfMacSetSidebarPreviewVisible(false);await wait();
    assert(!isMenu(),'collapsed menu intercepts normal page');
    const calendar=doc.createElement('div');calendar.className='project-month-calendar';calendar.dataset.projectMonthCalendar='true';calendar.textContent='일정 달력';doc.body.append(calendar);
    assert(hit()===calendar,'calendar is not visible before opening menu');
    const calendarFrame=JSON.stringify(calendar.getBoundingClientRect().toJSON());
    left.__nfMacSetSidebarPreviewVisible(true,276);await wait();
    assert(isMenu(),'hover menu is behind calendar at width '+width);
    assert(Number(left.getComputedStyle(nav).zIndex)>Number(left.getComputedStyle(calendar).zIndex),'menu has wrong stacking order');
    const beforeHoverClick=clicks;hit().click();assert(clicks===beforeHoverClick+1,'visible menu cannot receive a click');
    assert(doc.elementFromPoint(width-20,120)===calendar,'menu hides the entire calendar instead of only its own area');
    left.__nfMacSetSidebarPreviewVisible(false);await wait();
    assert(hit()===calendar,'calendar does not return after hover menu closes');
    assert(JSON.stringify(calendar.getBoundingClientRect().toJSON())===calendarFrame,'hover menu resized or moved calendar');
    left.__nfMacSetSidebarHidden(false);await wait();
    assert(isMenu(),'pinned menu is behind calendar at width '+width);
    const beforeClick=clicks;hit().click();assert(clicks===beforeClick+1,'pinned menu cannot receive a click');
    left.__nfMacSetSidebarHidden(true);await wait();assert(hit()===calendar,'calendar does not return after pinned menu closes');
    if(right)assert(rightSnapshot()===rightBefore,'left menu changed the right split pane');
    // Keep higher-priority document slides, dialogs and period fullscreen above
    // the menu; only the month-calendar layering is changed.
    left.__nfMacSetSidebarPreviewVisible(true,276);await wait();
    for(const layer of [240,280,320,10000]) {
      const modal=doc.createElement('div');modal.style.cssText='position:fixed;inset:0;background:#333;z-index:'+layer;doc.body.append(modal);
      assert(hit()===modal,'menu covers a document/modal at layer '+layer);modal.remove();
    }
    calendar.remove();assert(Number(left.getComputedStyle(nav).zIndex)===90,'normal page menu layer was changed');
    assert(isMenu(),'normal page menu disappeared after closing calendar');
    if(right)assert(rightSnapshot()===rightBefore,'closing calendar changed right split pane');
    // The override is macOS-only; web/mobile stacking stays unchanged.
    doc.body.append(calendar);doc.documentElement.removeAttribute('data-nf-desktop-host');
    assert(Number(left.getComputedStyle(nav).zIndex)===90,'non-macOS menu layer was changed');
    doc.documentElement.setAttribute('data-nf-desktop-host','true');calendar.remove();
  }
  clearTimeout(deadline);report({ok:true,checks,menuClicks:clicks,splitDocuments});
}catch(error){clearTimeout(deadline);report({error:String(error),stage})}})();void 0;
`;
const html = '<html><style>body{margin:0;display:flex}iframe{border:0;height:900px;flex:none}#left{width:760px}#right{width:700px}</style><iframe id="left"></iframe><iframe id="right"></iframe><output id="results"></output></html>';
const temp = mkdtempSync(path.join(tmpdir(), 'nf-mac-calendar-sidebar-'));
try {
  for (const browser of ['chrome', 'webkit']) {
    let result;
    if (browser === 'webkit') {
      const run = spawnSync('/usr/bin/swift', ['-module-cache-path', temp, new URL('test-webkit-dom.swift', import.meta.url).pathname], { input: JSON.stringify({html:frameHTML+'<output id="results"></output>', script}), encoding: 'utf8', timeout: 55000 });
      assert.equal(run.status, 0, run.stderr || run.stdout); result = JSON.parse(run.stdout.trim());
    } else {
      const fixture = path.join(temp, 'fixture.html');
      writeFileSync(fixture, html + '<script>' + script.replaceAll('</script', '<\\/script') + '</script>');
      const run = spawnSync('/Applications/Google Chrome.app/Contents/MacOS/Google Chrome', ['--headless=new', '--no-sandbox', '--disable-gpu', '--virtual-time-budget=12000', '--window-size=1500,1000', '--user-data-dir=' + temp + '/profile', '--dump-dom', 'file://' + fixture], { encoding: 'utf8', timeout: 30000 });
      assert.equal(run.status, 0, run.stderr);
      result = JSON.parse(run.stdout.match(/<output id="results">([^<]+)<\/output>/)[1]);
    }
    assert.equal(result.ok, true, JSON.stringify(result));
    assert(result.checks >= (browser === 'webkit' ? 18 : 40), JSON.stringify(result));
    console.log(browser + ': ' + JSON.stringify(result));
  }
} finally { rmSync(temp, {recursive: true, force: true}); }
