"use server";

import { redirect } from "next/navigation";
import { isValidPassword, isValidPhone, phoneToInternalAuthEmail } from "@/lib/domain/identity";
import { createSupabaseServerClient } from "@/lib/supabase/server";

export type AuthActionState = {
  error: string | null;
};

function field(formData: FormData, name: string): string {
  const value = formData.get(name);
  return typeof value === "string" ? value : "";
}

export async function registerAction(_state: AuthActionState, formData: FormData): Promise<AuthActionState> {
  const displayName = field(formData, "displayName").trim();
  const phone = field(formData, "phone");
  const password = field(formData, "password");
  const confirmPassword = field(formData, "confirmPassword");

  if (!displayName || displayName.length > 160 || !isValidPhone(phone) || !isValidPassword(password) || password !== confirmPassword) {
    return { error: "تحقق من الاسم ورقم الهاتف وكلمة المرور وتأكيدها." };
  }

  const supabase = await createSupabaseServerClient();
  if (!supabase) return { error: "التسجيل غير متاح حتى تكتمل إعدادات خدمة الحسابات." };

  const { data, error } = await supabase.auth.signUp({
    email: phoneToInternalAuthEmail(phone),
    password,
    options: { data: { display_name: displayName, phone } },
  });

  if (error || !data.user) return { error: "تعذر إنشاء الحساب بهذه البيانات. تحقق منها وحاول مجددًا." };
  if (!data.session) {
    return { error: "يلزم إيقاف تأكيد البريد في إعداد Supabase لأن هذا التطبيق لا يستخدم البريد أو الرسائل للتسجيل." };
  }

  redirect("/customer/activation");
}

export async function loginAction(_state: AuthActionState, formData: FormData): Promise<AuthActionState> {
  const phone = field(formData, "phone");
  const password = field(formData, "password");
  if (!isValidPhone(phone) || !isValidPassword(password)) return { error: "رقم الهاتف أو كلمة المرور غير صحيحة." };

  const supabase = await createSupabaseServerClient();
  if (!supabase) return { error: "تسجيل الدخول غير متاح حتى تكتمل إعدادات خدمة الحسابات." };

  const { error } = await supabase.auth.signInWithPassword({ email: phoneToInternalAuthEmail(phone), password });
  if (error) return { error: "رقم الهاتف أو كلمة المرور غير صحيحة." };

  const { error: auditError } = await supabase.rpc("record_security_event", {
    p_event_type: "LOGIN_SUCCESS",
    p_trace_id: crypto.randomUUID(),
  });
  if (auditError) {
    await supabase.auth.signOut();
    return { error: "تعذر إتمام تسجيل الدخول بأمان. حاول مجددًا." };
  }

  redirect("/dashboard");
}

export async function logoutAction(): Promise<void> {
  const supabase = await createSupabaseServerClient();
  if (supabase) await supabase.auth.signOut();
  redirect("/");
}
