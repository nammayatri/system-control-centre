import React, { useRef, useState, useEffect, useCallback } from 'react';
import Editor, { type OnMount, type Monaco } from '@monaco-editor/react';
import type { editor as MonacoEditor } from 'monaco-editor';
import { Button } from '../../../shared/ui/button';
import {
  Dialog, DialogContent, DialogHeader, DialogTitle,
  DialogDescription, DialogBody, DialogFooter,
} from '../../../shared/ui/dialog';
import { toast } from 'sonner';
import { Lock } from 'lucide-react';

// ── UTF-8-safe base64 helpers ────────────────────────────────────────────────
// atob/btoa are byte-oriented and mangle multibyte characters, so route through
// TextEncoder/TextDecoder to round-trip real UTF-8 secrets (URLs, JSON, etc.).
export function decodeBase64(b64: string): string {
  const bin = atob(b64);
  const bytes = Uint8Array.from(bin, c => c.charCodeAt(0));
  return new TextDecoder('utf-8', { fatal: true }).decode(bytes);
}

export function encodeBase64(text: string): string {
  const bytes = new TextEncoder().encode(text);
  let bin = '';
  bytes.forEach(b => { bin += String.fromCharCode(b); });
  return btoa(bin);
}

const BASE64_RE = /^[A-Za-z0-9+/]+={0,2}$/;

// Decide whether a JSON string value is *probably* base64-encoded text rather
// than a plain word that happens to sit in the base64 alphabet ("production",
// "true", …). Guards: minimum length, length a multiple of 4, the base64
// alphabet, a clean canonical round-trip, and a decode to mostly-printable
// UTF-8. Returns the decoded string when it qualifies, otherwise null.
export function detectBase64(raw: string): string | null {
  const s = raw.trim();
  if (s.length < 8 || s.length % 4 !== 0) return null;
  if (!BASE64_RE.test(s)) return null;

  let decoded: string;
  try {
    decoded = decodeBase64(s);
  } catch {
    return null; // invalid UTF-8 → treat as binary, not something to show as text
  }
  if (decoded.length === 0) return null;
  // Canonical base64 re-encodes to itself; anything else is a coincidence.
  if (encodeBase64(decoded) !== s) return null;

  const printable = [...decoded].filter(c => {
    const code = c.codePointAt(0)!;
    return code === 9 || code === 10 || code === 13 || (code >= 32 && code !== 127);
  }).length;
  if (printable / decoded.length < 0.85) return null;

  return decoded;
}

interface Base64Match {
  key: string;
  encoded: string;
  decoded: string;
  startOffset: number; 
  endOffset: number;   
}

