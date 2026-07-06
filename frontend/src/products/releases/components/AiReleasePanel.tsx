import { useState } from 'react';
import { Sparkles, ShieldAlert, MessageSquare, Loader2, Copy, Check } from 'lucide-react';
import { Button } from '../../../shared/ui/button';
import { Card, CardContent, CardHeader, CardTitle } from '../../../shared/ui/card';
import { PermissionGate } from '../../../core/auth/PermissionGate';
import { useReleaseAiSummary, useReleaseAiRisk, useReleaseAiAsk } from '../hooks';
import type { AiResp } from '../api';

/**
 * AI panel for a release detail page. Summarise / assess-risk / freeform-Q&A over
 * the release's context. Permission-gated (AI_SUMMARIZE); if AI is disabled the
 * backend returns `available:false` and we show a quiet notice (no error toast).
 * AI output is rendered as escaped, pre-wrapped text — never as HTML.
 */
export function AiReleasePanel({ releaseId }: { releaseId: string }) {
  const summary = useReleaseAiSummary(releaseId);
  const risk = useReleaseAiRisk(releaseId);
  const ask = useReleaseAiAsk(releaseId);
  const [result, setResult] = useState<AiResp | null>(null);
  const [question, setQuestion] = useState('');
  const [copied, setCopied] = useState(false);

  const busy = summary.isPending || risk.isPending || ask.isPending;
  // Reset the "copied" tick whenever a new result arrives so it isn't stale.
  const onSuccess = (data: AiResp) => {
    setResult(data);
    setCopied(false);
  };

  const copySummary = async (text: string) => {
    try {
      await navigator.clipboard.writeText(text);
      setCopied(true);
      setTimeout(() => setCopied(false), 1500);
    } catch {
      /* clipboard blocked (insecure context / permissions) — silently ignore */
    }
  };

  return (
    <PermissionGate product="autopilot" permission="AI_SUMMARIZE">
      <Card>
        <CardHeader className="flex flex-row items-center justify-between gap-2">
          <CardTitle className="flex items-center gap-2 text-base">
            <Sparkles size={16} className="text-violet-500" /> AI
          </CardTitle>
          <div className="flex items-center gap-2">
            <Button
              size="sm"
              variant="secondary"
              loading={summary.isPending}
              disabled={busy && !summary.isPending}
              onClick={() => summary.mutate(false, { onSuccess })}
            >
              <Sparkles size={14} /> Summarize
            </Button>
            <Button
              size="sm"
              variant="secondary"
              loading={risk.isPending}
              disabled={busy && !risk.isPending}
              onClick={() => risk.mutate(false, { onSuccess })}
            >
              <ShieldAlert size={14} /> Assess risk
            </Button>
          </div>
        </CardHeader>
        <CardContent className="space-y-3">
          <form
            className="flex items-center gap-2"
            onSubmit={(e) => {
              e.preventDefault();
              const q = question.trim();
              if (q) ask.mutate(q, { onSuccess });
            }}
          >
            <input
              className="flex-1 rounded-md border border-zinc-200 px-3 py-1.5 text-sm focus:outline-none focus:ring-1 focus:ring-violet-400"
              placeholder="Ask about this release…"
              value={question}
              onChange={(e) => setQuestion(e.target.value)}
            />
            <Button
              size="sm"
              type="submit"
              variant="ghost"
              loading={ask.isPending}
              disabled={(busy && !ask.isPending) || !question.trim()}
            >
              <MessageSquare size={14} /> Ask
            </Button>
          </form>

          {busy && !result && (
            <div className="flex items-center gap-2 text-sm text-zinc-500">
              <Loader2 size={14} className="animate-spin" /> Generating…
            </div>
          )}

          {result && result.available === false && (
            <p className="text-sm text-zinc-500">{result.reason || 'AI is unavailable.'}</p>
          )}

          {result && result.available && result.summary && (
            <div className="group relative rounded-md bg-zinc-50 p-3 pr-10 text-sm leading-relaxed text-zinc-800">
              <button
                type="button"
                onClick={() => copySummary(result.summary!)}
                title={copied ? 'Copied' : 'Copy to clipboard'}
                aria-label={copied ? 'Copied' : 'Copy summary to clipboard'}
                className="absolute right-2 top-2 rounded p-1 text-zinc-400 transition-colors hover:bg-zinc-200 hover:text-zinc-700"
              >
                {copied ? <Check size={14} className="text-emerald-600" /> : <Copy size={14} />}
              </button>
              <div className="whitespace-pre-wrap">{result.summary}</div>
            </div>
          )}

          {result && result.available && (
            <div className="flex items-center gap-2 text-xs text-zinc-400">
              {result.cached && (
                <span className="rounded bg-zinc-100 px-1.5 py-0.5 text-zinc-500">cached</span>
              )}
              {result.model && <span>{result.model}</span>}
              {typeof result.outputTokens === 'number' && result.outputTokens > 0 && (
                <span>· {result.outputTokens} tokens</span>
              )}
            </div>
          )}
        </CardContent>
      </Card>
    </PermissionGate>
  );
}
