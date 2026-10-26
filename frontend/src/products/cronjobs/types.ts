export interface Issue {
  severity: 'error' | 'warning';
  code: string;
  path: string;
  message: string;
}

export interface CronJobSummary {
  name: string;
  schedule: string;
  timeZone: string | null;
  suspend: boolean;
  concurrencyPolicy: string | null;
  lastScheduleTime: string | null;
  lastSuccessfulTime: string | null;
  active: number;
  images: string[];
  createdAt: string;
}

/** One env entry as stored in the pod spec. A credential-looking inline value comes back `masked` without its `value`. */
export interface EnvEntry {
  name: string;
  value?: string;
  masked?: boolean;
  valueFrom?: {
    secretKeyRef?: { name: string; key: string; optional?: boolean };
    configMapKeyRef?: { name: string; key: string; optional?: boolean };
    fieldRef?: { fieldPath: string };
    resourceFieldRef?: { resource: string };
  };
}

export interface ContainerDetail {
  name: string;
  image: string;
  command: string[] | null;
  args: string[] | null;
  env: EnvEntry[];
  envFrom: { kind: 'Secret' | 'ConfigMap'; name: string }[];
}

export interface CronJobDetail {
  summary: CronJobSummary;
  resourceVersion: string;
  startingDeadlineSeconds: number | null;
  successfulJobsHistoryLimit: number | null;
  failedJobsHistoryLimit: number | null;
  activeJobs: string[];
  containers: ContainerDetail[];
}

export interface ValidateResult {
  valid: boolean;
  issues: Issue[];
  name: string | null;
  schedule: string | null;
}

export interface CreateResult {
  name: string;
  namespace: string;
  warnings: Issue[];
}

export interface EnvChange {
  container?: string;
  set?: Pick<EnvEntry, 'name' | 'value' | 'valueFrom'>[];
  remove?: string[];
}
