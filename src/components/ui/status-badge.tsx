export function StatusBadge({ children }: { children: string }) {
  return (
    <span className="inline-flex min-h-7 items-center rounded-full border border-blue-300/20 bg-blue-300/10 px-3 text-xs font-medium text-blue-200">
      {children}
    </span>
  );
}
