import type { Metadata, Viewport } from "next";
import "./globals.css";

export const metadata: Metadata = {
  title: "كارتي 5G",
  description: "منصة تأسيسية لإدارة بطاقات الإنترنت بين المالك والوكيل والعميل.",
  applicationName: "كارتي 5G",
  manifest: "/manifest.webmanifest",
  appleWebApp: { capable: true, title: "كارتي 5G", statusBarStyle: "black-translucent" },
};

export const viewport: Viewport = {
  themeColor: "#0b1220",
  width: "device-width",
  initialScale: 1,
};

export default function RootLayout({ children }: Readonly<{ children: React.ReactNode }>) {
  return (
    <html lang="ar" dir="rtl">
      <body>{children}</body>
    </html>
  );
}
