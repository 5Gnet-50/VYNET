import Link from "next/link";
import { routeGroups } from "@/config/routes";
import { SurfaceCard } from "@/components/ui/surface-card";

export function RouteDirectory() {
  return (
    <div className="mt-12 space-y-8">
      {routeGroups.map((group) => (
        <section key={group.title} aria-labelledby={`routes-${group.title}`}>
          <h2 id={`routes-${group.title}`} className="mb-4 text-lg font-semibold text-white">{group.title}</h2>
          <ul className="grid gap-3 sm:grid-cols-2 lg:grid-cols-3">
            {group.links.map((route) => (
              <li key={route.href}>
                <Link href={route.href} className="block h-full rounded-2xl focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-blue-400">
                  <SurfaceCard className="h-full transition-colors hover:border-blue-300/30">
                    <span className="text-xs text-blue-300">{route.audience}</span>
                    <h3 className="mt-2 font-semibold text-white">{route.title}</h3>
                    <p className="mt-1 text-sm leading-6 text-slate-400">{route.description}</p>
                  </SurfaceCard>
                </Link>
              </li>
            ))}
          </ul>
        </section>
      ))}
    </div>
  );
}
