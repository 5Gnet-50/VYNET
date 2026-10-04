import { PageFrame } from "@/components/layout/page-frame";
import { StatusBadge } from "@/components/ui/status-badge";
import { SurfaceCard } from "@/components/ui/surface-card";

type PlaceholderPageProps = {
  title: string;
  description: string;
  note?: string;
};

export function PlaceholderPage({ title, description, note }: PlaceholderPageProps) {
  return (
    <PageFrame>
      <div className="mb-6 flex flex-wrap items-center gap-3">
        <h1 className="text-2xl font-bold tracking-tight text-white sm:text-3xl">{title}</h1>
        <StatusBadge>قيد التجهيز</StatusBadge>
      </div>
      <SurfaceCard className="max-w-2xl p-6 sm:p-8">
        <p className="text-base leading-8 text-slate-200">{description}</p>
        {note ? <p className="mt-4 border-t border-white/10 pt-4 text-sm leading-7 text-slate-400">{note}</p> : null}
      </SurfaceCard>
    </PageFrame>
  );
}
