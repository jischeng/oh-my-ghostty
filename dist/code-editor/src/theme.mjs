const THEME_NAME = 'omg-theme';

function clampByte(n) {
  return Math.max(0, Math.min(255, Math.round(Number(n) || 0)));
}

function byteToHex(n) {
  return clampByte(n).toString(16).padStart(2, '0');
}

export function normalizeHexColor(input, fallbackHex) {
  if (typeof input !== 'string' || input.trim().length === 0) {
    return fallbackHex;
  }
  const raw = input.trim();
  if (raw === 'transparent') {
    return '#00000000';
  }
  if (raw.startsWith('#')) {
    const h = raw.slice(1);
    if (h.length === 3) {
      return `#${h[0]}${h[0]}${h[1]}${h[1]}${h[2]}${h[2]}`.toLowerCase();
    }
    if (h.length === 4) {
      return `#${h[0]}${h[0]}${h[1]}${h[1]}${h[2]}${h[2]}${h[3]}${h[3]}`.toLowerCase();
    }
    if (h.length === 6 || h.length === 8) {
      return `#${h.toLowerCase()}`;
    }
  } else if (/^[0-9a-fA-F]{6}([0-9a-fA-F]{2})?$/.test(raw)) {
    return `#${raw.toLowerCase()}`;
  }

  const rgbaMatch = raw.match(/^rgba?\(\s*([\d.]+)\s*,\s*([\d.]+)\s*,\s*([\d.]+)(?:\s*,\s*([\d.]+))?\s*\)$/i);
  if (rgbaMatch) {
    const r = byteToHex(rgbaMatch[1]);
    const g = byteToHex(rgbaMatch[2]);
    const b = byteToHex(rgbaMatch[3]);
    if (rgbaMatch[4] !== undefined) {
      const alphaFloat = Math.max(0, Math.min(1, parseFloat(rgbaMatch[4])));
      const a = byteToHex(alphaFloat * 255);
      return `#${r}${g}${b}${a}`;
    }
    return `#${r}${g}${b}`;
  }

  return fallbackHex;
}

function toRuleHex(input, fallbackSixChar) {
  const hex = normalizeHexColor(input, `#${fallbackSixChar}`).slice(1);
  return hex.slice(0, 6);
}

function toSolidHex(hexColor, fallbackHex) {
  const norm = normalizeHexColor(hexColor, fallbackHex);
  return norm.slice(0, 7);
}

function ensureMinimumAlphaHex(hexColor, minAlphaFloat) {
  const norm = normalizeHexColor(hexColor, '#000000');
  const currentAlpha = norm.length === 9 ? parseInt(norm.slice(7, 9), 16) / 255 : 1;
  if (currentAlpha >= minAlphaFloat) {
    return norm;
  }
  const alphaByte = byteToHex(minAlphaFloat * 255);
  return alphaByte === 'ff' ? norm.slice(0, 7) : `${norm.slice(0, 7)}${alphaByte}`;
}

function normalizeBaseTheme(base) {
  if (base === 'vs' || base === 'light') return 'vs';
  if (base === 'hc-black' || base === 'hc-light') return base;
  return 'vs-dark';
}

