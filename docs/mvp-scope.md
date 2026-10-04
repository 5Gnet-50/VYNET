# نطاق MVP والحالة

| المجال | الحالة | التفسير |
| --- | --- | --- |
| Next.js / TypeScript / RTL | DONE | أساس التطبيق موجود |
| Phone/password Auth | PARTIAL | Server Actions، لكن لا إعداد خدمة/اختبار جلسات |
| Organization/Roles/RLS | PARTIAL | Bootstrap إداري وقيود التسجيل العام موجودة بالمخطط؛ لم تطبق أو تختبر DB |
| Networks/Products | DEFERRED | لا CRUD حقيقي |
| CSV import | PARTIAL | Server Action محمية تتحقق وتشفّر وترسل RPC عبر service-role؛ غير متحققة على Supabase ولا توجد واجهة معاينة/اعتماد متكاملة |
| حماية credentials | PARTIAL | تشفير وفهرسة محليان؛ لا تخزين/reveal متصل |
| Inventory/Transfer/Sale/Delivery | PARTIAL | RPC مرشحة؛ انتهاء تحويل 24 ساعة وتسويته موجودان في SQL لكن غير مطبقين |
| Customer activation/cards | PARTIAL | الهيكل فقط، بلا DB أو UI تشغيلية |
| Audit/Security/Reports | PARTIAL | تصميم SQL فقط؛ فشل الدخول غير مسجل |
| Backup/restore/monitoring | BLOCKED | لا مزود مربوط أو خطة مزود معتمدة |
| Offline/Voice/Hotspot/Payments | DEFERRED | خارج نطاق MVP |

المشروع **ليس MVP يعمل فعليًا**. قبل الاختبار يلزم إعداد dev/test آمن وتطبيق migrations واختبارات تكامل RLS/RPC؛ وتهيئة Owner تحتاج مستخدم Auth موجودًا وUUID في بيئة الاختبار.
