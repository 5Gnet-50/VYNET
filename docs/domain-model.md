# نموذج المجال

هذا نموذج مرشح في migrations غير مطبقة؛ لا توجد قاعدة بيانات أو بيانات فعلية.

- Organization تملك Networks وProducts وAgents وBatches وCards وTransfers وSales.
- User في `auth.users` و`profiles`، وصلاحياته ضمن المنظمة عبر `memberships`.
- Agent مرتبط بمستخدم ومنظمة. Customer يبدأ INACTIVE ثم ينشط برمز مؤقت.
- Product يتبع Network ويحوي value وprice اختياريين.
- CardBatch يحتوي ImportRows؛ لا تنشأ Cards إلا عند الاعتماد.
- Card مستقل وله credential_type متعدد الأنواع، ciphertext/IV وHMAC fingerprint منفصل، ومحاور حيازة/عملية/حالة شبكة خارجية منفصلة.
- Transfer/TransferItem، Sale/SaleItem/Delivery، InventoryMovement، AuditEvent، SecurityEvent، IdempotencyKey، ClaimToken، Device/Session وNotificationOutbox موصوفة في SQL.

Sale يحمل حقولًا اختيارية price/currency/payment_method/settlement_status/discount/reason_code لتوسعة مستقبلية؛ لا يوجد سلوك دفع أو تسوية. لا تعتبر نقل الحيازة ملكية قانونية. يجب ألا يُكشف credential في قوائم Cards.

توجد فجوة تمنع التهيئة: لا مسار آمن معتمد لإنشاء أول Organization وOWNER. العلاقات والقيود وRLS تحتاج تحقق Postgres قبل التشغيل.