export function buildOmgThemeData(spec = {}) {
  const base = normalizeBaseTheme(spec.base);
  const isDark = base !== 'vs' && base !== 'hc-light';

  const fgHex = normalizeHexColor(spec.foreground, isDark ? '#abb2bf' : '#383a42');
  const cursorHex = normalizeHexColor(spec.cursor, isDark ? '#528bff' : '#526fff');
  const selectionHex = normalizeHexColor(spec.selection, isDark ? '#3e445199' : '#d5d9e299');
  const lineHighlightHex = normalizeHexColor(spec.lineHighlight, isDark ? '#528bff14' : '#4078f210');

  const fgRule = toRuleHex(fgHex, isDark ? 'abb2bf' : '383a42');
  const keywordRule = toRuleHex(spec.keywords, isDark ? 'c678dd' : 'a626a4');
  const functionRule = toRuleHex(spec.functions ?? spec.commands, isDark ? '61afef' : '4078f2');
  const typeRule = toRuleHex(spec.types, isDark ? 'e5c07b' : 'c18401');
  const stringRule = toRuleHex(spec.strings, isDark ? '98c379' : '50a14f');
  const numberRule = toRuleHex(spec.numbers ?? spec.values, isDark ? 'd19a66' : '986801');
  const commentRule = toRuleHex(spec.comments, isDark ? '5c6370' : 'a0a1a7');
  const variableRule = toRuleHex(spec.variables, isDark ? 'e06c75' : 'e45649');
  const attributeRule = toRuleHex(spec.attributes ?? spec.types, isDark ? 'd19a66' : '986801');

  const rules = [
    { token: '', foreground: fgRule },
    { token: 'keyword', foreground: keywordRule },
    { token: 'function', foreground: functionRule },
    { token: 'type', foreground: typeRule },
    { token: 'string', foreground: stringRule },
    { token: 'string.escape', foreground: numberRule },
    { token: 'regexp', foreground: stringRule },
    { token: 'number', foreground: numberRule },
    { token: 'constant', foreground: numberRule },
    { token: 'comment', foreground: commentRule, fontStyle: 'italic' },
    { token: 'variable', foreground: variableRule },
    { token: 'variable.property', foreground: variableRule },
    { token: 'attribute', foreground: attributeRule },
    { token: 'operator', foreground: keywordRule },
    { token: 'delimiter', foreground: fgRule },
    { token: 'emphasis', fontStyle: 'italic' },
    { token: 'strong', fontStyle: 'bold' },
    { token: 'inserted', foreground: isDark ? '3fb950' : '1a7f37' },
    { token: 'deleted', foreground: isDark ? 'f85149' : 'cf222e' },
  ];

  const colors = {
    // Transparent backgrounds so OMG's native EditorBackdrop glass/blur shines through!
    'editor.background': '#00000000',
    'editorGutter.background': '#00000000',
    'minimap.background': '#00000000',
    'editorOverviewRuler.background': '#00000000',
    'editorOverviewRuler.border': '#00000000',

    // Semi-translucent sticky scroll & floating widgets
    'editorStickyScroll.background': isDark ? '#14171fcc' : '#f4f6facc',
    'editorStickyScrollHover.background': isDark ? '#1e2330dd' : '#e8ecf4dd',
    'editorStickyScroll.border': isDark ? '#ffffff14' : '#00000012',
    'editorStickyScroll.shadow': '#00000000',

    'editor.foreground': fgHex,
    'editorCursor.foreground': cursorHex,
    'editor.selectionBackground': selectionHex,
    'editor.inactiveSelectionBackground': isDark ? '#3e445155' : '#d5d9e255',
    'editor.lineHighlightBackground': lineHighlightHex,
    'editor.lineHighlightBorder': '#00000000',

    'editorLineNumber.foreground': isDark ? '#6e7681aa' : '#6e7781aa',
    'editorLineNumber.activeForeground': fgHex,

    // Widget chrome (hover, suggest, find, quickOutline)
    'editorWidget.background': isDark ? '#1a1d26f2' : '#f8f9fcf5',
    'editorWidget.border': isDark ? '#ffffff1f' : '#0000001a',
    'editorHoverWidget.background': isDark ? '#1a1d26f2' : '#f8f9fcf5',
    'editorHoverWidget.border': isDark ? '#ffffff1f' : '#0000001a',
    'editorSuggestWidget.background': isDark ? '#1a1d26f5' : '#f8f9fcf7',
    'editorSuggestWidget.border': isDark ? '#ffffff1f' : '#0000001a',
    'quickInput.background': isDark ? '#1a1d26f5' : '#f8f9fcf7',

    // Diff editor translucent tints over glass backdrop
    'diffEditor.insertedTextBackground': isDark ? '#2ea04333' : '#2da44e29',
    'diffEditor.insertedLineBackground': isDark ? '#2ea0431f' : '#2da44e17',
    'diffEditor.removedTextBackground': isDark ? '#f8514933' : '#cf222e29',
    'diffEditor.removedLineBackground': isDark ? '#f851491f' : '#cf222e17',
    'diffEditor.unchangedRegionBackground': isDark ? '#161922b8' : '#eef1f6b8',
    'diffEditor.unchangedCodeBackground': '#00000000',
    'diffEditor.diagonalFill': isDark ? '#ffffff12' : '#00000010',
  };

  const addedFg = normalizeHexColor(
    spec.added ?? spec.addition,
    isDark ? '#3fb950' : '#1a7f37'
  );
  const deletedFg = normalizeHexColor(
    spec.deleted ?? spec.deletion,
    isDark ? '#f85149' : '#cf222e'
  );
  const modifiedFg = normalizeHexColor(
    spec.modified,
    isDark ? '#58a6ff' : '#0969da'
  );
  // @pierre/diffs mixes --diffs-bg-addition-override / --diffs-bg-deletion-override
  // against --diffs-bg (transparent) via color-mix(in lab, transparent 80..86%, target),
  // so pass high-alpha / solid base colors here to achieve ~14-15% rendered line tint
  // and ~20% gutter number tint instead of double-diluted 2.8% alpha.
  // Meanwhile --diffs-bg-*-emphasis-override is applied directly on [data-diff-span]
  // without color-mix, so keep word-emphasis alpha at ~34-36%.
  const addedLineBg = ensureMinimumAlphaHex(
    normalizeHexColor(
      spec.addedBackground ?? spec.insertedLineBackground,
      isDark ? '#2ea043bf' : '#2da44e'
    ),
    isDark ? 0.72 : 0.92
  );
  const addedNumberBg = normalizeHexColor(
    spec.addedNumberBackground,
    toSolidHex(addedLineBg, isDark ? '#2ea043' : '#2da44e')
  );
  const addedWordBg = normalizeHexColor(
    spec.addedEmphasisBackground ?? spec.insertedTextBackground,
    isDark ? '#2ea0435c' : '#2da44e57'
  );
  const deletedLineBg = ensureMinimumAlphaHex(
    normalizeHexColor(
      spec.deletedBackground ?? spec.removedLineBackground,
      isDark ? '#f85149bf' : '#cf222e'
    ),
    isDark ? 0.72 : 0.92
  );
  const deletedNumberBg = normalizeHexColor(
    spec.deletedNumberBackground,
    toSolidHex(deletedLineBg, isDark ? '#f85149' : '#cf222e')
  );
  const deletedWordBg = normalizeHexColor(
    spec.deletedEmphasisBackground ?? spec.removedTextBackground,
    isDark ? '#f851495c' : '#cf222e57'
  );
  const hoverBg = ensureMinimumAlphaHex(
    normalizeHexColor(spec.pierreHoverBackground, isDark ? '#8b949e8c' : '#57606ab3'),
    0.5
  );
  const selectionBg = ensureMinimumAlphaHex(selectionHex, 0.75);

  const pierre = {
    themeType: isDark ? 'dark' : 'light',
    foreground: `#${fgRule}`,
    keywords: `#${keywordRule}`,
    functions: `#${functionRule}`,
    types: `#${typeRule}`,
    strings: `#${stringRule}`,
    numbers: `#${numberRule}`,
    comments: `#${commentRule}`,
    variables: `#${variableRule}`,
    attributes: `#${attributeRule}`,
    selection: selectionHex,
    selectionBg,
    lineHighlight: lineHighlightHex,
    hoverBg,
    lineNumber: isDark ? '#7d8590b8' : '#6e7781cc',
    addedFg,
    deletedFg,
    modifiedFg,
    addedLineBg,
    addedNumberBg,
    addedWordBg,
    deletedLineBg,
    deletedNumberBg,
    deletedWordBg,
    separatorBg: isDark ? 'rgba(255, 255, 255, 0.045)' : 'rgba(15, 23, 42, 0.045)',
    bufferBg: isDark ? 'rgba(255, 255, 255, 0.022)' : 'rgba(15, 23, 42, 0.022)',
  };

  return {
    base,
    inherit: true,
    rules,
    colors,
    isDark,
    pierre,
  };
}

