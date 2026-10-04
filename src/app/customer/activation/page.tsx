import { PageFrame } from "@/components/layout/page-frame";
import { SurfaceCard } from "@/components/ui/surface-card";

export default function CustomerActivationPage() {
  return <PageFrame><section className="mx-auto max-w-xl py-8"><h1 className="mb-5 text-2xl font-bold text-white">تفعيل حساب العميل</h1><SurfaceCard><p className="leading-7 text-slate-300">التفعيل يتم لدى وكيل باستخدام رمز مؤقت. يلزم إعداد Supabase وربط حسابك قبل إصدار الرمز.</p></SurfaceCard></section></PageFrame>;
}
