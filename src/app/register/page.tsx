import { AuthForm } from "@/components/auth/auth-form";
import { registerAction } from "@/app/actions/auth";
import { PageFrame } from "@/components/layout/page-frame";

export default function RegisterPage() {
  return (
    <PageFrame><section className="mx-auto max-w-lg py-10"><h1 className="mb-6 text-2xl font-bold text-white">إنشاء حساب</h1><AuthForm mode="register" action={registerAction} /></section></PageFrame>
  );
}
