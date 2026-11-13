import { isSupportedLanguage } from '@pierre/highlights';

const C_STYLE_COMMENTS = { lineComment: '//', blockComment: ['/*', '*/'] };
const HASH_COMMENTS = { lineComment: '#' };
const DASH_COMMENTS = { lineComment: '--', blockComment: ['/*', '*/'] };
const XML_COMMENTS = { blockComment: ['<!--', '-->'] };

const STANDARD_BRACKETS = [
  ['{', '}'],
  ['[', ']'],
  ['(', ')'],
];

const STANDARD_PAIRS = [
  { open: '{', close: '}' },
  { open: '[', close: ']' },
  { open: '(', close: ')' },
  { open: '"', close: '"', notIn: ['string'] },
  { open: "'", close: "'", notIn: ['string', 'comment'] },
  { open: '`', close: '`', notIn: ['string', 'comment'] },
];

const SURROUNDING_PAIRS = [
  { open: '{', close: '}' },
  { open: '[', close: ']' },
  { open: '(', close: ')' },
  { open: '"', close: '"' },
  { open: "'", close: "'" },
  { open: '`', close: '`' },
];

export const LANGUAGE_SPECS = [
  { id: 'ghostty', pierre: 'ini', extensions: ['.ghostty'], filenames: ['config.ghostty'], aliases: ['Ghostty', 'ghostty'], comments: HASH_COMMENTS },
  { id: 'conf', pierre: 'ini', extensions: ['.conf', '.ini', '.cfg', '.properties', '.service', '.desktop'], filenames: ['.editorconfig', '.gitconfig'], aliases: ['Conf', 'INI', 'ini', 'conf'], comments: HASH_COMMENTS },
  { id: 'toml', pierre: 'toml', extensions: ['.toml'], filenames: ['Cargo.toml', 'pyproject.toml'], aliases: ['TOML', 'toml'], comments: HASH_COMMENTS },
  { id: 'zig', pierre: 'zig', extensions: ['.zig', '.zon'], filenames: ['build.zig', 'build.zig.zon'], aliases: ['Zig', 'zig', 'zon'], comments: { lineComment: '//' } },
  { id: 'swift', pierre: 'swift', extensions: ['.swift'], filenames: ['Package.swift'], aliases: ['Swift', 'swift'], comments: C_STYLE_COMMENTS },
  { id: 'rust', pierre: 'rust', extensions: ['.rs'], aliases: ['Rust', 'rust', 'rs'], comments: C_STYLE_COMMENTS },
  { id: 'python', pierre: 'python', extensions: ['.py', '.pyi', '.pyw'], aliases: ['Python', 'python', 'py'], comments: HASH_COMMENTS },
  { id: 'typescript', pierre: 'ts', extensions: ['.ts', '.mts', '.cts'], aliases: ['TypeScript', 'typescript', 'ts'], comments: C_STYLE_COMMENTS },
  { id: 'tsx', pierre: 'tsx', extensions: ['.tsx'], aliases: ['TSX', 'typescriptreact', 'tsx'], comments: C_STYLE_COMMENTS },
  { id: 'javascript', pierre: 'js', extensions: ['.js', '.mjs', '.cjs'], aliases: ['JavaScript', 'javascript', 'js'], comments: C_STYLE_COMMENTS },
  { id: 'jsx', pierre: 'jsx', extensions: ['.jsx'], aliases: ['JSX', 'javascriptreact', 'jsx'], comments: C_STYLE_COMMENTS },
  { id: 'json', pierre: 'jsonc', extensions: ['.json', '.jsonc', '.jsonl', '.har'], aliases: ['JSON', 'json', 'jsonc'], comments: C_STYLE_COMMENTS },
  { id: 'yaml', pierre: 'yaml', extensions: ['.yaml', '.yml'], aliases: ['YAML', 'yaml', 'yml'], comments: HASH_COMMENTS },
  { id: 'markdown', pierre: 'markdown', extensions: ['.md', '.markdown', '.mdc', '.mdx'], aliases: ['Markdown', 'markdown', 'md'], comments: XML_COMMENTS },
  { id: 'shell', pierre: 'bash', extensions: ['.sh', '.bash', '.zsh', '.ksh', '.env', '.nu'], filenames: ['zshrc', '.zshrc', '.bashrc', '.zprofile', '.env'], aliases: ['Shell', 'shell', 'shellscript', 'bash', 'sh', 'zsh', 'nushell', 'nu'], comments: HASH_COMMENTS },
  { id: 'fish', pierre: 'fish', extensions: ['.fish'], aliases: ['Fish', 'fish'], comments: HASH_COMMENTS },
  { id: 'c', pierre: 'c', extensions: ['.c', '.h'], aliases: ['C', 'c'], comments: C_STYLE_COMMENTS },
  { id: 'cpp', pierre: 'cpp', extensions: ['.cpp', '.cc', '.cxx', '.hpp', '.hh', '.hxx', '.ipp', '.metal'], aliases: ['C++', 'cpp', 'c++', 'cc', 'cxx', 'metal'], comments: C_STYLE_COMMENTS },
  { id: 'objective-c', pierre: 'objc', extensions: ['.m', '.mm'], aliases: ['Objective-C', 'objc', 'objective-c', 'objective-cpp'], comments: C_STYLE_COMMENTS },
  { id: 'go', pierre: 'go', extensions: ['.go'], filenames: ['go.mod'], aliases: ['Go', 'go', 'golang'], comments: C_STYLE_COMMENTS },
  { id: 'html', pierre: 'html', extensions: ['.html', '.htm', '.xhtml', '.vue', '.svelte', '.astro'], aliases: ['HTML', 'html', 'htm'], comments: XML_COMMENTS },
  { id: 'css', pierre: 'css', extensions: ['.css'], aliases: ['CSS', 'css'], comments: { blockComment: ['/*', '*/'] } },
  { id: 'scss', pierre: 'scss', extensions: ['.scss', '.less'], aliases: ['SCSS', 'scss', 'less'], comments: C_STYLE_COMMENTS },
  { id: 'xml', pierre: 'xml', extensions: ['.xml', '.svg', '.plist', '.storyboard', '.xib', '.csproj', '.xsd', '.xsl'], aliases: ['XML', 'xml', 'svg', 'plist'], comments: XML_COMMENTS },
  { id: 'sql', pierre: 'sql', extensions: ['.sql'], aliases: ['SQL', 'sql'], comments: DASH_COMMENTS },
  { id: 'lua', pierre: 'lua', extensions: ['.lua', '.luau'], aliases: ['Lua', 'lua'], comments: { lineComment: '--', blockComment: ['--[[', ']]'] } },
  { id: 'nix', pierre: 'nix', extensions: ['.nix'], aliases: ['Nix', 'nix'], comments: { lineComment: '#', blockComment: ['/*', '*/'] } },
  { id: 'dockerfile', pierre: 'dockerfile', extensions: ['.dockerfile'], filenames: ['Dockerfile', 'Containerfile'], aliases: ['Dockerfile', 'dockerfile', 'docker'], comments: HASH_COMMENTS },
  { id: 'makefile', pierre: 'makefile', extensions: ['.mk', '.mak'], filenames: ['Makefile', 'makefile', 'GNUmakefile', 'Justfile', 'justfile'], aliases: ['Makefile', 'makefile', 'make', 'just'], comments: HASH_COMMENTS },
  { id: 'cmake', pierre: 'cmake', extensions: ['.cmake'], filenames: ['CMakeLists.txt'], aliases: ['CMake', 'cmake'], comments: HASH_COMMENTS },
  { id: 'java', pierre: 'java', extensions: ['.java'], aliases: ['Java', 'java'], comments: C_STYLE_COMMENTS },
  { id: 'kotlin', pierre: 'kotlin', extensions: ['.kt', '.kts'], aliases: ['Kotlin', 'kotlin', 'kt'], comments: C_STYLE_COMMENTS },
  { id: 'csharp', pierre: 'csharp', extensions: ['.cs'], aliases: ['C#', 'csharp', 'cs'], comments: C_STYLE_COMMENTS },
  { id: 'ruby', pierre: 'ruby', extensions: ['.rb', '.gemspec', '.rake'], filenames: ['Gemfile', 'Rakefile'], aliases: ['Ruby', 'ruby', 'rb'], comments: HASH_COMMENTS },
  { id: 'php', pierre: 'php', extensions: ['.php'], aliases: ['PHP', 'php'], comments: C_STYLE_COMMENTS },
  { id: 'graphql', pierre: 'graphql', extensions: ['.graphql', '.gql'], aliases: ['GraphQL', 'graphql', 'gql'], comments: HASH_COMMENTS },
  { id: 'protobuf', pierre: 'proto', extensions: ['.proto'], aliases: ['Protocol Buffers', 'protobuf', 'proto'], comments: C_STYLE_COMMENTS },
  { id: 'wgsl', pierre: 'wgsl', extensions: ['.wgsl', '.glsl', '.vert', '.frag', '.hlsl'], aliases: ['WGSL', 'wgsl', 'glsl'], comments: C_STYLE_COMMENTS },
  { id: 'diff', pierre: 'diff', extensions: ['.diff', '.patch'], aliases: ['Diff', 'diff', 'patch'], comments: HASH_COMMENTS },
];

