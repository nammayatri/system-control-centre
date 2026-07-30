import { useState } from 'react';
import { Link, useNavigate, useParams } from 'react-router-dom';
import { ArrowLeft, Check, ChevronRight, File as FileIcon, Package2, Rocket } from 'lucide-react';
import { toast } from 'sonner';
import type { ComponentType } from 'react';
import { useCreateOtaPackage } from '../hooks';
import { OtaFileChooser } from '../components/OtaFileChooser';
import type { OtaSelectedFile } from '../types';
import { Button } from '../../../shared/ui/button';
import { Card, CardContent, CardHeader, CardTitle } from '../../../shared/ui/card';
import { Input } from '../../../shared/ui/input';
import { cn } from '../../../lib/utils';

const fieldDark = 'dark:bg-zinc-900 dark:border-zinc-700 dark:text-zinc-100';
const primaryBtnDark = 'bg-airborne border-airborne text-white hover:bg-airborne-hover';
const secondaryBtnDark = 'dark:bg-zinc-900 dark:border-zinc-700 dark:text-zinc-300 dark:hover:bg-zinc-800';
const cardDark = 'dark:bg-zinc-900 dark:border-zinc-800';

const STEPS: { number: 1 | 2; title: string; icon: ComponentType<{ className?: string }> }[] = [
  { number: 1, title: 'Package Details & Index File', icon: Package2 },
  { number: 2, title: 'Select Package Files', icon: FileIcon },
];

function Stepper({ current }: { current: 1 | 2 }) {
  return (
    <div className="flex items-center gap-2 sm:gap-4 flex-wrap">
      {STEPS.map((step, i) => {
        const status =
          step.number < current ? 'completed' : step.number === current ? 'current' : 'upcoming';
        const Icon = step.icon;
        return (
          <div key={step.number} className="flex items-center">
            <div className="flex items-center gap-3">
              <div
                className={cn(
                  'flex items-center justify-center w-10 h-10 rounded-full border-2 transition-colors shrink-0',
                  status === 'completed' && 'bg-airborne border-airborne text-white',
                  status === 'current' && 'border-airborne text-airborne bg-airborne/10',
                  status === 'upcoming' &&
                    'border-zinc-300 text-zinc-400 dark:border-zinc-700 dark:text-zinc-500',
                )}
              >
                {status === 'completed' ? <Check className="w-5 h-5" /> : <Icon className="w-5 h-5" />}
              </div>
              <div className="hidden sm:block">
                <div
                  className={cn(
                    'font-medium text-sm',
                    status === 'upcoming'
                      ? 'text-zinc-400 dark:text-zinc-500'
                      : 'text-zinc-900 dark:text-zinc-100',
                  )}
                >
                  {step.title}
                </div>
                <div className="text-xs text-zinc-500 dark:text-zinc-400">Step {step.number}</div>
              </div>
            </div>
            {i < STEPS.length - 1 && (
              <ChevronRight className="w-4 h-4 text-zinc-400 dark:text-zinc-500 mx-2 sm:mx-4" />
            )}
          </div>
        );
      })}
    </div>
  );
}