const PAIR_RE = /"((?:[^"\\]|\\.)*)"\s*:\s*"((?:[^"\\]|\\.)*)"/g;

export function findBase64Matches(text: string): Base64Match[] {
  const out: Base64Match[] = [];
  let m: RegExpExecArray | null;
  PAIR_RE.lastIndex = 0;
  let lastName: string | null = null;
  while ((m = PAIR_RE.exec(text)) !== null) {
    const key = m[1];
    const value = m[2];
    if (key === 'name') lastName = value;
    const decoded = detectBase64(value);
    if (decoded == null) continue;
    const contentEnd = m.index + m[0].length - 1; // the closing quote
    const contentStart = contentEnd - value.length;
    out.push({
      key: key === 'value' && lastName ? lastName : key,
      encoded: value,
      decoded,
      startOffset: contentStart,
      endOffset: contentEnd,
    });
  }
  return out;
}

interface EnvVarEditorProps {
  value: string;
  onChange: (val: string) => void;
  readOnly?: boolean;
  height?: string;
}

interface PopupState {
  key: string;
  encoded: string;
  startOffset: number;
  endOffset: number;
}

const EnvVarEditor: React.FC<EnvVarEditorProps> = ({ value, onChange, readOnly = false, height = '320px' }) => {
  const editorRef = useRef<MonacoEditor.IStandaloneCodeEditor | null>(null);
  const monacoRef = useRef<Monaco | null>(null);
  const decorationsRef = useRef<string[]>([]);
  const matchesRef = useRef<Base64Match[]>([]);

  const [popup, setPopup] = useState<PopupState | null>(null);
  const [draft, setDraft] = useState('');
  const [showEncoded, setShowEncoded] = useState(false);

  const refreshDecorations = useCallback(() => {
    const ed = editorRef.current;
    const monaco = monacoRef.current;
    if (!ed || !monaco) return;
    const model = ed.getModel();
    if (!model) return;

    const matches = findBase64Matches(model.getValue());
    matchesRef.current = matches;

    const decos: MonacoEditor.IModelDeltaDecoration[] = matches.map(mt => {
      const start = model.getPositionAt(mt.startOffset);
      const end = model.getPositionAt(mt.endOffset);
      const label = mt.key ? `\`${mt.key}\`` : 'value';
      return {
        range: new monaco.Range(start.lineNumber, start.column, end.lineNumber, end.column),
        options: {
          isWholeLine: true,
          className: 'env-base64-line',
          inlineClassName: 'env-base64-cursor',
          glyphMarginClassName: 'env-base64-glyph',
          glyphMarginHoverMessage: { value: `**Base64** — click to decode ${label}` },
          hoverMessage: { value: `**Base64** — click to decode ${label}` },
        },
      };
    });
    decorationsRef.current = model.deltaDecorations(decorationsRef.current, decos);
  }, []);

  const openPopup = useCallback((mt: Base64Match) => {
    let decoded: string;
    try {
      decoded = decodeBase64(mt.encoded);
    } catch {
      toast.error('Value is not valid base64');
      return;
    }
    setPopup({ key: mt.key, encoded: mt.encoded, startOffset: mt.startOffset, endOffset: mt.endOffset });
    setDraft(decoded);
    setShowEncoded(false);
  }, []);

  const handleMount: OnMount = (ed, monaco) => {
    editorRef.current = ed;
    monacoRef.current = monaco;
    refreshDecorations();

    ed.onMouseDown(e => {
      const model = ed.getModel();
      if (!model || !e.target.position) return;
      const { position } = e.target;
      const hit = matchesRef.current.find(
        m => model.getPositionAt(m.startOffset).lineNumber === position.lineNumber,
      );
      if (hit) openPopup(hit);
    });
  };

  // Re-scan whenever the content changes (user edits or a fresh env is loaded).
  useEffect(() => {
    refreshDecorations();
  }, [value, refreshDecorations]);

  const encodedPreview = (() => {
    try {
      return encodeBase64(draft);
    } catch {
      return '';
    }
  })();

  const isLarge = !!popup && popup.encoded.length > 300;
  const editorHeight = isLarge ? '60vh' : '200px';
  const decodedLanguage = (() => {
    const t = draft.trimStart();
    return t.startsWith('{') || t.startsWith('[') ? 'json' : 'plaintext';
  })();

  const applyEncoded = () => {
    const ed = editorRef.current;
    const monaco = monacoRef.current;
    if (!ed || !monaco || !popup) return;
    if (!encodedPreview) {
      toast.error('Could not encode this value');
      return;
    }
    const model = ed.getModel();
    if (!model) return;
    const start = model.getPositionAt(popup.startOffset);
    const end = model.getPositionAt(popup.endOffset);
    ed.executeEdits('env-base64-encode', [{
      range: new monaco.Range(start.lineNumber, start.column, end.lineNumber, end.column),
      text: encodedPreview,
      forceMoveMarkers: true,
    }]);
    setPopup(null);
  };

  return (
    <>
      <Editor
        height={height}
        defaultLanguage="json"
        theme="light"
        value={value}
        onChange={val => onChange(val ?? '')}
        onMount={handleMount}
        options={{
          readOnly,
          glyphMargin: true,
          minimap: { enabled: false },
          fontSize: 13,
          lineNumbers: 'on',
          scrollBeyondLastLine: false,
          wordWrap: 'on',
          tabSize: 2,
          automaticLayout: true,
        }}
      />

      <Dialog open={!!popup} onOpenChange={open => { if (!open) setPopup(null); }}>
        <DialogContent size={isLarge ? '2xl' : 'lg'}>
          <DialogHeader>
            <DialogTitle className="flex items-center gap-2">
              <Lock className="w-4 h-4 text-amber-600" />
              Decoded Value{popup?.key ? <span className="font-mono text-sm text-zinc-500">· {popup.key}</span> : null}
            </DialogTitle>
            <DialogDescription>
              This value is base64-encoded. Edit the decoded text below — {readOnly ? 'the editor is read-only, so changes cannot be saved.' : 'saving re-encodes it to base64 and writes it back into the env.'}
            </DialogDescription>
          </DialogHeader>
          <DialogBody>
            <div className="space-y-4">
              <div>
                <div className="flex items-center justify-between mb-1.5">
                  <label className="block text-[11px] font-medium text-zinc-600 uppercase tracking-wider">Decoded</label>
                  <span className="text-[11px] text-zinc-400">{draft.length.toLocaleString()} chars · drag the bottom edge to resize</span>
                </div>
                {/* resize-y lets the user drag the editor taller for huge configs;
                    Monaco (automaticLayout) tracks the container size. */}
                <div
                  className="border border-zinc-300 rounded-lg overflow-hidden resize-y min-h-[160px]"
                  style={{ height: editorHeight }}
                >
                  <Editor
                    height="100%"
                    language={decodedLanguage}
                    theme="light"
                    value={draft}
                    onChange={val => setDraft(val ?? '')}
                    options={{
                      readOnly,
                      minimap: { enabled: false },
                      fontSize: 13,
                      lineNumbers: 'on',
                      scrollBeyondLastLine: false,
                      wordWrap: 'on',
                      tabSize: 2,
                      automaticLayout: true,
                    }}
                  />
                </div>
              </div>
              <div>
                <button
                  type="button"
                  onClick={() => setShowEncoded(v => !v)}
                  className="text-[11px] font-medium text-zinc-500 hover:text-zinc-700 uppercase tracking-wider cursor-pointer"
                >
                  {showEncoded ? '▾' : '▸'} Will be stored as (base64) · {encodedPreview.length.toLocaleString()} chars
                </button>
                {showEncoded && (
                  <div className="mt-1.5 rounded-lg border border-zinc-200 bg-zinc-50 px-3 py-2 text-xs font-mono text-zinc-500 break-all max-h-40 overflow-y-auto">
                    {encodedPreview || <span className="text-red-500">unencodable value</span>}
                  </div>
                )}
              </div>
            </div>
          </DialogBody>
          <DialogFooter>
            <Button variant="secondary" size="md" onClick={() => setPopup(null)}>Cancel</Button>
            {!readOnly && (
              <Button size="md" onClick={applyEncoded} disabled={!encodedPreview}>Save Encoded</Button>
            )}
          </DialogFooter>
        </DialogContent>
      </Dialog>
    </>
  );
};

export default EnvVarEditor;
