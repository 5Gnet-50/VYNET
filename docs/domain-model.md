# نموذج المجال

هذا نموذج مرشح في migrations غير مطبقة؛ لا توجد قاعدة بيانات أو بيانات فعلية.

- Organization تملك Networks وProducts وAgents وBatches وCards وTransfers وSales.
- User في `auth.users` و`profiles`، وصلاحياته ضمن المنظمة عبر `memberships`.
- Agent مرتبط بمستخدم ومنظمة. Customer/VY CARD يبقى نطاقًا منفصلًا؛ التسجيل العام وRPC تفعيل العميل معطلان في VYNET Stage 1.
- Product يتبع Network؛ سعر الوكيل في `agent_product_prices` لكل agent/network/product، ويُنسخ إلى transfer line والقيد المالي وقت التنفيذ.
- CardBatch يحتوي ImportRows؛ لا تنشأ Cards إلا عند الاعتماد.
- Card مستقل وله credential_type متعدد الأنواع، ciphertext/IV وHMAC fingerprint منفصل، ومحاور حيازة/عملية/حالة شبكة خارجية منفصلة.
- TransferRequest/Lines ثم Transfer/Lines/Items، FinancialEntry، Notification، InventoryMovement، AuditEvent، SecurityEvent، IdempotencyKey، ClaimToken، Device/Session وNotificationOutbox موصوفة في SQL.

Sale يحمل حقولًا اختيارية price/currency/payment_method/settlement_status/discount/reason_code لتوسعة مستقبلية؛ لا يوجد سلوك دفع أو تسوية. لا تعتبر نقل الحيازة ملكية قانونية. يجب ألا يُكشف credential في قوائم Cards.

توجد تهيئة إدارية لمرة واحدة لأول Organization وOWNER؛ لا توجد بعد آلية آمنة معتمدة لإنشاء حسابات ADMIN/AGENT من داخل النظام. العلاقات والقيود وRLS/RPC تحتاج تحقق PostgreSQL قبل التشغيل.