export default function PackageCreate() {
  const { app } = useParams<{ app: string }>();
  const navigate = useNavigate();

  const createMutation = useCreateOtaPackage(app);

  const [step, setStep] = useState<1 | 2>(1);
  const [index, setIndex] = useState<OtaSelectedFile[]>([]);
  const [files, setFiles] = useState<OtaSelectedFile[]>([]);
  const [tag, setTag] = useState('');

  // Create APIs take the "<path>@version:<n>" key, not the (path, version) pair.
  const keyOf = (f: OtaSelectedFile) => `${f.file_path}@version:${f.version}`;
  const indexFile = index[0] ?? null;

  const backPath = `/airborne/${encodeURIComponent(app!)}/packages`;

  const submit = () => {
    if (!indexFile) {
      toast.error('Select an index file for the package');
      return;
    }
    createMutation.mutate(
      {
        index: keyOf(indexFile),
        // Airborne's own create page filters the index out of the file list.
        files: files.filter((f) => f.file_path !== indexFile.file_path).map(keyOf),
        ...(tag.trim() ? { tag: tag.trim() } : {}),
      },
      { onSuccess: () => navigate(backPath) },
    );
  };

  return (
    <div className="flex flex-col flex-1 w-full pb-12 space-y-6">
      {/* Header + stepper */}
      <div className="flex items-start gap-3 min-w-0">
        <Link
          to={backPath}
          className="w-9 h-9 mt-1 rounded-lg border border-zinc-200 bg-white text-zinc-500 hover:text-zinc-800 hover:bg-zinc-50 dark:border-zinc-800 dark:bg-zinc-900 dark:text-zinc-400 dark:hover:text-zinc-100 dark:hover:bg-zinc-800 flex items-center justify-center shrink-0"
          aria-label="Back to packages"
        >
          <ArrowLeft className="w-4 h-4" />
        </Link>
        <div className="flex-1 min-w-0">
          <h1 className="text-xl sm:text-2xl font-bold text-zinc-900 dark:text-zinc-100">
            Create Package Version
          </h1>
          <p className="text-sm text-zinc-500 dark:text-zinc-400 mt-1">
            Bundle files together with properties and metadata
          </p>
          <div className="mt-6">
            <Stepper current={step} />
          </div>
        </div>
      </div>

      {/* Step 1 — details + index */}
      {step === 1 && (
        <div className="space-y-4">
          <Card className={cardDark}>
            <CardHeader className="dark:border-zinc-800">
              <CardTitle className="dark:text-zinc-100">Package Details</CardTitle>
              <p className="text-sm text-zinc-500 dark:text-zinc-400 mt-0.5">
                Basic information about your package
              </p>
            </CardHeader>
            <CardContent>
              <div className="max-w-sm">
                <Input
                  label="Tag"
                  value={tag}
                  onChange={(e) => setTag(e.target.value)}
                  placeholder="e.g., latest, v1.0, production"
                  className={fieldDark}
                />
              </div>
            </CardContent>
          </Card>

          <Card className={cardDark}>
            <CardHeader className="dark:border-zinc-800">
              <CardTitle className="dark:text-zinc-100">Select Index File</CardTitle>
              <p className="text-sm text-zinc-500 dark:text-zinc-400 mt-0.5">
                Choose the main entry point file for your package
              </p>
            </CardHeader>
            <CardContent>
              <OtaFileChooser app={app!} mode="single" value={index} onChange={setIndex} />
            </CardContent>
          </Card>
        </div>
      )}

      {/* Step 2 — bundled files */}
      {step === 2 && (
        <Card className={cardDark}>
          <CardHeader className="dark:border-zinc-800">
            <CardTitle className="dark:text-zinc-100">Select Package Files</CardTitle>
            <p className="text-sm text-zinc-500 dark:text-zinc-400 mt-0.5">
              Choose additional files to include in this package
            </p>
          </CardHeader>
          <CardContent className="space-y-2">
            <OtaFileChooser
              app={app!}
              mode="multi"
              value={files}
              onChange={setFiles}
              excludePaths={indexFile ? [indexFile.file_path] : undefined}
            />
          </CardContent>
        </Card>
      )}

      {/* Actions — airborne layout: Cancel/Previous left, Next Step / Create right */}
      <div className="flex items-center justify-between gap-2">
        <div className="flex items-center gap-2">
          <Button variant="secondary" className={secondaryBtnDark} onClick={() => navigate(backPath)}>
            Cancel
          </Button>
          {step > 1 && (
            <Button variant="secondary" className={secondaryBtnDark} onClick={() => setStep(1)}>
              Previous
            </Button>
          )}
        </div>
        {step === 1 ? (
          <Button
            variant="primary"
            className={primaryBtnDark}
            disabled={!indexFile}
            onClick={() => setStep(2)}
          >
            Next Step
          </Button>
        ) : (
          <Button
            variant="primary"
            className={primaryBtnDark}
            disabled={!indexFile || createMutation.isPending}
            loading={createMutation.isPending}
            onClick={submit}
          >
            <Rocket className="w-4 h-4" />
            Create Package
          </Button>
        )}
      </div>
    </div>
  );
}
