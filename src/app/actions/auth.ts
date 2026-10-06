"use server";

import { redirect } from "next/navigation";
import { resolveVynetExperience } from "@/lib/domain/authorization";
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
  void _state;
  void formData;
  return { error: "إنشاء حسابات VYNET يتم إداريًا فقط. تواصل مع مسؤول النظام للحصول على حساب." };
}

export async function loginAction(_state: AuthActionState, formData: FormData): Promise<AuthActionState> {
  const phone = field(formData, "phone");
  const password = field(formData, "password");
  if (!isValidPhone(phone) || !isValidPassword(password)) return { error: "رقم الهاتف أو كلمة المرور غير صحيحة." };

  const supabase = await createSupabaseServerClient();
  if (!supabase) return { error: "تسجيل الدخول غير متاح حتى تكتمل إعدادات خدمة الحسابات." };

  const { data: signIn, error } = await supabase.auth.signInWithPassword({ email: phoneToInternalAuthEmail(phone), password });
  if (error) return { error: "رقم الهاتف أو كلمة المرور غير صحيحة." };

  const { data: memberships, error: membershipError } = await supabase
    .from("memberships").select("role").eq("user_id", signIn.user.id);
  const experience = membershipError || !memberships
    ? "UNAUTHORIZED"
    : resolveVynetExperience(memberships.map(({ role }) => role));
  if (experience === "UNAUTHORIZED" || experience === "AMBIGUOUS") {
    await supabase.auth.signOut();
    return { error: "لا توجد صلاحية VYNET واضحة لهذا الحساب. تواصل مع مسؤول النظام." };
  }

  const { error: auditError } = await supabase.rpc("record_security_event", {
    p_event_type: "LOGIN_SUCCESS",
    p_trace_id: crypto.randomUUID(),
  });
  if (auditError) {
    await supabase.auth.signOut();
    return { error: "تعذر إتمام تسجيل الدخول بأمان. حاول مجددًا." };
  }

  redirect(experience === "OWNER_ADMIN" ? "/admin" : "/agent");
}

export async function logoutAction(): Promise<void> {
  const supabase = await createSupabaseServerClient();
  if (supabase) await supabase.auth.signOut();
  redirect("/");
}
