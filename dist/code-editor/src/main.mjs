import './styles.css';
import { monaco } from './monaco-imports.mjs';
import { createOmgEditorWorkbench } from './workbench.mjs';

/* global __OMG_EDITOR_WORKER_CODE__ */

let cachedWorkerBlobUrl = null;

function createInlineEditorWorker() {
  const workerSource =
    typeof __OMG_EDITOR_WORKER_CODE__ === 'string' ? __OMG_EDITOR_WORKER_CODE__ : '';

  if (workerSource && typeof Blob !== 'undefined' && typeof URL !== 'undefined' && URL.createObjectURL) {
    try {
      if (!cachedWorkerBlobUrl) {
        const blob = new Blob([workerSource], { type: 'text/javascript' });
        cachedWorkerBlobUrl = URL.createObjectURL(blob);
      }
      return new Worker(cachedWorkerBlobUrl, { name: 'omg-monaco-worker' });
    } catch {
      // Fall back to relative same-origin worker script below
    }
  }

  return new Worker('./editor.worker.js', { name: 'omg-monaco-worker' });
}

globalThis.MonacoEnvironment = {
  getWorker() {
    return createInlineEditorWorker();
  },
};

createOmgEditorWorkbench({ monaco });
