import { PageFrame } from "@/components/layout/page-frame";
import { NetworkCard } from "@/components/network-card";

const networks = ["5G-NET", "العالم نت", "توفير نت"] as const;

export default function CustomerPage() {
  return (
    <PageFrame>
      <div>
        <p className="text-sm font-medium text-blue-300">VY CARD · تطبيق مستقل</p>
        <h1 className="mt-2 text-3xl font-bold text-white">مرحبًا بك في VY CARD</h1>
        <p className="mt-3 max-w-2xl text-base leading-7 text-slate-300">
          هذه الصفحة قيد التجهيز. أسماء الشبكات أدناه للعرض فقط وليست حالة توفر مباشرة.
        </p>
      </div>
      <section className="mt-8" aria-labelledby="customer-networks-title">
        <h2 id="customer-networks-title" className="mb-4 text-lg font-semibold text-white">الشبكات</h2>
        <ul className="grid gap-3 sm:grid-cols-2 lg:grid-cols-3">
          {networks.map((network, index) => (
            <li key={network}><NetworkCard name={network} index={index + 1} /></li>
          ))}
        </ul>
      </section>
    </PageFrame>
  );
}
