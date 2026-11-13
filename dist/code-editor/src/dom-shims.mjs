// Defensive Constructable Stylesheets & ShadowRoot adoptedStyleSheets fallback for
// non-Chromium/WebKit headless DOM environments (e.g. jsdom in unit tests).
// Safari 17+ / WKWebView implements both natively in C++, so this is a no-op in OMG runtime.
if (typeof globalThis.CSSStyleSheet !== 'undefined') {
  const proto = globalThis.CSSStyleSheet.prototype;
  if (typeof proto.replaceSync !== 'function') {
    proto.replaceSync = function replaceSync(cssText) {
      this._omgCssText = String(cssText ?? '');
    };
  }
}

if (
  typeof globalThis.ShadowRoot !== 'undefined' &&
  !('adoptedStyleSheets' in globalThis.ShadowRoot.prototype)
) {
  Object.defineProperty(globalThis.ShadowRoot.prototype, 'adoptedStyleSheets', {
    configurable: true,
    get() {
      return this._omgAdoptedStyleSheets ?? [];
    },
    set(sheets) {
      const list = Array.isArray(sheets) ? sheets : [];
      this._omgAdoptedStyleSheets = list;
      let shimStyle = this.querySelector('style[data-omg-adopted-shim]');
      if (list.length === 0) {
        shimStyle?.remove();
        return;
      }
      if (!shimStyle && this.ownerDocument) {
        shimStyle = this.ownerDocument.createElement('style');
        shimStyle.setAttribute('data-omg-adopted-shim', '');
        this.prepend(shimStyle);
      }
      if (shimStyle) {
        shimStyle.textContent = list.map((s) => s?._omgCssText ?? '').join('\n');
      }
    },
  });
}