const aliasToMonacoId = new Map();
const extToMonacoId = new Map();
const filenameToMonacoId = new Map();
const monacoIdToPierre = new Map();

for (const spec of LANGUAGE_SPECS) {
  monacoIdToPierre.set(spec.id, spec.pierre);
  aliasToMonacoId.set(spec.id.toLowerCase(), spec.id);
  aliasToMonacoId.set(spec.pierre.toLowerCase(), spec.id);
  for (const alias of spec.aliases ?? []) {
    aliasToMonacoId.set(alias.toLowerCase(), spec.id);
  }
  for (const ext of spec.extensions ?? []) {
    extToMonacoId.set(ext.toLowerCase(), spec.id);
    aliasToMonacoId.set(ext.slice(1).toLowerCase(), spec.id);
  }
  for (const fname of spec.filenames ?? []) {
    filenameToMonacoId.set(fname.toLowerCase(), spec.id);
  }
}

export function resolveMonacoLanguageId({ languageHint, path, uri } = {}) {
  if (typeof languageHint === 'string' && languageHint.trim().length > 0) {
    const raw = languageHint.trim().toLowerCase();
    const cleaned = raw.startsWith('.') ? raw.slice(1) : raw;
    if (cleaned === 'plaintext' || cleaned === 'plain' || cleaned === 'text' || cleaned === 'txt') {
      return 'plaintext';
    }
    if (aliasToMonacoId.has(raw)) return aliasToMonacoId.get(raw);
    if (aliasToMonacoId.has(cleaned)) return aliasToMonacoId.get(cleaned);
    if (extToMonacoId.has(`.${cleaned}`)) return extToMonacoId.get(`.${cleaned}`);
    if (isSupportedLanguage(cleaned)) {
      return `pierre-${cleaned}`;
    }
  }

  const candidatePath = extractPath(path, uri);
  if (candidatePath) {
    const slashIdx = Math.max(candidatePath.lastIndexOf('/'), candidatePath.lastIndexOf('\\'));
    const basename = (slashIdx >= 0 ? candidatePath.slice(slashIdx + 1) : candidatePath);
    const lowerBase = basename.toLowerCase();

    if (filenameToMonacoId.has(lowerBase)) {
      return filenameToMonacoId.get(lowerBase);
    }
    if (lowerBase === 'config' && candidatePath.toLowerCase().includes('ghostty')) {
      return 'ghostty';
    }
    if (lowerBase.startsWith('.env.')) {
      return 'shell';
    }

    const dotIdx = lowerBase.lastIndexOf('.');
    if (dotIdx >= 0) {
      const ext = lowerBase.slice(dotIdx);
      if (extToMonacoId.has(ext)) {
        return extToMonacoId.get(ext);
      }
      const extName = ext.slice(1);
      if (extName && isSupportedLanguage(extName)) {
        return `pierre-${extName}`;
      }
    }
  }

  return 'plaintext';
}

