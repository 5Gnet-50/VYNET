import Link from "next/link";
import { Brand } from "@/components/brand";

export function SiteHeader() {
  return (
    <header className="border-b border-white/10">
      <div className="mx-auto flex w-full max-w-5xl items-center justify-between px-5 py-4 sm:px-8">
        <Link href="/" aria-label="كارتي 5G - الصفحة الرئيسية" className="rounded-lg focus-visible:outline-2 focus-visible:outline-offset-4 focus-visible:outline-blue-400">
          <Brand />
        </Link>
        <Link href="/login" className="min-h-11 rounded-xl px-4 py-2.5 text-sm font-medium text-slate-200 hover:bg-white/5 focus-visible:outline-2 focus-visible:outline-blue-400">
          تسجيل الدخول
        </Link>
      </div>
    </header>
  );
}
