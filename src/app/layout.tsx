import type { Metadata, Viewport } from "next";
import "./globals.css";

export const metadata: Metadata = {
  title: "VYNET | فاينت",
  description: "منصة إدارة البطاقات والشبكات والتحويلات للمالك والوكيل.",
  applicationName: "VYNET",
  manifest: "/manifest.webmanifest",
  appleWebApp: { capable: true, title: "VYNET", statusBarStyle: "black-translucent" },
};

export const viewport: Viewport = {
  themeColor: "#0B0620",
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