export function getPierreLanguageForMonacoId(monacoId) {
  if (!monacoId || monacoId === 'plaintext') return null;
  if (monacoIdToPierre.has(monacoId)) {
    const mapped = monacoIdToPierre.get(monacoId);
    return isSupportedLanguage(mapped) ? mapped : null;
  }
  if (monacoId.startsWith('pierre-')) {
    const raw = monacoId.slice('pierre-'.length);
    return isSupportedLanguage(raw) ? raw : null;
  }
  if (isSupportedLanguage(monacoId)) {
    return monacoId;
  }
  return null;
}

export function ensureMonacoLanguageRegistered(monaco, monacoId, registeredSet) {
  if (!monacoId || monacoId === 'plaintext' || registeredSet.has(monacoId)) {
    return;
  }
  const existing = new Set(monaco.languages.getLanguages().map((l) => l.id));
  const spec = LANGUAGE_SPECS.find((s) => s.id === monacoId);
  if (!existing.has(monacoId)) {
    monaco.languages.register({
      id: monacoId,
      extensions: spec?.extensions ?? [],
      filenames: spec?.filenames ?? [],
      aliases: spec?.aliases ?? [monacoId],
    });
  }
  monaco.languages.setLanguageConfiguration(monacoId, {
    comments: spec?.comments ?? C_STYLE_COMMENTS,
    brackets: STANDARD_BRACKETS,
    autoClosingPairs: STANDARD_PAIRS,
    surroundingPairs: SURROUNDING_PAIRS,
    folding: { offSide: monacoId === 'python' || monacoId === 'yaml' },
  });
  registeredSet.add(monacoId);
}

export function registerCoreLanguages(monaco) {
  const registeredSet = new Set();
  for (const spec of LANGUAGE_SPECS) {
    ensureMonacoLanguageRegistered(monaco, spec.id, registeredSet);
  }
  return registeredSet;
}

function extractPath(path, uri) {
  if (typeof path === 'string' && path.length > 0) {
    return path;
  }
  if (typeof uri === 'string' && uri.length > 0) {
    try {
      const parsed = new URL(uri);
      return decodeURIComponent(parsed.pathname || '');
    } catch {
      return uri;
    }
  }
  return '';
}
