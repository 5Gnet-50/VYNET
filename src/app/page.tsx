import { PageFrame } from "@/components/layout/page-frame";
import { RouteDirectory } from "@/components/route-directory";
import { SurfaceCard } from "@/components/ui/surface-card";
import Link from "next/link";

export default function Home() {
  return (
    <PageFrame>
      <section className="rounded-3xl border border-white/10 bg-gradient-to-bl from-blue-500/10 to-transparent p-6 sm:p-10" aria-labelledby="welcome-title">
        <p className="mt-8 text-sm font-medium text-blue-300">إدارة بطاقات الإنترنت ببساطة</p>
        <h1 id="welcome-title" className="mt-3 max-w-2xl text-3xl font-bold leading-tight tracking-tight text-white sm:text-5xl">
          منصة <span className="text-blue-300">كارتي 5G</span>
        </h1>
        <p className="mt-4 max-w-2xl text-base leading-8 text-slate-300">
          مساحة تأسيسية لمالك الشبكة والوكيل والعميل. الصفحات الحالية للتعريف بالبنية فقط، ولا تنفذ حسابات أو عمليات تشغيلية.
        </p>
        <Link href="/customer" className="mt-6 inline-flex min-h-12 items-center rounded-xl bg-blue-500 px-5 py-3 text-sm font-semibold text-white hover:bg-blue-400 focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-blue-300">
          استعراض مساحة العميل
        </Link>
      </section>

      <section className="mt-8 grid gap-3 sm:grid-cols-3" aria-label="الأدوار الرئيسية">
        {["المالك والإدارة", "الوكيل", "العميل"].map((role) => (
          <SurfaceCard key={role}>
            <h2 className="font-semibold text-white">{role}</h2>
            <p className="mt-2 text-sm leading-6 text-slate-400">واجهة مبدئية غير مرتبطة بحساب أو صلاحيات.</p>
          </SurfaceCard>
        ))}
      </section>

      <RouteDirectory />
    </PageFrame>
  );
}
