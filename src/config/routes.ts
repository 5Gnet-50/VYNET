export type RouteLink = {
  href: string;
  title: string;
  description: string;
  audience: string;
};

export const routeGroups = [
  {
    title: "الحساب",
    links: [
      { href: "/login", title: "تسجيل الدخول", description: "واجهة أولية للدخول", audience: "عام" },
      { href: "/register", title: "إنشاء حساب", description: "واجهة أولية لإنشاء الحساب", audience: "عام" },
    ],
  },
  {
    title: "المساحات",
    links: [
      { href: "/dashboard", title: "لوحة التحكم", description: "نقطة دخول أولية حسب الدور", audience: "عام" },
      { href: "/admin", title: "الإدارة", description: "مساحة إدارة أولية", audience: "المالك والإدارة" },
      { href: "/agent", title: "الوكيل", description: "مساحة الوكيل الأولية", audience: "الوكيل" },
      { href: "/customer", title: "العميل", description: "واجهة العميل الأولية", audience: "العميل" },
      { href: "/customer/cards", title: "كروتي", description: "مكان عرض بطاقات العميل مستقبلًا", audience: "العميل" },
    ],
  },
  {
    title: "وحدات العمل",
    links: [
      { href: "/inventory", title: "المخزون", description: "هيكل أولي للمخزون", audience: "المالك والإدارة" },
      { href: "/imports", title: "استيراد البطاقات", description: "هيكل أولي لمسار الاستيراد", audience: "المالك والإدارة" },
      { href: "/transfers", title: "التحويلات", description: "هيكل أولي للتحويلات", audience: "المالك والوكيل" },
      { href: "/sales", title: "المبيعات", description: "هيكل أولي للمبيعات", audience: "الوكيل" },
    ],
  },
] satisfies { title: string; links: RouteLink[] }[];
