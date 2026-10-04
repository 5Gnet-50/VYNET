import type { HTMLAttributes } from "react";

type SurfaceCardProps = HTMLAttributes<HTMLDivElement>;

export function SurfaceCard({ className = "", ...props }: SurfaceCardProps) {
  return (
    <div
      className={`rounded-2xl border border-white/10 bg-slate-900/70 p-5 ${className}`}
      {...props}
    />
  );
}
