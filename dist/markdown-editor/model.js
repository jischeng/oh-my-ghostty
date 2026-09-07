// Markdown-it remains the single block parser and safe preview renderer.
// All offsets are UTF-16 indices into the original document, as used by CM6.
export function parseBlocks(text) {
    return window.omgMarkdownModel.parseBlocks(text);
}

export function renderFragment(source, options = {}) {
    return window.omgMarkdownModel.renderFragment(source, options);
}

export function ensureMermaid() {
    return window.omgMarkdownModel.ensureMermaid();
}