export function applyPierreCssVariables(targetEl, pierrePalette) {
  if (!targetEl || !targetEl.style || !pierrePalette) return;
  const s = targetEl.style;
  // Strictly transparent glass backdrop (#00000000) so OMG EditorBackdrop vibrancy shines through
  s.setProperty('--diffs-bg', 'transparent');
  s.setProperty('--diffs-dark-bg', 'transparent');
  s.setProperty('--diffs-light-bg', 'transparent');
  s.setProperty('--diffs-bg-context-override', 'transparent');
  s.setProperty('--diffs-bg-context-gutter-override', 'transparent');
  s.setProperty('--diffs-bg-buffer-override', pierrePalette.bufferBg);
  s.setProperty('--diffs-bg-separator-override', pierrePalette.separatorBg);

  s.setProperty('--omg-diff-fg', pierrePalette.foreground);
  s.setProperty('--diffs-fg', pierrePalette.foreground);
  s.setProperty('--diffs-dark', pierrePalette.foreground);
  s.setProperty('--diffs-light', pierrePalette.foreground);
  s.setProperty('--diffs-fg-number-override', pierrePalette.lineNumber);

  // Syntax highlighting token variables consumed by our registered Zed theme (`omg-pierre`)
  s.setProperty('--omg-syntax-foreground', pierrePalette.foreground);
  s.setProperty('--omg-syntax-keyword', pierrePalette.keywords);
  s.setProperty('--omg-syntax-function', pierrePalette.functions);
  s.setProperty('--omg-syntax-type', pierrePalette.types);
  s.setProperty('--omg-syntax-string', pierrePalette.strings);
  s.setProperty('--omg-syntax-number', pierrePalette.numbers);
  s.setProperty('--omg-syntax-comment', pierrePalette.comments);
  s.setProperty('--omg-syntax-variable', pierrePalette.variables);
  s.setProperty('--omg-syntax-attribute', pierrePalette.attributes);

  // Diff semantic tints
  s.setProperty('--diffs-addition-color-override', pierrePalette.addedFg);
  s.setProperty('--diffs-deletion-color-override', pierrePalette.deletedFg);
  s.setProperty('--diffs-modified-color-override', pierrePalette.modifiedFg);
  s.setProperty('--diffs-bg-addition-override', pierrePalette.addedLineBg);
  s.setProperty(
    '--diffs-bg-addition-number-override',
    pierrePalette.addedNumberBg ?? pierrePalette.addedLineBg
  );
  s.setProperty('--diffs-bg-addition-emphasis-override', pierrePalette.addedWordBg);
  s.setProperty('--diffs-bg-deletion-override', pierrePalette.deletedLineBg);
  s.setProperty(
    '--diffs-bg-deletion-number-override',
    pierrePalette.deletedNumberBg ?? pierrePalette.deletedLineBg
  );
  s.setProperty('--diffs-bg-deletion-emphasis-override', pierrePalette.deletedWordBg);
  s.setProperty('--diffs-bg-hover-override', pierrePalette.hoverBg ?? pierrePalette.lineHighlight);
  s.setProperty(
    '--diffs-bg-selection-override',
    pierrePalette.selectionBg ?? pierrePalette.selection
  );
}

export function applyOmgTheme(monaco, spec = {}, doc = globalThis.document) {
  const themeData = buildOmgThemeData(spec);
  monaco.editor.defineTheme(THEME_NAME, {
    base: themeData.base,
    inherit: themeData.inherit,
    rules: themeData.rules,
    colors: themeData.colors,
  });
  monaco.editor.setTheme(THEME_NAME);
  if (doc && doc.documentElement) {
    doc.documentElement.dataset.omgTheme = themeData.isDark ? 'dark' : 'light';
    applyPierreCssVariables(doc.documentElement, themeData.pierre);
  }
  return { themeName: THEME_NAME, themeData };
}
