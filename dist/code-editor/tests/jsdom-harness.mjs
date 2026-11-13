import fs from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { JSDOM } from 'jsdom';

const __dirname = path.dirname(fileURLToPath(import.meta.url));
export const REPO_ROOT = path.resolve(__dirname, '../../..');
export const CODE_EDITOR_OUT_DIR = path.join(REPO_ROOT, 'macos/Resources/CodeEditor');

export async function createWorkbenchDom() {
  const html = await fs.readFile(path.join(CODE_EDITOR_OUT_DIR, 'index.html'), 'utf8');
  const editorJs = await fs.readFile(path.join(CODE_EDITOR_OUT_DIR, 'editor.js'), 'utf8');

  const dom = new JSDOM(html, {
    url: 'https://omg-editor.local/index.html',
    runScripts: 'outside-only',
    pretendToBeVisual: true,
  });

  const { window } = dom;
  const messages = [];

  // Install standard browser shims Monaco expects in headless jsdom
  window.webkit = {
    messageHandlers: {
      codeEditor: {
        postMessage(msg) {
          messages.push(structuredClone(msg));
        },
      },
    },
  };

  if (!window.matchMedia) {
    window.matchMedia = (query) => ({
      matches: query.includes('dark'),
      media: query,
      onchange: null,
      addListener() {},
      removeListener() {},
      addEventListener() {},
      removeEventListener() {},
      dispatchEvent() {
        return false;
      },
    });
  }

  if (!window.ResizeObserver) {
    window.ResizeObserver = class ResizeObserver {
      observe() {}
      unobserve() {}
      disconnect() {}
    };
  }

  if (!window.IntersectionObserver) {
    window.IntersectionObserver = class IntersectionObserver {
      observe() {}
      unobserve() {}
      disconnect() {}
      takeRecords() {
        return [];
      }
    };
  }

  if (!window.document.queryCommandSupported) {
    window.document.queryCommandSupported = () => true;
  }
  if (!window.document.execCommand) {
    window.document.execCommand = () => true;
  }

  if (!window.CSS) {
    window.CSS = {};
  }
  if (!window.CSS.escape) {
    window.CSS.escape = (s) => String(s).replace(/[^a-zA-Z0-9_-]/g, '\\$&');
  }

  if (!window.Element.prototype.scrollIntoView) {
    window.Element.prototype.scrollIntoView = function scrollIntoView() {};
  }

  if (!window.PointerEvent) {
    window.PointerEvent = class PointerEvent extends window.MouseEvent {
      constructor(type, init = {}) {
        super(type, init);
        this.pointerId = init.pointerId ?? 1;
        this.pointerType = init.pointerType ?? 'mouse';
        this.isPrimary = init.isPrimary ?? true;
      }
    };
  }

  window.HTMLCanvasElement.prototype.getContext = () => ({
    font: '',
    fillStyle: '',
    clearRect() {},
    fillRect() {},
    fillText() {},
    measureText: (text) => ({
      width: String(text ?? '').length * 7.8,
      actualBoundingBoxAscent: 10,
      actualBoundingBoxDescent: 3,
      fontBoundingBoxAscent: 11,
      fontBoundingBoxDescent: 3,
    }),
    getImageData: (_x, _y, w, h) => ({
      data: new Uint8ClampedArray(Math.max(1, w) * Math.max(1, h) * 4),
    }),
    putImageData() {},
    createImageData: () => [],
    setTransform() {},
    drawImage() {},
    save() {},
    restore() {},
    beginPath() {},
    moveTo() {},
    lineTo() {},
    closePath() {},
    stroke() {},
    translate() {},
    scale() {},
    rotate() {},
    arc() {},
    fill() {},
  });

  if (!window.Worker) {
    window.Worker = class MockWorker {
      constructor() {
        this.onmessage = null;
        this.onerror = null;
      }
      postMessage() {}
      terminate() {}
      addEventListener() {}
      removeEventListener() {}
    };
  }

  // Give container realistic dimensions
  Object.defineProperty(window.HTMLElement.prototype, 'clientWidth', {
    configurable: true,
    get() {
      return 1024;
    },
  });
  Object.defineProperty(window.HTMLElement.prototype, 'clientHeight', {
    configurable: true,
    get() {
      return 768;
    },
  });

  // Expose WebAssembly & TextEncoder/TextDecoder from Node runtime into jsdom window
  window.WebAssembly = WebAssembly;
  window.TextEncoder = TextEncoder;
  window.TextDecoder = TextDecoder;
  window.MessageChannel = MessageChannel;
  window.TransformStream = TransformStream;
  window.ReadableStream = ReadableStream;
  window.WritableStream = WritableStream;
  window.structuredClone = structuredClone;

  window.eval(editorJs);
  // Drain microtasks so @pierre/highlights WASM + Zed theme preload completes
  await new Promise((resolve) => setTimeout(resolve, 0));

  return {
    dom,
    window,
    document: window.document,
    omgEditor: window.omgEditor,
    messages,
    cleanup() {
      try {
        window.omgEditor?.dispose?.();
      } catch {
        // Ignore teardown errors
      }
      dom.window.close();
    },
  };
}
