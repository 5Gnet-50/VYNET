"use client";

import { useActionState } from "react";
import type { AuthActionState } from "@/app/actions/auth";
import { SurfaceCard } from "@/components/ui/surface-card";

type AuthFormProps = {
  mode: "login" | "register";
  action: (state: AuthActionState, formData: FormData) => Promise<AuthActionState>;
};

export function AuthForm({ mode, action }: AuthFormProps) {
  const [state, formAction, pending] = useActionState(action, { error: null });
  const register = mode === "register";

  return (
    <SurfaceCard className="w-full max-w-lg p-5 sm:p-8">
      <form action={formAction} className="space-y-5">
        {register ? (
          <div>
            <label htmlFor="displayName" className="mb-2 block text-sm font-medium text-slate-200">الاسم</label>
            <input id="displayName" name="displayName" autoComplete="name" required maxLength={160} className="min-h-12 w-full rounded-xl border border-white/10 bg-slate-950 px-4 text-white outline-none focus:border-blue-400" />
          </div>
        ) : null}
        <div>
          <label htmlFor="phone" className="mb-2 block text-sm font-medium text-slate-200">رقم الهاتف</label>
          <input id="phone" name="phone" type="tel" inputMode="numeric" autoComplete="tel-national" pattern="7[0-9]{8}" minLength={9} maxLength={9} required className="min-h-12 w-full rounded-xl border border-white/10 bg-slate-950 px-4 text-left text-white outline-none focus:border-blue-400" dir="ltr" aria-describedby="phone-hint" />
          <p id="phone-hint" className="mt-2 text-xs text-slate-400">9 أرقام، تبدأ بالرقم 7.</p>
        </div>
        <div>
          <label htmlFor="password" className="mb-2 block text-sm font-medium text-slate-200">كلمة المرور</label>
          <input id="password" name="password" type="password" autoComplete={register ? "new-password" : "current-password"} minLength={6} required className="min-h-12 w-full rounded-xl border border-white/10 bg-slate-950 px-4 text-white outline-none focus:border-blue-400" />
        </div>
        {register ? (
          <div>
            <label htmlFor="confirmPassword" className="mb-2 block text-sm font-medium text-slate-200">تأكيد كلمة المرور</label>
            <input id="confirmPassword" name="confirmPassword" type="password" autoComplete="new-password" minLength={6} required className="min-h-12 w-full rounded-xl border border-white/10 bg-slate-950 px-4 text-white outline-none focus:border-blue-400" />
          </div>
        ) : null}
        {state.error ? <p role="alert" className="rounded-xl border border-rose-400/20 bg-rose-400/10 p-3 text-sm leading-6 text-rose-200">{state.error}</p> : null}
        <button type="submit" disabled={pending} className="min-h-12 w-full rounded-xl bg-blue-500 px-5 py-3 font-semibold text-white hover:bg-blue-400 disabled:cursor-wait disabled:opacity-60">
          {pending ? "جارٍ الإرسال…" : register ? "إنشاء الحساب" : "تسجيل الدخول"}
        </button>
      </form>
    </SurfaceCard>
  );
}
