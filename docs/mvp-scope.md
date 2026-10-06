# نطاق MVP والحالة

| المجال | الحالة | التفسير |
| --- | --- | --- |
| Next.js / TypeScript / RTL | DONE | أساس التطبيق موجود |
| Phone/password Auth | PARTIAL | الدخول يستخدم mapping `phone@vynet.app`؛ التسجيل العام معطل، وتهيئة المستخدمين إدارية؛ migration توافق النطاق لم تختبر |
| Organization/Roles/RLS | PARTIAL | Bootstrap إداري، حراسة لمساحتي Owner/Admin وAgent، ومخططات RLS؛ لم تطبق أو تختبر DB |
| Networks/Products | DEFERRED | لا CRUD حقيقي |
| CSV import | PARTIAL | Server Action محمية تتحقق وتشفّر وترسل RPC عبر service-role؛ غير متحققة على Supabase ولا توجد واجهة معاينة/اعتماد متكاملة |
| حماية credentials | PARTIAL | تشفير وفهرسة محليان؛ لا تخزين/reveal متصل |
| Inventory/Transfer/Sale/Delivery | PARTIAL | RPC طلب/مراجعة/تنفيذ/قبول التحويل وحركات الحجز والاستلام مضافة كمخطط؛ لم تختبر على PostgreSQL ولا توجد واجهات تشغيل متكاملة |
| Pricing / financial ledger / notifications | PARTIAL | سعر لكل وكيل وشبكة ومنتج مع snapshots وعكس عند انتهاء التحويل؛ تهيئة الأسعار والتقارير المالية غير متاحة بواجهة |
| VY CARD customer flow | DEFERRED | جداول مستقبلية باقية، لكن التسجيل العام وRPC تفعيل العميل معطلان ضمن VYNET Stage 1 |
| Audit/Security/Reports | PARTIAL | تصميم SQL فقط؛ فشل الدخول غير مسجل |
| Backup/restore/monitoring | BLOCKED | لا مزود مربوط أو خطة مزود معتمدة |
| Offline/Voice/Hotspot/Payments | DEFERRED | خارج نطاق MVP |

المشروع **ليس MVP يعمل فعليًا**. migrations Stage 1 غير مطبقة أو متحققة. قبل التشغيل يلزم توفير بيئة dev/test، آلية إدارية آمنة لإنشاء الوكلاء والمديرين، واجهات تشغيل الأسعار والتحويل، ثم اختبارات SQL/RLS/RPC فعلية؛ وتهيئة Owner تحتاج مستخدم Auth موجودًا وUUID في بيئة الاختبار.
