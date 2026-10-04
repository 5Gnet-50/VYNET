type NetworkCardProps = { name: string; index: number };

export function NetworkCard({ name, index }: NetworkCardProps) {
  return (
    <article className="flex min-h-24 items-center gap-4 rounded-2xl border border-white/10 bg-slate-900/70 p-4">
      <span className="flex size-11 shrink-0 items-center justify-center rounded-xl bg-blue-400/10 text-sm font-semibold text-blue-300" aria-hidden="true">
        {String(index).padStart(2, "0")}
      </span>
      <h3 className="text-base font-semibold text-slate-100">{name}</h3>
    </article>
  );
}
