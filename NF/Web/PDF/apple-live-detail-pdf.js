((token, noteID, saved, useNativeEditor = false, pageZoom = 1) => {
  const panels = '[data-linked-document-panel="true"]';
  const visible = node => node?.getClientRects().length && !node.hasAttribute('data-linked-document-closing');
  const focusedPanel = document.activeElement?.closest(panels);
  const note = noteID && Array.from(document.querySelectorAll('[data-nf-live-note-id]'))
    .find(node => node.dataset.nfLiveNoteId === noteID && visible(node));
  const detail = visible(focusedPanel) ? focusedPanel
    : !note && Array.from(document.querySelectorAll(panels)).reverse().find(visible);
  const panel = detail || note?.closest('#portal-content');
  const body = detail ? panel.querySelector('[data-linked-document-body="true"]') : panel;
  const bridge = window.webkit?.messageHandlers?.NFAppleLiveDetailPDF;
  if (!panel || !body || !bridge) return false;
  let nativePageZoom = useNativeEditor ? pageZoom : 0;
  let nativeWidth = 0, nativeHeight = 0;
  let previousViewport = '';

  let objects;
  let savedLayout;
  try {
    const value = saved ? JSON.parse(saved) : [];
    objects = Array.isArray(value) ? value : value.annotations;
    const dimensions = value.layout;
    if (dimensions?.width > 0 && dimensions.width <= 16384 && dimensions.content > 0 && dimensions.content <= dimensions.width) {
      savedLayout = dimensions;
    }
    if (!Array.isArray(objects) || objects.some(item => !item || typeof item.id !== 'string' || typeof item.kind !== 'string')) return false;
  } catch { return false; }

  // macOS uses the PDF editor. Keep older portal-link markers available to the page.
  const legacyObjects = objects;
  if (useNativeEditor) objects = objects.filter(item => ['document', 'link'].includes(item.kind));
  const life = new AbortController();
  const listen = (node, event, action, options = {}) => node.addEventListener(event, action, { ...options, signal: life.signal });
  const element = (tag, attributes = {}) => {
    const node = document.createElement(tag);
    for (const [key, value] of Object.entries(attributes)) node.setAttribute(key, value);
    return node;
  };
  const svg = (tag, attributes = {}) => {
    const node = document.createElementNS('http://www.w3.org/2000/svg', tag);
    for (const [key, value] of Object.entries(attributes)) node.setAttribute(key, value);
    return node;
  };

  const scrollAtEntry = { left: body.scrollLeft, top: body.scrollTop };
  const paddingEdges = ['top', 'right', 'bottom', 'left'];
  const style = element('style');
  style.textContent = `
    [data-apple-live-detail][data-linked-document-panel] {
      position: fixed !important; inset: 0 !important; width: 100% !important; height: 100% !important;
      max-width: none !important; min-width: 0 !important; animation: none !important;
    }
    :is([data-current-page-slide-host], [data-workspace-project-overlays]):has(> [data-apple-live-detail]) {
      position: fixed !important; inset: 0 !important; width: auto !important; height: auto !important; overflow: visible !important;
    }
    #portal-content[data-apple-live-detail] {
      position: fixed !important; inset: 0 !important; width: auto !important; height: auto !important;
      min-height: 0 !important; transform: none !important; transition: none !important;
    }
    [data-apple-live-detail] > [data-linked-document-resizer] { display: none; }
    [data-apple-live-detail] > [data-linked-document-viewport] { margin-top: var(--nf-apple-pdf-toolbar-height, 0px); }
    [data-apple-pdf-native-toolbar] > :is([data-apple-pdf-tools], [data-apple-pdf-popover]) { display: none !important; }
    #portal-content[data-apple-live-detail] > :is([data-apple-pdf-tools], [data-apple-pdf-popover]) { position: fixed; }
    [data-apple-pdf-body] { overflow: auto !important; overflow-anchor: none; touch-action: pan-x pan-y; }
    [data-apple-pdf-body][data-apple-pdf-zoom] {
      padding: calc(var(--nf-apple-pdf-padding-top) * var(--nf-apple-pdf-zoom))
        calc(var(--nf-apple-pdf-padding-right) * var(--nf-apple-pdf-zoom))
        calc(var(--nf-apple-pdf-padding-bottom) * var(--nf-apple-pdf-zoom))
        calc(var(--nf-apple-pdf-padding-left) * var(--nf-apple-pdf-zoom));
    }
    [data-apple-pdf-body][data-apple-pdf-zoom] > :not([data-apple-pdf-layer], [data-apple-pdf-tools], [data-apple-pdf-popover], [data-apple-pdf-dialog]) {
      zoom: var(--nf-apple-pdf-zoom);
    }
    [data-apple-pdf-body][data-apple-pdf-fixed-width] > :not(.portal-titlebar, [data-apple-pdf-layer], [data-apple-pdf-tools], [data-apple-pdf-popover], [data-apple-pdf-dialog]) {
      min-width: var(--nf-apple-pdf-content-width);
    }
    [data-apple-pdf-body][data-apple-pdf-fixed-width] > .contents { display: block; }
    [data-apple-pdf-layer] { position: absolute; top: 0; left: 0; display: block; z-index: 2; pointer-events: none; }
    [data-apple-pdf-layer][data-drawing] { pointer-events: auto; touch-action: none; cursor: crosshair; }
    [data-apple-pdf-layer][data-hand] { pointer-events: auto; touch-action: pan-x pan-y pinch-zoom; cursor: grab; }
    [data-apple-pdf-layer] [data-pdf-object] { pointer-events: visiblePainted; cursor: pointer; }
    [data-apple-pdf-tools] {
      position: absolute; z-index: 5; inset: 6px 8px auto; display: flex; width: fit-content; max-width: calc(100% - 16px);
      align-items: center; gap: 4px; box-sizing: border-box; padding: 4px; border: 1px solid var(--card-border, #8886);
      border-radius: 10px; color: var(--foreground, CanvasText); background: var(--theme-surface-raised, Canvas);
      box-shadow: 0 4px 16px #0003;
    }
    [data-apple-pdf-tools] > [data-tool-scroll] {
      display: flex; align-items: center; gap: 2px; min-width: 0; overflow-x: auto; scrollbar-width: none;
    }
    [data-apple-pdf-tools] > [data-tool-actions] { display: flex; flex: none; align-items: center; gap: 2px; }
    [data-apple-pdf-tools] button, [data-apple-pdf-popover] button, [data-apple-pdf-dialog] button {
      border: 0; background: transparent; color: inherit; border-radius: 6px;
    }
    [data-apple-pdf-tools] button {
      flex: none; display: inline-flex; align-items: center; justify-content: center; gap: 5px;
      padding: 0 8px; min-width: 32px; height: 32px; white-space: nowrap; font-size: 12px;
    }
    [data-apple-pdf-tools] button:enabled:hover,
    [data-apple-pdf-popover] button:hover { background: var(--theme-surface-hover, #8883); }
    [data-apple-pdf-tools] button:is([aria-pressed="true"], [aria-expanded="true"]),
    [data-apple-pdf-popover] button[aria-pressed="true"] {
      background: color-mix(in srgb, var(--detail-animation-color, #438af4) 20%, var(--theme-surface-raised, Canvas));
      color: var(--foreground, CanvasText);
      box-shadow: inset 0 0 0 1px var(--detail-animation-color, #438af4);
    }
    [data-apple-pdf-tools] button:disabled { opacity: .4; }
    :is([data-apple-pdf-tools], [data-apple-pdf-popover]) svg { width: 17px; height: 17px; flex: none; }
    [data-apple-pdf-popover] {
      position: absolute; z-index: 6; top: var(--nf-apple-pdf-popover-top, 49px); left: 8px;
      display: grid; gap: 6px; align-content: start; padding: 8px;
      border: 1px solid var(--card-border, #8886); border-radius: 10px;
      color: var(--foreground, CanvasText); background: var(--theme-surface-raised, Canvas);
      width: min(320px, calc(100% - 16px)); max-height: calc(100% - var(--nf-apple-pdf-popover-top, 49px) - 8px);
      overflow: auto; overscroll-behavior: contain; box-sizing: border-box; font-size: 13px; box-shadow: 0 8px 28px #0004;
    }
    [data-apple-pdf-popover] header, [data-apple-pdf-options] label {
      display: flex; align-items: center; justify-content: space-between; gap: 8px; padding: 4px 8px;
    }
    [data-apple-pdf-popover] header { border-bottom: 1px solid var(--card-border, #8886); }
    [data-apple-pdf-popover] header button { display: grid; place-items: center; width: 28px; height: 28px; }
    [data-apple-pdf-popover] [data-popup-menu-row] {
      display: flex; align-items: center; gap: 8px; width: 100%; min-height: 32px; padding: 5px 8px; text-align: left;
    }
    [data-apple-pdf-tool-menu] [data-tool-check] { margin-inline-start: auto; }
    [data-apple-pdf-options] [role="group"] { display: grid; grid-template-columns: repeat(2, minmax(0, 1fr)); gap: 4px; }
    [data-apple-pdf-options] input[type="range"] { width: min(50%, 130px); }
    [data-apple-pdf-options] input[type="color"] { width: 36px; height: 28px; }
    [data-apple-pdf-dialog] {
      border: 1px solid var(--card-border, #8886); border-radius: 12px; width: min(420px, calc(100% - 24px));
      color: var(--foreground, CanvasText); background: var(--theme-surface-raised, Canvas); padding: 14px;
    }
    [data-apple-pdf-dialog]::backdrop { background: #0004; }
    [data-apple-pdf-dialog] form { display: grid; gap: 10px; }
    [data-apple-pdf-dialog] :is(input:not([type="hidden"]), textarea) {
      width: 100%; box-sizing: border-box; padding: 8px; border: 1px solid var(--card-border, #8886);
      border-radius: 6px; color: inherit; background: var(--background, Canvas);
    }
    [data-apple-pdf-dialog] footer { display: flex; justify-content: flex-end; gap: 8px; }
    [data-apple-pdf-dialog] footer button { padding: 5px 12px; background: var(--theme-surface-hover, #8883); }
    [data-apple-pdf-dialog] [data-popup-menu-list] { max-height: 220px; overflow-y: auto; }
    [data-apple-pdf-document] {
      position: absolute; z-index: 7; inset: 54px 10px auto auto; width: min(460px, calc(100% - 20px));
      height: min(70%, 640px); display: flex; flex-direction: column; overflow: hidden;
      border: 1px solid var(--card-border, #8886); border-radius: 12px; background: var(--theme-surface-raised, Canvas);
      color: var(--foreground, CanvasText); box-shadow: 0 8px 28px #0004;
    }
    [data-apple-pdf-document] header { display: flex; padding: 8px 10px; justify-content: space-between; }
    [data-apple-pdf-document] iframe { flex: 1; min-height: 0; width: 100%; border: 0; }
    [data-apple-pdf-tools] [role="status"] { max-width: 160px; font-size: 11px; }
    @media (max-width: 580px) {
      [data-apple-pdf-tools] [data-close-label] { display: none; }
      [data-apple-pdf-tools] button { min-width: 36px; height: 36px; }
    }
    :is([data-apple-pdf-popover], [data-apple-pdf-popover] *, [data-apple-pdf-tools] *)[hidden] { display: none !important; }
  `;

  panel.setAttribute('data-apple-live-detail', '');
  panel.toggleAttribute('data-apple-pdf-native-toolbar', nativePageZoom > 0);
  body.setAttribute('data-apple-pdf-body', '');
  document.head.append(style);

  const layer = svg('svg', { 'data-apple-pdf-layer': '', 'aria-label': 'PDFView 주석' });
  const drawing = svg('g');
  const preview = svg('g', { 'pointer-events': 'none' });
  layer.append(drawing, preview);
  body.append(layer);

  const toolbar = element('div', { 'data-apple-pdf-tools': '', role: 'toolbar', 'aria-label': '상세페이지 PDF 도구' });
  const toolScroll = element('div', { 'data-tool-scroll': '' });
  const toolActions = element('div', { 'data-tool-actions': '' });
  const options = element('div', { id: 'nf-apple-pdf-tool-options', 'data-apple-pdf-popover': '', 'data-apple-pdf-options': '', role: 'region', hidden: '' });
  const toolMenu = element('div', { id: 'nf-apple-pdf-tool-menu', 'data-apple-pdf-popover': '', 'data-apple-pdf-tool-menu': '', 'data-popup-menu-list': '', role: 'region', 'aria-label': '도구 지원', hidden: '' });
  const status = element('span', { role: 'status', hidden: '' });
  const fileInput = element('input', { type: 'file', accept: 'image/*', hidden: '' });
  toolbar.append(toolScroll, toolActions, status, fileInput);
  panel.append(toolbar, options, toolMenu);

  const icons = {
    close: 'M14 6l-6 6 6 6M8 12h12',
    view: 'M2 12s4-7 10-7 10 7 10 7-4 7-10 7S2 12 2 12m10-3a3 3 0 1 0 0 6 3 3 0 0 0 0-6',
    hand: 'M7 13V8a1 1 0 0 1 2 0v4-7a1 1 0 0 1 2 0v7-8a1 1 0 0 1 2 0v8-6a1 1 0 0 1 2 0v8l2-2a2 2 0 0 1 2 2l-3 6H9l-5-6a2 2 0 0 1 3-1Z',
    pen: 'M5 19l1-5L17 3l4 4-11 11-5 1zm10-14 4 4',
    handwriting: 'M3 18c4-9 8-13 10-13 4 0-2 11-5 11-2 0 0-6 4-6 5 0 0 7 4 7 2 0 4-2 5-3',
    highlighter: 'm4 16 4-5L17 2l5 5-9 9-5 4H4Zm4-5 5 5M3 22h12',
    neon: 'M12 2v4m6 0-2 3m5 3h-4M4 12H1m5-6 2 3m0 12v-7a4 4 0 0 1 8 0v7m-11 0h14',
    eraser: 'm3 15 11-12 8 7-10 11H9Zm5-5 8 7m-4 4h10',
    select: 'M6 3v17l5-5 4 7 3-2-4-7 7-1Z',
    shape: 'M4 4h16v16H4Z',
    text: 'M4 6V3h16v3M12 3v18m-4 0h8',
    image: 'M3 4h18v16H3Zm0 13 6-6 5 5 3-3 4 4M17 8h.1',
    connector: 'M6 6h8q4 0 4 4v4m-12-8a2 2 0 1 1-4 0 2 2 0 0 1 4 0m14 12a2 2 0 1 1-4 0 2 2 0 0 1 4 0',
    document: 'M6 3h9l5 5v13H6Zm9 0v5h5M9 12h8m-8 4h8',
    link: 'm10 13 4-4m-5 8-2 2a4 4 0 0 1-6-6l4-4a4 4 0 0 1 6 0m2-2 2-2a4 4 0 0 1 6 6l-4 4a4 4 0 0 1-6 0',
    undo: 'm9 5-5 5 5 5m-5-5h10q7 0 7 7',
    redo: 'm15 5 5 5-5 5m5-5H10q-7 0-7 7',
    minus: 'M4 12h16', plus: 'M4 12h16M12 4v16',
    settings: 'M4 6h16M4 12h16M4 18h16M8 3v6m8 0v6m-6 0v6',
    list: 'M8 6h13M8 12h13M8 18h13M3 6h.1M3 12h.1M3 18h.1',
    dismiss: 'M6 6l12 12M6 18 18 6',
    trash: 'M3 6h18M8 6V3h8v3M5 6l1 15h12l1-15m-9 4v7m4-7v7',
  };
  function button(icon, label, action, parent = toolScroll) {
    const node = element('button', { type: 'button', title: label, 'aria-label': label });
    const graphic = svg('svg', { viewBox: '0 0 24 24', fill: 'none', stroke: 'currentColor', 'stroke-width': 1.6, 'stroke-linecap': 'round', 'stroke-linejoin': 'round', 'aria-hidden': 'true' });
    graphic.append(svg('path', { d: icons[icon] }));
    node.append(graphic);
    listen(node, 'click', action);
    parent.append(node);
    return node;
  }
  const closeButton = button('close', '상세페이지로 돌아가기', () => { void close(true); }, toolbar);
  const closeLabel = element('span', { 'data-close-label': '' });
  closeLabel.textContent = '상세페이지로 돌아가기';
  closeButton.append(closeLabel);
  toolbar.prepend(closeButton);

  const previous = [];
  const next = [];
  const transient = [];
  let active = 'view';
  let selected = null;
  let connectorSource = null;
  let gesture = null;
  let color = '#2563eb';
  let lineWidth = 2;
  let shape = 'rectangle';
  let fill = false;
  let textSize = 17;
  let eraserSize = 8;
  let zoom = 1;
  let pinch = null;
  let documentLayout = savedLayout || null;
  let documentPopup = null;
  let dialog = null;
  let closed = false;
  let closing = false;
  let needsSave = false;
  let saving = null;
  let pendingLayout = 0;
  const timers = new Set();

  const undoButton = button('undo', 'PDF 실행 취소', () => restore(previous, next));
  const redoButton = button('redo', 'PDF 다시 실행', () => restore(next, previous));
  const minus = button('minus', '상세페이지 축소', () => changeZoom(zoom / 1.25));
  const plus = button('plus', '상세페이지 확대', () => changeZoom(zoom * 1.25));
  const supportedTools = new Map([
    ['view', '원본 보기·편집'], ['hand', '손 도구'], ['select', '선택'], ['pen', '펜'],
    ['handwriting', '손글씨'], ['highlighter', '형광펜'], ['neon', '네온'], ['eraser', '지우개'],
    ['shape', '도형'], ['text', '텍스트 주석'], ['image', '이미지 삽입'],
    ['connector', '연결선'], ['document', '문서 연결'], ['link', '웹 링크 연결'],
  ]);
  const inkTools = new Set(['pen', 'handwriting', 'highlighter', 'neon', 'shape', 'connector', 'document', 'link', 'text']);
  const passiveTools = new Set(['view', 'hand', 'image']);
  const toolsWithOptions = new Set([...inkTools, 'eraser', 'image']);
  const autoShowOptions = new Set(['shape', 'text', 'image', 'connector']);
  const toolButtons = new Map();
  const menuButtons = new Map();
  for (const [key, label] of supportedTools) {
    const node = button(key, label, () => chooseTool(key));
    node.setAttribute('data-apple-pdf-tool', key);
    toolButtons.set(key, node);
  }
  const remove = button('trash', '선택 주석 삭제', removeSelected);
  const menuToggle = button('list', '도구 지원', () => togglePopover(toolMenu), toolActions);
  const settings = button('settings', '도구 상세 설정', () => togglePopover(options), toolActions);
  menuToggle.setAttribute('aria-controls', toolMenu.id);
  settings.setAttribute('aria-controls', options.id);

  function showPopover(popover = null) {
    toolMenu.hidden = popover !== toolMenu;
    options.hidden = popover !== options;
    menuToggle.setAttribute('aria-expanded', String(!toolMenu.hidden));
    settings.setAttribute('aria-expanded', String(!options.hidden));
  }
  function togglePopover(popover) {
    showPopover(popover.hidden ? popover : null);
    if (popover === toolMenu && !popover.hidden) menuButtons.get(active)?.focus();
  }
  function popoverHeader(popover, title, toggle) {
    const header = element('header');
    const heading = element('strong');
    heading.textContent = title;
    header.append(heading);
    button('dismiss', title + ' 닫기', () => {
      showPopover();
      toggle.focus({ preventScroll: true });
    }, header);
    popover.append(header);
    return heading;
  }
  popoverHeader(toolMenu, '도구 지원', menuToggle);
  for (const [key, label] of supportedTools) {
    const node = button(key, label, () => {
      chooseTool(key);
      const button = toolButtons.get(key);
      button.focus({ preventScroll: true });
      const frame = button.getBoundingClientRect();
      const scroller = toolScroll.getBoundingClientRect();
      toolScroll.scrollLeft += Math.min(0, frame.left - scroller.left) + Math.max(0, frame.right - scroller.right);
    }, toolMenu);
    node.setAttribute('data-popup-menu-row', '');
    node.append(document.createTextNode(label));
    const check = element('span', { 'data-tool-check': '', 'aria-hidden': 'true', hidden: '' });
    check.textContent = '✓';
    node.append(check);
    menuButtons.set(key, node);
  }
  const optionTitle = popoverHeader(options, '도구 설정', settings);

  function field(label, input) {
    const node = element('label');
    node.append(document.createTextNode(label), input);
    options.append(node);
    return input;
  }
  const colorInput = field('색상', element('input', { type: 'color', value: color }));
  const widthInput = field('두께', element('input', { type: 'range', min: '1', max: '36', value: lineWidth }));
  const fillInput = field('도형 채우기', element('input', { type: 'checkbox' }));
  const textSizeInput = field('글자 크기', element('input', { type: 'range', min: '10', max: '48', value: textSize }));
  const eraserSizeInput = field('지우개 크기', element('input', { type: 'range', min: '6', max: '100', value: eraserSize }));
  const imageButton = button('image', '이미지 파일 가져오기', () => fileInput.click(), options);
  imageButton.setAttribute('data-popup-menu-row', '');
  imageButton.append(document.createTextNode('이미지 파일 가져오기'));
  const shapes = element('div', { role: 'group', 'aria-label': '도형 종류' });
  for (const [value, label] of [['rectangle', '사각형'], ['rounded', '둥근 사각형'], ['ellipse', '원'], ['triangle', '삼각형'], ['arrow', '화살표']]) {
    const node = element('button', { type: 'button', 'data-pdf-shape': value, 'aria-pressed': String(value === shape) });
    node.setAttribute('data-popup-menu-row', '');
    node.textContent = label;
    listen(node, 'click', () => {
      shape = value;
      for (const sibling of shapes.children) sibling.setAttribute('aria-pressed', String(sibling === node));
    });
    shapes.append(node);
  }
  options.append(shapes);
  listen(colorInput, 'input', () => { color = colorInput.value; });
  listen(widthInput, 'input', () => { lineWidth = Number(widthInput.value); });
  listen(fillInput, 'change', () => { fill = fillInput.checked; });
  listen(textSizeInput, 'input', () => { textSize = Number(textSizeInput.value); });
  listen(eraserSizeInput, 'input', () => { eraserSize = Number(eraserSizeInput.value); });
  showPopover();

  function setStatus(message) {
    status.textContent = message || '';
    status.hidden = !message;
    if (useNativeEditor && message) void bridge.postMessage({ token, nativeError: message }).catch(() => {});
  }
  function updateTools() {
    for (const [key, node] of toolButtons) {
      const pressed = key === active;
      node.setAttribute('aria-pressed', String(pressed));
      node.title = supportedTools.get(key) + (pressed ? ' · 선택됨' : '');
      const menuButton = menuButtons.get(key);
      menuButton.setAttribute('aria-pressed', String(pressed));
      menuButton.querySelector('[data-tool-check]').hidden = !pressed;
    }
    const title = supportedTools.get(active) + ' 설정';
    if (optionTitle.textContent !== title) optionTitle.textContent = title;
    options.setAttribute('aria-label', title);
    settings.disabled = !toolsWithOptions.has(active);
    colorInput.parentElement.hidden = !inkTools.has(active);
    widthInput.parentElement.hidden = !inkTools.has(active) || ['text', 'document', 'link'].includes(active);
    fillInput.parentElement.hidden = shapes.hidden = active !== 'shape';
    textSizeInput.parentElement.hidden = active !== 'text';
    eraserSizeInput.parentElement.hidden = active !== 'eraser';
    imageButton.hidden = active !== 'image';
    layer.toggleAttribute('data-drawing', !passiveTools.has(active));
    layer.toggleAttribute('data-hand', active === 'hand');
    undoButton.disabled = !previous.length;
    redoButton.disabled = !next.length;
    remove.hidden = !selected;
    minus.disabled = zoom <= 1;
    plus.disabled = zoom >= 4;
  }
  function setTool(value) {
    if (gesture) cancelGesture();
    active = value;
    connectorSource = null;
    if (value !== 'select') selected = null;
    updateTools();
    render();
  }
  function chooseTool(value) {
    const wasActive = active === value;
    const showOptions = toolsWithOptions.has(value) && (wasActive ? options.hidden : autoShowOptions.has(value));
    setTool(value);
    showPopover(showOptions ? options : null);
  }
  function publishViewport() {
    if (!useNativeEditor || closed || !body.isConnected) return;
    const rect = body.getBoundingClientRect();
    if (rect.width <= 0 || rect.height <= 0) return;
    const viewport = JSON.stringify({
      x: rect.left * nativePageZoom, y: rect.top * nativePageZoom,
      width: body.clientWidth * nativePageZoom, height: body.clientHeight * nativePageZoom,
      scrollX: body.scrollLeft * nativePageZoom, scrollY: body.scrollTop * nativePageZoom,
      scale: zoom * nativePageZoom, zoom, pageZoom: nativePageZoom,
      contentWidth: Number(layer.getAttribute('width')) / zoom,
      contentHeight: Number(layer.getAttribute('height')) / zoom,
    });
    if (viewport === previousViewport) return;
    previousViewport = viewport;
    void bridge.postMessage({ token, viewport }).catch(() => {});
  }
  function nativeCommand(sessionToken, command, x, y) {
    if (!useNativeEditor || sessionToken !== token || closed || closing) return false;
    switch (command) {
      case 'close': return close(true);
      case 'zoom': changeZoom(x); break;
      case 'scroll':
        body.scrollBy(x / nativePageZoom, y / nativePageZoom);
        publishViewport();
        break;
      case 'extent':
        nativeWidth = x; nativeHeight = y;
        layout();
        break;
      default: return false;
    }
    return true;
  }
  function changeZoom(value, focus) {
    const nextZoom = Math.min(useNativeEditor ? 10 : 4, Math.max(useNativeEditor ? 0.1 : 1, value));
    if (nextZoom === zoom) return;
    const frame = body.getBoundingClientRect();
    const x = focus ? Math.max(0, focus[0] - frame.left) : body.clientWidth / 2;
    const y = focus ? Math.max(0, focus[1] - frame.top) : body.clientHeight / 2;
    const left = (body.scrollLeft + x) / zoom, top = (body.scrollTop + y) / zoom;
    if (zoom === 1) {
      const computed = getComputedStyle(body);
      for (const edge of paddingEdges) body.style.setProperty('--nf-apple-pdf-padding-' + edge, computed.getPropertyValue('padding-' + edge));
    }
    zoom = nextZoom;
    body.style.setProperty('--nf-apple-pdf-zoom', String(zoom));
    body.toggleAttribute('data-apple-pdf-zoom', zoom !== 1);
    layout();
    body.scrollLeft = left * zoom - x;
    body.scrollTop = top * zoom - y;
    publishViewport();
    updateTools();
  }
  function box(object) {
    if (object.points?.length) {
      const p = object.points[0];
      let left = p[0], right = p[0], top = p[1], bottom = p[1];
      for (const [x, y] of object.points) { left = Math.min(left, x); right = Math.max(right, x); top = Math.min(top, y); bottom = Math.max(bottom, y); }
      return { x: left, y: top, w: Math.max(1, right - left), h: Math.max(1, bottom - top) };
    }
    return { x: object.x, y: object.y, w: object.w, h: object.h };
  }
  function layout() {
    if (closed || !body.isConnected) return;
    const width = body.clientWidth;
    if (zoom === 1 && width > (documentLayout?.width || 0) && width <= 16384) {
      const computed = getComputedStyle(body);
      const padding = (parseFloat(computed.paddingLeft) || 0) + (parseFloat(computed.paddingRight) || 0);
      documentLayout = { width, content: Math.max(1, width - padding) };
      needsSave = true;
      void saveAnnotations();
    }
    body.style.setProperty('--nf-apple-pdf-content-width', (documentLayout?.content || width) + 'px');
    body.toggleAttribute('data-apple-pdf-fixed-width', zoom !== 1 || width < (documentLayout?.width || 0) - 1);
    const left = body.scrollLeft, top = body.scrollTop;
    // Measure the document extent independently of the annotation canvas.
    layer.setAttribute('width', 0);
    layer.setAttribute('height', 0);
    let maxX = Math.max(nativeWidth, Math.max(body.clientWidth, body.scrollWidth) / zoom);
    let maxY = Math.max(nativeHeight, Math.max(body.clientHeight, body.scrollHeight) / zoom);
    for (const object of objects) {
      const rect = box(object);
      if (rect.x + rect.w > maxX) maxX = rect.x + rect.w + 16;
      if (rect.y + rect.h > maxY) maxY = rect.y + rect.h + 16;
    }
    layer.setAttribute('width', maxX * zoom);
    layer.setAttribute('height', maxY * zoom);
    layer.setAttribute('viewBox', [0, 0, maxX, maxY].join(' '));
    body.scrollLeft = left;
    body.scrollTop = top;
    if (useNativeEditor) {
      publishViewport();
      return;
    }
    const height = toolbar.offsetHeight;
    const header = detail ? panel.querySelector('[data-linked-document-header]') : body.querySelector(':scope > .portal-titlebar');
    const headerHeight = (header?.offsetHeight || 0) * (detail ? 1 : zoom);
    panel.style.setProperty('--nf-apple-pdf-popover-top', headerHeight + height + 11 + 'px');
    toolbar.style.top = headerHeight + 6 + 'px';
    if (detail) panel.style.setProperty('--nf-apple-pdf-toolbar-height', height + 12 + 'px');
  }
  if (useNativeEditor) listen(body, 'scroll', publishViewport, { passive: true });
  listen(window, 'nfPortalMacZoomState', event => {
    const scale = event.detail?.percent / 100;
    if (nativePageZoom && scale >= .25 && scale <= 5) {
      nativePageZoom = scale;
      scheduleLayout();
    }
  });
  function scheduleLayout() {
    if (closed || pendingLayout) return;
    pendingLayout = requestAnimationFrame(() => { pendingLayout = 0; layout(); });
  }

  function renderObject(object) {
    const styles = { stroke: object.color, 'stroke-width': object.width, 'stroke-linecap': 'round', 'stroke-linejoin': 'round', fill: 'none' };
    if (object.source && object.target) {
      const source = objects.find(item => item.id === object.source);
      const target = objects.find(item => item.id === object.target);
      if (!source || !target) return svg('g');
      const a = box(source), b = box(target);
      const ax = a.x + a.w, ay = a.y + a.h / 2, bx = b.x, by = b.y + b.h / 2, middle = (ax + bx) / 2;
      return svg('path', { ...styles, d: ['M', ax, ay, 'H', middle, 'V', by, 'H', bx].join(' ') });
    }
    if (object.points) {
      const coordinates = object.points.length === 1
        ? [object.points[0], [object.points[0][0] + .01, object.points[0][1]]] : object.points;
      const path = svg('polyline', { ...styles, points: coordinates.map(point => point.join(',')).join(' ') });
      if (object.kind === 'highlighter') path.setAttribute('opacity', .32);
      if (object.kind === 'neon') path.style.filter = 'drop-shadow(0 0 3px ' + object.color + ')';
      return path;
    }
    const { x, y, w, h } = object;
    if (object.kind === 'image') return svg('image', { x, y, width: w, height: h, href: object.image });
    if (object.kind === 'text') {
      const group = svg('g');
      if (object.background) group.append(svg('rect', { x, y, width: w, height: h, rx: 4, fill: object.background }));
      const node = svg('text', { x, y, fill: object.color, 'font-size': object.fontSize || 17, 'font-family': 'system-ui, sans-serif' });
      object.text.split('\n').forEach((line, i) => {
        const span = svg('tspan', { x, y: y + (i + .95) * (object.fontSize || 17) * 1.18 });
        span.textContent = line || ' ';
        node.append(span);
      });
      group.append(node);
      return group;
    }
    if (object.kind === 'document' || object.kind === 'link') {
      const group = svg('g', { role: 'button', tabindex: 0, 'aria-label': object.title || '연결 열기' });
      group.append(svg('rect', { x, y, width: w, height: h, rx: 5, fill: object.color }));
      group.append(svg('path', { transform: 'translate(' + (x + 4) + ' ' + (y + 4) + ') scale(.75)', d: icons[object.kind],
        fill: 'none', stroke: 'white', 'stroke-linecap': 'round', 'stroke-linejoin': 'round', 'stroke-width': 1.7 }));
      return group;
    }
    const paint = { ...styles, fill: object.fill ? object.color + '32' : 'none' };
    if (object.shape === 'ellipse') return svg('ellipse', { ...paint, cx: x + w / 2, cy: y + h / 2, rx: w / 2, ry: h / 2 });
    if (object.shape === 'triangle') return svg('polygon', { ...paint, points: [x + w / 2, y, x + w, y + h, x, y + h].join(' ') });
    if (object.shape === 'arrow') return svg('path', { ...paint,
      d: ['M', x, y + h / 2, 'H', x + w, 'm', -w / 3, -h / 3, 'l', w / 3, h / 3, 'l', -w / 3, h / 3].join(' ') });
    return svg('rect', { ...paint, x, y, width: w, height: h, rx: object.shape === 'rounded' ? 10 : 0 });
  }
  function render() {
    const nodes = [];
    for (const object of [...objects, ...transient]) {
      const node = renderObject(object);
      node.setAttribute('data-pdf-rendered', object.id);
      if (['select', 'connector'].includes(active) || (active === 'view' && ['document', 'link'].includes(object.kind))) {
        node.setAttribute('data-pdf-object', object.id);
        if (active !== 'view') node.setAttribute('pointer-events', 'bounding-box');
      }
      nodes.push(node);
      if (object.id === selected || object.id === connectorSource) {
        const rect = box(object);
        nodes.push(svg('rect', { x: rect.x - 4, y: rect.y - 4, width: rect.w + 8, height: rect.h + 8,
          fill: 'none', stroke: 'var(--theme-accent, #2563eb)', 'stroke-dasharray': '4 3', 'pointer-events': 'none' }));
        if (active === 'select' && object.id === selected && !['connector', 'document', 'link'].includes(object.kind)) {
          for (const [x, y] of resizeCorners(rect)) {
            nodes.push(svg('rect', { x: x - 3, y: y - 3, width: 6, height: 6, fill: 'white',
              stroke: 'var(--theme-accent, #2563eb)', 'pointer-events': 'none' }));
          }
        }
      }
    }
    drawing.replaceChildren(...nodes);
  }
  function refresh() { layout(); render(); updateTools(); }

  function saveAnnotations() {
    if (saving) return saving;
    if (!needsSave) return Promise.resolve(true);
    saving = (async () => {
      while (needsSave) {
        needsSave = false;
        try {
          await bridge.postMessage({ token, annotations: JSON.stringify({ annotations: useNativeEditor ? legacyObjects : objects, layout: documentLayout }) });
          setStatus('');
        } catch (error) {
          needsSave = true;
          setStatus(typeof error === 'string' ? error : 'PDF 주석 저장 실패');
          return false;
        }
      }
      return true;
    })().finally(() => { saving = null; });
    return saving;
  }
  function change(value) {
    previous.push(objects);
    if (previous.length > 32) previous.shift();
    objects = value;
    next.length = 0;
    needsSave = true;
    refresh();
    void saveAnnotations();
  }
  function restore(source, destination) {
    if (gesture) cancelGesture();
    if (!source.length) return;
    destination.push(objects);
    objects = source.pop();
    selected = null;
    connectorSource = null;
    needsSave = true;
    refresh();
    void saveAnnotations();
  }
  function removeSelected() {
    if (!selected) return;
    const id = selected;
    selected = null;
    change(objects.filter(object => object.id !== id && object.source !== id && object.target !== id));
  }
  function newObject(kind, rect) {
    return { id: crypto.randomUUID(), kind, color, width: lineWidth, ...rect };
  }
  function point(event) {
    const rect = layer.getBoundingClientRect();
    return [Math.max(0, (event.clientX - rect.left) / zoom), Math.max(0, (event.clientY - rect.top) / zoom)];
  }
  function objectAt(x, y) {
    return [...objects].reverse().find(object => {
      const rect = box(object);
      const padding = active === 'eraser' ? eraserSize : Math.max(5, object.width || 0);
      if (x < rect.x - padding || x > rect.x + rect.w + padding ||
          y < rect.y - padding || y > rect.y + rect.h + padding) return false;
      if (!object.points || object.points.length < 2) return true;
      return object.points.slice(1).some(([x2, y2], index) => {
        const [x1, y1] = object.points[index];
        const dx = x2 - x1, dy = y2 - y1;
        const t = Math.min(1, Math.max(0, ((x - x1) * dx + (y - y1) * dy) / (dx * dx + dy * dy || 1)));
        return Math.hypot(x - x1 - t * dx, y - y1 - t * dy) <= padding;
      });
    });
  }

  function resizeCorners(rect) {
    return [[rect.x, rect.y], [rect.x + rect.w, rect.y], [rect.x, rect.y + rect.h], [rect.x + rect.w, rect.y + rect.h]];
  }
  function updateGesture(p) {
    const g = gesture;
    if (!g) return;
    if (g.kind === 'hand') return;
    if (g.kind === 'eraser') {
      const hit = objectAt(...p);
      if (hit) {
        g.erased.add(hit.id);
        const node = [...drawing.children].find(node => node.getAttribute('data-pdf-rendered') === hit.id);
        if (node) node.style.opacity = '.35';
      }
      return;
    }
    const [x, y] = p;
    const [startX, startY] = g.start;
    const dx = x - startX, dy = y - startY;
    if (g.kind === 'resize') {
      const rect = box(g.original);
      const left = g.corner % 2 === 0, top = g.corner < 2;
      const x1 = left ? Math.min(x, rect.x + rect.w - 6) : rect.x;
      const y1 = top ? Math.min(y, rect.y + rect.h - 6) : rect.y;
      const x2 = left ? rect.x + rect.w : Math.max(x, rect.x + 6);
      const y2 = top ? rect.y + rect.h : Math.max(y, rect.y + 6);
      const w = x2 - x1, h = y2 - y1;
      g.draft = g.original.points
        ? { ...g.original, points: g.original.points.map(([px, py]) => [x1 + (px - rect.x) * w / rect.w, y1 + (py - rect.y) * h / rect.h]) }
        : { ...g.original, x: x1, y: y1, w, h };
      if (g.original.kind === 'text') g.draft.fontSize = Math.max(6, (g.original.fontSize || 17) * h / rect.h);
    } else if (g.kind === 'move') {
      const original = g.original;
      if (Math.abs(dx) + Math.abs(dy) < 1 && g.draft === original) return;
      g.draft = original.points
        ? { ...original, points: original.points.map(([px, py]) => [px + dx, py + dy]) }
        : { ...original, x: Math.max(0, original.x + dx), y: Math.max(0, original.y + dy) };
    } else if (g.kind === 'shape') {
      g.draft = { ...g.draft, x: Math.min(startX, x), y: Math.min(startY, y), w: Math.max(1, Math.abs(dx)), h: Math.max(1, Math.abs(dy)) };
    } else {
      const last = g.draft.points.at(-1);
      if (g.draft.points.length < 16000 && Math.hypot(x - last[0], y - last[1]) > .35) g.draft.points.push(p);
    }
    if (g.draft) preview.replaceChildren(renderObject(g.draft));
  }

  listen(layer, 'pointerdown', event => {
    if (closed || closing || active === 'view' || active === 'image' || !event.isPrimary || event.button !== 0) return;
    if (active === 'hand' && event.pointerType === 'touch') return;
    event.preventDefault();
    event.stopPropagation();
    const p = point(event);
    const [x, y] = p;
    const hit = objectAt(x, y);
    if (active === 'text') { openText(p); return; }
    if (active === 'document') { openDocumentPicker(p); return; }
    if (active === 'link') { openLinkEditor(p); return; }
    if (active === 'connector') { connect(hit); return; }
    if (active === 'select') {
      const original = objects.find(item => item.id === selected);
      const corner = original && !['connector', 'document', 'link'].includes(original.kind)
        ? resizeCorners(box(original)).findIndex(([px, py]) => Math.hypot(px - x, py - y) <= 9 / zoom) : -1;
      if (corner >= 0) {
        gesture = { kind: 'resize', original, corner, draft: original, start: p };
      } else {
        selected = hit?.id || null;
        render(); updateTools();
        if (!hit || hit.kind === 'connector') return;
        gesture = { kind: 'move', original: hit, draft: hit, start: p };
      }
    } else if (active === 'hand') {
      gesture = { kind: 'hand', start: [event.clientX, event.clientY], left: body.scrollLeft, top: body.scrollTop };
    } else if (active === 'eraser') {
      gesture = { kind: 'eraser', erased: new Set(), start: p };
    } else if (active === 'shape') {
      gesture = { kind: 'shape', draft: { ...newObject('shape', { x, y, w: 1, h: 1 }), shape, fill }, start: p };
    } else {
      const object = newObject(active);
      object.width = active === 'highlighter' ? Math.max(lineWidth, 14) : lineWidth;
      object.points = [p];
      gesture = { kind: active, draft: object, start: p };
    }
    gesture.pointer = event.pointerId;
    layer.setPointerCapture(event.pointerId);
    updateGesture(p);
  });
  listen(layer, 'pointermove', event => {
    const g = gesture;
    if (!g || g.pointer !== event.pointerId) return;
    event.preventDefault();
    if (g.kind === 'hand') {
      body.scrollLeft = g.left - (event.clientX - g.start[0]);
      body.scrollTop = g.top - (event.clientY - g.start[1]);
      return;
    }
    const samples = event.getCoalescedEvents?.();
    if (samples?.length) for (const sample of samples) updateGesture(point(sample));
    else updateGesture(point(event));
  });
  listen(layer, 'pointerup', event => {
    const g = gesture;
    if (!g || g.pointer !== event.pointerId) return;
    updateGesture(point(event));
    cancelGesture();
    if (g.kind === 'hand') return;
    if (g.kind === 'eraser') {
      if (g.erased.size) change(objects.filter(object =>
        !g.erased.has(object.id) && !g.erased.has(object.source) && !g.erased.has(object.target)));
      return;
    }
    if (g.kind === 'move' || g.kind === 'resize') {
      if (g.draft !== g.original) change(objects.map(object => object.id === g.original.id ? g.draft : object));
    } else if (g.kind === 'neon') {
      transient.push(g.draft);
      const timer = setTimeout(() => {
        const index = transient.indexOf(g.draft);
        if (index >= 0) transient.splice(index, 1);
        timers.delete(timer);
        render();
      }, 4000);
      timers.add(timer);
      render();
    } else change([...objects, g.draft]);
  });
  function cancelGesture() {
    const current = gesture;
    gesture = null;
    if (current && layer.hasPointerCapture(current.pointer)) layer.releasePointerCapture(current.pointer);
    preview.replaceChildren();
  }
  function discardGesture() { if (gesture) { cancelGesture(); render(); } }
  listen(layer, 'pointercancel', discardGesture);
  listen(layer, 'lostpointercapture', discardGesture);

  function connect(hit) {
    if (!hit) { connectorSource = null; render(); return; }
    if (hit.kind === 'connector') return;
    const source = objects.find(object => object.id === connectorSource);
    if (!source || source === hit) {
      connectorSource = hit.id; render(); return;
    }
    const a = box(source), b = box(hit);
    connectorSource = null;
    change([...objects, { ...newObject('connector'), source: source.id, target: hit.id,
      points: [[a.x + a.w, a.y + a.h / 2], [b.x, b.y + b.h / 2]] }]);
  }

  function showDialog(title, attach, submit) {
    dialog?.close();
    const pop = element('dialog', { 'data-apple-pdf-dialog': '', 'aria-label': title });
    const form = element('form');
    const heading = element('strong');
    heading.textContent = title;
    form.append(heading);
    const input = attach(form);
    const footer = element('footer');
    const cancel = element('button', { type: 'button' });
    cancel.textContent = '취소';
    listen(cancel, 'click', () => pop.close());
    footer.append(cancel);
    if (submit) {
      const apply = element('button', { type: 'submit' });
      apply.textContent = '적용';
      footer.append(apply);
      listen(form, 'submit', event => {
        event.preventDefault();
        if (submit(input.value) !== false) pop.close();
      });
    } else listen(form, 'submit', event => event.preventDefault());
    form.append(footer);
    pop.append(form);
    panel.append(pop);
    dialog = pop;
    listen(pop, 'close', () => {
      pop.remove();
      if (dialog === pop) dialog = null;
      });
    pop.showModal();
    input?.focus();
    return pop;
  }
  function openText([x, y], existing) {
    showDialog('텍스트 주석', form => {
      const input = element('textarea', { rows: 3, maxlength: 4000, 'aria-label': '주석 내용', required: '' });
      input.value = existing?.text || '';
      form.append(input);
      return input;
    }, value => {
      if (!value.trim()) return false;
      const size = existing?.fontSize || textSize;
      const lines = value.split('\n');
      const rect = { x, y, w: Math.max(24, Math.max(...lines.map(line => line.length)) * size), h: lines.length * size * 1.18 };
      const object = { ...(existing || newObject('text')), ...rect, text: value, fontSize: size };
      change(existing ? objects.map(item => item.id === existing.id ? object : item) : [...objects, object]);
    });
  }
  function supportedDocument(href) {
    if (typeof href !== 'string' || !href) return null;
    let url;
    try { url = new URL(href, location.origin); } catch { return null; }
    if (url.origin !== location.origin || !/^\/(custom|linked-document)\/[a-zA-Z0-9_-]{1,120}$/.test(url.pathname)) return null;
    return url.pathname + url.search + url.hash;
  }
  function openLinkEditor([x, y]) {
    showDialog('웹 링크 연결', form => {
      const input = element('input', { type: 'url', placeholder: 'https://', 'aria-label': '웹 주소', required: '' });
      form.append(input);
      return input;
    }, value => {
      const url = new URL(value);
      if (!['http:', 'https:'].includes(url.protocol) || url.username || url.password) return false;
      change([...objects, { ...newObject('link', { x, y, w: 26, h: 26 }), href: url.href, title: url.host }]);
      setTool('view');
    });
  }
  function openDocumentPicker([x, y]) {
    showDialog('페이지 연결', form => {
      const input = element('input', { type: 'search', placeholder: '# 페이지·문서 검색', maxlength: 80, 'aria-label': '페이지·문서 검색' });
      const filters = element('div', { role: 'group', 'aria-label': '검색 범위' });
      const create = element('button', { type: 'button' });
      create.textContent = '새 문서 생성';
      create.disabled = true;
      const list = element('div', { 'data-popup-menu-list': '', 'aria-label': '연결할 페이지' });
      const message = element('span', { role: 'status' });
      form.append(input, filters, message, list, create);
      let search = null;
      let timer = null;
      let scope = 'all';
      let creating = false;
      const term = () => input.value.replace(/^\s*#/, '').trim();
      function select(href, title) {
        change([...objects, { ...newObject('document', { x, y, w: 26, h: 26 }), href, title }]);
        dialog?.close();
        setTool('view');
      }
      for (const [key, label] of [['all', '전체'], ['page', '상세페이지'], ['document', '문서'], ['calendar', '달력']]) {
        const control = element('button', { type: 'button', 'aria-pressed': String(key === scope) });
        control.textContent = label;
        listen(control, 'click', () => {
          scope = key;
          for (const sibling of filters.children) sibling.setAttribute('aria-pressed', String(sibling === control));
          void lookup();
        });
        filters.append(control);
      }
      listen(create, 'click', async () => {
        const title = term();
        if (creating || !title || title.length > 40) return;
        creating = true;
        search?.abort();
        input.disabled = true;
        create.disabled = true;
        message.textContent = '문서를 만드는 중…';
        try {
          const href = supportedDocument(await bridge.postMessage({ token, createNote: title }));
          if (!href) throw Error();
          if (form.isConnected && !closed) select(href, title);
        } catch {
          message.textContent = '문서 생성 결과를 확인하지 못했습니다. 제목을 검색해 주세요.';
        } finally {
          creating = false;
          input.disabled = false;
          create.disabled = true;
        }
      });
      async function lookup() {
        if (creating || !form.isConnected) return;
        search?.abort();
        const request = new AbortController();
        search = request;
        message.textContent = '검색 중…';
        list.replaceChildren();
        try {
          const response = await fetch('/api/project-data', { method: 'POST', signal: request.signal, headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({ kind: 'pageMention', scope, query: term() }) });
          if (!response.ok) throw Error();
          const { data } = await response.json();
          if (request.signal.aborted || !form.isConnected) return;
          list.replaceChildren();
          for (const row of data) {
            const href = supportedDocument(row.href);
            if (!href) continue;
            const entry = element('button', { type: 'button', 'data-popup-menu-row': '' });
            const icon = svg('svg', { width: 16, height: 16, viewBox: '0 0 24 24', fill: 'none', stroke: 'currentColor', 'aria-hidden': 'true' });
            icon.append(svg('path', { d: icons.document }));
            const title = element('span');
            title.textContent = row.title;
            entry.append(icon, title);
            listen(entry, 'click', () => select(href, row.title));
            list.append(entry);
          }
          message.textContent = list.children.length ? '' : '검색된 문서가 없습니다.';
        } catch { if (!request.signal.aborted) message.textContent = '페이지를 검색하지 못했습니다.'; }
      }
      listen(input, 'input', () => {
        create.disabled = !term() || term().length > 40;
        search?.abort();
        clearTimeout(timer);
        timer = setTimeout(lookup, 160);
      });
      queueMicrotask(() => { void lookup(); });
      return input;
    });
  }
  function showDocument(object) {
    if (documentPopup) {
      void closeDocument().then(ok => { if (ok && !closed) showDocument(object); });
      return;
    }
    const href = supportedDocument(object.href);
    if (!href) return;
    const panel = element('section', { 'data-apple-pdf-document': '', 'aria-label': object.title || '연결 문서' });
    const header = element('header');
    const title = element('strong'); title.textContent = object.title || '연결 문서';
    const hide = element('button', { type: 'button', 'aria-label': '연결 문서 닫기' });
    hide.textContent = '닫기';
    listen(hide, 'click', () => { void closeDocument(); });
    const note = href.match(/^\/custom\/([a-zA-Z0-9_-]+)$/);
    const embedded = note ? '/pdf-free-note?note=' + encodeURIComponent(note[1]) + '&embed=1' : href;
    const iframe = element('iframe', { title: title.textContent, src: embedded });
    listen(iframe, 'load', () => {
      const document = iframe.contentDocument;
      if (!document || note) return;
      const style = element('style');
      style.textContent = '#portal-common-tabs, [data-resolution-workspace] > aside, .portal-titlebar, .mobile-navigation-overlay { display: none !important; } [data-resolution-workspace] { display: block !important; } #portal-main { max-width: none !important; padding: 16px !important; }';
      document.head.append(style);
    });
    header.append(title, hide);
    panel.append(header, iframe);
    body.parentElement.append(panel);
    documentPopup = panel;
  }
  async function closeDocument() {
    const popup = documentPopup;
    if (!popup) return true;
    try {
      const view = popup.querySelector('iframe')?.contentWindow;
      if (view) {
        const flush = view.nfFlushPdfFreeNote || view.__nfDisplayPrepare;
        if (flush) await flush.call(view);
      }
      popup.remove();
      if (documentPopup === popup) documentPopup = null;
      return true;
    } catch {
      setStatus('연결 문서를 저장하지 못했습니다.');
      return false;
    }
  }
  listen(drawing, 'click', event => {
    const id = event.target.closest('[data-pdf-object]')?.getAttribute('data-pdf-object');
    const object = objects.find(item => item.id === id);
    if (active !== 'view' || !object) return;
    event.preventDefault();
    event.stopPropagation();
    if (object.kind === 'document') showDocument(object);
    if (object.kind === 'link') {
      const url = new URL(object.href);
      if (['http:', 'https:'].includes(url.protocol)) window.open(url.href, '_blank', 'noopener,noreferrer');
    }
  });
  listen(drawing, 'keydown', event => {
    if (event.key === 'Enter' || event.key === ' ') {
      event.preventDefault();
      event.target.dispatchEvent(new MouseEvent('click', { bubbles: true }));
    }
  });
  listen(layer, 'dblclick', event => {
    if (active !== 'select') return;
    const object = objectAt(...point(event));
    if (object?.kind === 'text') openText([object.x, object.y], object);
  });
  listen(fileInput, 'change', async () => {
    const file = fileInput.files?.[0];
    fileInput.value = '';
    if (!file) return;
    const url = URL.createObjectURL(file);
    try {
      const image = new Image();
      image.src = url;
      await image.decode();
      if (closed) return;
      const ratio = Math.min(1, 1400 / Math.max(image.width, image.height));
      const canvas = element('canvas');
      canvas.width = Math.max(1, Math.round(image.width * ratio));
      canvas.height = Math.max(1, Math.round(image.height * ratio));
      canvas.getContext('2d').drawImage(image, 0, 0, canvas.width, canvas.height);
      const data = canvas.toDataURL('image/webp', .82);
      const viewWidth = body.clientWidth / zoom, viewHeight = body.clientHeight / zoom;
      const fit = Math.min(1, (viewWidth * .62) / canvas.width, (viewHeight * .55) / canvas.height);
      const w = canvas.width * fit, h = canvas.height * fit;
      change([...objects, { ...newObject('image', { x: body.scrollLeft / zoom + (viewWidth - w) / 2,
        y: body.scrollTop / zoom + (viewHeight - h) / 2, w, h }), image: data }]);
    } catch { setStatus('이미지를 열지 못했습니다.'); }
    finally { URL.revokeObjectURL(url); }
  });

  listen(document, 'click', event => {
    if (!event.target.closest?.('[data-apple-pdf-tools], [data-apple-pdf-popover]')) showPopover();
  }, { capture: true });
  listen(document, 'keydown', event => {
    if (event.defaultPrevented || event.isComposing || dialog?.open) return;
    if (useNativeEditor) return;
    if (event.key === 'Escape' && (!toolMenu.hidden || !options.hidden)) {
      event.preventDefault();
      const toggle = toolMenu.hidden ? settings : menuToggle;
      showPopover();
      toggle.focus({ preventScroll: true });
      return;
    }
    if (event.target.closest?.('input, textarea, [contenteditable="true"]')) return;
    if (event.key === 'Escape') {
      event.preventDefault();
      if (active !== 'view') setTool('view');
      else void close(true);
    } else if ((event.metaKey || event.ctrlKey) && event.key.toLowerCase() === 'z' && active !== 'view') {
      event.preventDefault();
      if (event.shiftKey) restore(next, previous); else restore(previous, next);
    } else if (selected && (event.key === 'Backspace' || event.key === 'Delete')) {
      event.preventDefault();
      removeSelected();
    }
  });
  listen(body, 'wheel', event => {
    if (!event.ctrlKey && !event.metaKey) return;
    event.preventDefault();
    changeZoom(zoom * Math.exp(-event.deltaY * .01), [event.clientX, event.clientY]);
  }, { passive: false });

  const touchDistance = (a, b) => Math.hypot(a.clientX - b.clientX, a.clientY - b.clientY);
  listen(body, 'touchstart', event => {
    if (event.touches.length !== 2) return;
    discardGesture();
    const [a, b] = Array.from(event.touches);
    pinch = { distance: Math.max(1, touchDistance(a, b)), zoom };
    if (event.cancelable) event.preventDefault();
  }, { passive: false, capture: true });
  listen(body, 'touchmove', event => {
    if (!pinch || event.touches.length !== 2) return;
    const [a, b] = Array.from(event.touches);
    if (event.cancelable) event.preventDefault();
    changeZoom(pinch.zoom * touchDistance(a, b) / pinch.distance,
      [(a.clientX + b.clientX) / 2, (a.clientY + b.clientY) / 2]);
  }, { passive: false, capture: true });
  listen(body, 'touchend', () => { pinch = null; });
  listen(body, 'touchcancel', () => { pinch = null; });

  const resize = new ResizeObserver(scheduleLayout);
  resize.observe(body);
  resize.observe(toolbar);
  const changes = new MutationObserver(records => {
    if (!body.isConnected) { void close(false); return; }
    if (records.some(record => !layer.contains(record.target) && !toolbar.contains(record.target) &&
      !options.contains(record.target) && !toolMenu.contains(record.target))) scheduleLayout();
  });
  changes.observe(panel, { childList: true, subtree: true, characterData: true });
  const detach = new MutationObserver(() => { if (!body.isConnected) void close(false); });
  detach.observe(document.body, { childList: true, subtree: true });

  async function close(confirmSource) {
    if (closed) return true;
    if (closing) return false;
    closing = true;
    try {
      if (useNativeEditor && !await bridge.postMessage({ token, prepareNativeClose: true })) return false;
      if (confirmSource) {
        document.activeElement?.blur();
        await window.__nfDisplayPrepare?.();
      }
      if (!await closeDocument() || !await saveAnnotations()) return false;
      const left = body.scrollLeft / zoom, top = body.scrollTop / zoom;
      closed = true;
      cancelGesture();
      life.abort();
      resize.disconnect();
      changes.disconnect();
      detach.disconnect();
      cancelAnimationFrame(pendingLayout);
      for (const timer of timers) clearTimeout(timer);
      dialog?.remove();
      documentPopup?.remove();
      layer.remove();
      toolbar.remove();
      options.remove();
      toolMenu.remove();
      for (const attr of ['data-apple-pdf-body', 'data-apple-pdf-zoom', 'data-apple-pdf-fixed-width']) body.removeAttribute(attr);
      for (const name of ['--nf-apple-pdf-zoom', '--nf-apple-pdf-content-width', ...paddingEdges.map(edge => '--nf-apple-pdf-padding-' + edge)]) {
        body.style.removeProperty(name);
      }
      panel.removeAttribute('data-apple-live-detail');
      panel.removeAttribute('data-apple-pdf-native-toolbar');
      panel.style.removeProperty('--nf-apple-pdf-toolbar-height');
      panel.style.removeProperty('--nf-apple-pdf-popover-top');
      style.remove();
      body.scrollLeft = left;
      body.scrollTop = top;
      delete window.__nfAppleLiveDetailPDF;
      await bridge.postMessage({ token, closed: true });
      return true;
    } catch {
      if (closed) return true;
      setStatus('원본 문서 또는 주석을 저장하지 못했습니다.');
      return false;
    } finally { closing = false; }
  }
  window.__nfAppleLiveDetailPDF = { close, nativeCommand };
  refresh();
  body.scrollLeft = scrollAtEntry.left;
  body.scrollTop = scrollAtEntry.top;
  publishViewport();
  return true;
})
