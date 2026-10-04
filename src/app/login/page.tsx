import { AuthForm } from "@/components/auth/auth-form";
import { loginAction } from "@/app/actions/auth";
import { PageFrame } from "@/components/layout/page-frame";

export default function LoginPage() {
  return (
    <PageFrame><section className="mx-auto max-w-lg py-10"><h1 className="mb-6 text-2xl font-bold text-white">تسجيل الدخول</h1><AuthForm mode="login" action={loginAction} /></section></PageFrame>
  );
}
