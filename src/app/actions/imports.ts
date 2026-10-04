"use server";

import { parseCardCsv } from "@/lib/imports/csv";
import { encryptCardCredential } from "@/lib/security/card-credentials";
import { createSupabaseAdminClient } from "@/lib/supabase/admin";
import { createSupabaseServerClient } from "@/lib/supabase/server";

export type ImportActionState = { error: string | null; result: unknown | null };

function field(formData: FormData, name: string): string {
  const value = formData.get(name);
  return typeof value === "string" ? value : "";
}

export async function createCardBatchAction(_state: ImportActionState, formData: FormData): Promise<ImportActionState> {
  const organizationId = field(formData, "organizationId");
  const networkId = field(formData, "networkId");
  const productId = field(formData, "productId");
  const file = formData.get("file");
  if (!organizationId || !networkId || !productId || !(file instanceof File) || file.size === 0 || file.size > 5_000_000
    || !file.name.toLowerCase().endsWith(".csv")) {
    return { error: "بيانات ملف الاستيراد غير صالحة أو يتجاوز الحد المسموح.", result: null };
  }

  const supabase = await createSupabaseServerClient();
  if (!supabase) return { error: "خدمة الحسابات غير مهيأة.", result: null };
  const { data: { user }, error: authError } = await supabase.auth.getUser();
  if (authError || !user) return { error: "يجب تسجيل الدخول أولاً.", result: null };
  const { data: membership, error: membershipError } = await supabase
    .from("memberships").select("role").eq("organization_id", organizationId).eq("user_id", user.id).maybeSingle();
  if (membershipError || !membership || !["OWNER", "ADMIN"].includes(membership.role)) {
    return { error: "ليست لديك صلاحية استيراد البطاقات لهذه المنظمة.", result: null };
  }

  const admin = createSupabaseAdminClient();
  if (!admin) return { error: "مسار الاستيراد الآمن غير مهيأ في بيئة الخادم.", result: null };

  try {
    const csv = await file.text();
    const fingerprintKey = process.env.CARD_FINGERPRINT_KEY;
    const encryptionKey = process.env.CARD_ENCRYPTION_KEY;
    const parsed = parseCardCsv(csv, fingerprintKey, organizationId);
    const rows = parsed.map((row) => {
      if (!row.credential || row.status === "DUPLICATE_IN_FILE") {
        return { row_number: row.rowNumber, status: row.status, error_code: row.reasonCode };
      }
      const encrypted = encryptCardCredential(row.credential, encryptionKey, fingerprintKey, organizationId);
      return {
        row_number: row.rowNumber,
        status: row.status,
        error_code: row.reasonCode,
        credential_type: row.credential.kind,
        ciphertext_hex: encrypted.ciphertextHex,
        iv_hex: encrypted.ivHex,
        fingerprint_hex: encrypted.fingerprintHex,
      };
    });
    const { data, error } = await admin.rpc("create_card_batch", {
      p_organization_id: organizationId,
      p_network_id: networkId,
      p_product_id: productId,
      p_source_filename: file.name.replace(/[\r\n\0]/g, "_").slice(0, 255) || "cards.csv",
      p_rows: rows,
      p_trace_id: crypto.randomUUID(),
      p_actor_user_id: user.id,
    });
    if (error) return { error: "تعذر حفظ دفعة الاستيراد. راجع الملف والصلاحيات.", result: null };
    return { error: null, result: data };
  } catch (error) {
    const message = error instanceof Error ? error.message : "";
    const safeMessage = ["MISSING_CARD_FINGERPRINT_KEY", "INVALID_CARD_FINGERPRINT_KEY", "MISSING_CARD_ENCRYPTION_KEY", "INVALID_CARD_ENCRYPTION_KEY"].includes(message)
      ? "إعداد مفاتيح تشفير البطاقات غير مكتمل على الخادم."
      : "تعذر تحليل ملف الاستيراد بأمان.";
    return { error: safeMessage, result: null };
  }
}
