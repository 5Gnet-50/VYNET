import type { ReactNode } from "react";
import { SiteHeader } from "@/components/layout/site-header";

export function PageFrame({ children }: { children: ReactNode }) {
  return (
    <div className="flex min-h-screen flex-col">
      <SiteHeader />
      <main className="mx-auto flex w-full max-w-5xl flex-1 flex-col px-5 py-8 sm:px-8 sm:py-12">
        {children}
      </main>
      <footer className="mx-auto w-full max-w-5xl px-5 pb-6 text-xs text-slate-500 sm:px-8">
        كارتي 5G · نموذج تأسيسي غير متصل بخدمات تشغيلية
      </footer>
    </div>
  );
}
