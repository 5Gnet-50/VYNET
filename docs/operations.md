# التشغيل والاستعادة

## تطوير محلي

استخدم Node.js >=20.9 وpnpm 11.19.0. انسخ `.env.example` إلى `.env.local` بعد توفير مشروع Supabase تطوير/اختبار، وأدخل القيم من مدير أسرار محلي. لا تستخدم Production. عطّل تأكيد البريد للمشروع حسب قرار mapping الداخلي. مفتاح service-role ومفتاحا تشفير البطاقة خادمية فقط. طبّق migrations واختبرها على قاعدة اختبار قبل تشغيل التطبيق.

### تهيئة أول Owner

1. أنشئ مستخدم Auth بآلية إدارية معتمدة في بيئة الاختبار. استخدم البريد الداخلي المشتق `phone@vynet.app` وبيانات metadata `phone` و`display_name` المطابقة، دون تضمين بيانات اعتماد في source. تسجيل VYNET العام معطل.
2. بعد trigger إنشاء `profiles`, استخرج UUID من لوحة Supabase المصرح بها.
3. مرر `NEXT_PUBLIC_SUPABASE_URL`, `SUPABASE_SERVICE_ROLE_KEY`, `BOOTSTRAP_OWNER_USER_ID`, و`BOOTSTRAP_ORGANIZATION_NAME` إلى بيئة shell موثوقة ثم نفّذ `pnpm bootstrap:owner` مرة واحدة. السكربت لا ينشئ Auth user؛ يستدعي RPC التي تتحقق من وجود profile وتمنع تكرار bootstrap بقفل transaction.
4. لا تنفذ bootstrap من التسجيل العام أو من متصفح التطبيق. لا تضع service-role key في `NEXT_PUBLIC_*` ولا تُسجل بيانات دخول في تقارير عامة.

### انتهاء التحويل

Owner/Admin يستدعي `public.expire_owner_agent_transfers(organization_id, limit, trace_id)` عند الحاجة، بحد أقصى 100 تحويل في الاستدعاء. الدالة تقفل التحويلات والبطاقات، ترفض mismatch ذريًا، وتعيد تشغيلها آمن لأن الحالة لم تعد `PENDING_ACCEPTANCE`. لم يُضف scheduler.

نفذ:

```bash
pnpm install --frozen-lockfile
pnpm lint
pnpm typecheck
pnpm test
pnpm build
```

## Backup / Restore

لا يوجد مزود نسخ احتياطي أو سياسة retention أو monitoring متصل. لا تدّع وجود نسخ. قبل بيانات حقيقية، حدد RPO/RTO، اختبر الاستعادة دوريًا، واحفظ مفاتيح التشفير في مخزن مستقل وآمن.

## الفشل والعمليات المجهولة

استعلم بمفتاح العملية نفسه بعد فقد الرد؛ لا تنشئ عملية بمفتاح جديد. لا تعاود بيع/تحويل بطاقة قبل reconciliation مع قاعدة البيانات والـledger. لا ترسل أسرار البطاقات في سجلات أو تذاكر. هذه إرشادات تصميمية؛ لا توجد Jobs أو reconciliation تلقائية منشورة.
