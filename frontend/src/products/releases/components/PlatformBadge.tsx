import { Apple } from 'lucide-react';

const AndroidIcon = ({ className }: { className?: string }) => (
  <svg viewBox="0 0 24 24" fill="currentColor" className={className}>
    <path d="M17.6 9.48l1.84-3.18c.16-.31.04-.69-.27-.85a.637.637 0 00-.83.22l-1.88 3.24a11.463 11.463 0 00-8.92 0L5.66 5.67c-.19-.29-.58-.38-.87-.2-.28.18-.37.54-.19.83L6.4 9.48A10.78 10.78 0 003 16h18a10.78 10.78 0 00-3.4-6.52zM8.86 13a.98.98 0 110-1.96.98.98 0 010 1.96zm6.28 0a.98.98 0 110-1.96.98.98 0 010 1.96z"/>
  </svg>
);

/**
 * Platform chip for a release row: an Android / iOS icon badge for mobile, or a
 * plain text badge for a backend env. Shared by the releases list and the App
 * Release Monitor bulk panel so the two never drift.
 */
export const PlatformBadge = ({ platform, isMobile }: { platform: string; isMobile: boolean }) => {
  if (!isMobile) {
    return (
      <span className="rounded px-2 py-0.5 text-[10px] font-bold uppercase tracking-wide bg-sky-700 text-white">
        {platform}
      </span>
    );
  }
  if (platform === 'android') {
    return (
      <span className="inline-flex items-center gap-1 rounded px-2 py-0.5 text-[10px] font-bold uppercase tracking-wide bg-[#3DDC84]/15 text-[#1B8A4F] border border-[#3DDC84]/30">
        <AndroidIcon className="w-3 h-3" />
        Android
      </span>
    );
  }
  if (platform === 'ios') {
    return (
      <span className="inline-flex items-center gap-1 rounded px-2 py-0.5 text-[10px] font-bold uppercase tracking-wide bg-zinc-500/15 text-zinc-700 border border-zinc-400/30">
        <Apple className="w-3 h-3" />
        iOS
      </span>
    );
  }
  return (
    <span className="rounded px-2 py-0.5 text-[10px] font-bold uppercase tracking-wide bg-violet-600 text-white">
      {platform}
    </span>
  );
};
