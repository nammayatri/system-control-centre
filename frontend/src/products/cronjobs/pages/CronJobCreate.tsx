import { useState } from 'react';
import { Link, useNavigate } from 'react-router-dom';
import { CheckCircle2, FileCode, ShieldCheck } from 'lucide-react';
import { Button } from '../../../shared/ui/button';
import { Card } from '../../../shared/ui/card';
import { useCreate, useValidate } from '../hooks';
import { IssueList } from '../IssueList';
import { useNamespaceParam } from '../useNamespaceParam';
import type { ValidateResult } from '../types';

const select = 'h-9 rounded-lg border border-zinc-300 bg-white px-3 text-sm focus:border-zinc-500 focus:outline-none';

const TEMPLATE = `apiVersion: batch/v1
kind: CronJob
metadata:
  name: my-cronjob
spec:
  schedule: "*/15 * * * *"
  concurrencyPolicy: Forbid
  jobTemplate:
    spec:
      template:
        spec:
          restartPolicy: Never
          containers:
            - name: main
              image: registry.example.com/my-image:tag
              command: ["/bin/sh", "-c", "echo hello"]
              env:
                - name: LOG_LEVEL
                  value: info
                - name: DB_PASSWORD
                  valueFrom:
                    secretKeyRef:
                      name: my-secret
                      key: DB_PASSWORD
`;

export default function CronJobCreate() {
  const { namespace, setNamespace, namespaces } = useNamespaceParam();
  const [yaml, setYaml] = useState(TEMPLATE);
  // What the verdict below was computed for, so an edit after validating re-locks Create.
  const [checked, setChecked] = useState<{ ns: string; yaml: string; result: ValidateResult } | null>(null);
  const navigate = useNavigate();
  const validate = useValidate();
  const create = useCreate((name) => navigate(`/backend/cronjobs/${encodeURIComponent(name)}?namespace=${encodeURIComponent(namespace)}`));

  const fresh = checked && checked.ns === namespace && checked.yaml === yaml ? checked.result : null;
  const runValidate = () => validate.mutate({ namespace, yaml }, { onSuccess: (result) => setChecked({ ns: namespace, yaml, result }) });

  return (
    <div className="mx-auto max-w-4xl space-y-4 p-4 sm:p-6">
      <div className="flex flex-wrap items-center gap-3">
        <div>
          <h1 className="text-lg font-semibold text-zinc-900">New CronJob</h1>
          <p className="text-xs text-zinc-500">Paste the manifest. Before it is created it is checked for inline passwords and tokens, and every Secret / ConfigMap key it uses must exist.</p>
        </div>
        <select className={`${select} ml-auto`} value={namespace} onChange={(e) => setNamespace(e.target.value)} aria-label="Namespace">
          {namespaces.map((n) => <option key={n} value={n}>{n}</option>)}
        </select>
      </div>

      <Card className="p-0">
        <div className="flex items-center gap-2 border-b border-zinc-100 px-4 py-2 text-xs text-zinc-500"><FileCode className="h-4 w-4" />CronJob YAML</div>
        <textarea
          value={yaml}
          onChange={(e) => setYaml(e.target.value)}
          spellCheck={false}
          aria-label="CronJob YAML"
          className="block h-[420px] w-full resize-y rounded-b-xl bg-zinc-50 p-4 font-mono text-[13px] leading-relaxed text-zinc-900 focus:outline-none"
        />
      </Card>

      {fresh && (
        <div className="space-y-2">
          {fresh.valid && (
            <div className="flex items-center gap-2 rounded-lg border border-emerald-200 bg-emerald-50 px-3 py-2 text-sm text-emerald-800">
              <CheckCircle2 className="h-4 w-4" />{fresh.name} in “{namespace}” passed every check{fresh.schedule && <> · runs <span className="font-mono">{fresh.schedule}</span></>}.
            </div>
          )}
          <IssueList issues={fresh.issues} />
        </div>
      )}

      <div className="flex items-center justify-end gap-2">
        <Link to={`/backend/cronjobs?namespace=${encodeURIComponent(namespace)}`}><Button variant="secondary">Cancel</Button></Link>
        <Button variant="secondary" loading={validate.isPending} disabled={!yaml.trim() || !namespace} onClick={runValidate}><ShieldCheck className="h-4 w-4" />Validate</Button>
        <Button loading={create.isPending} disabled={!fresh?.valid} onClick={() => create.mutate({ namespace, yaml })}
          title={fresh?.valid ? undefined : 'Validate the manifest first'}>
          Create CronJob
        </Button>
      </div>
    </div>
  );
}
