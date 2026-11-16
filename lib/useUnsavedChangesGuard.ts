"use client";

import { useCallback, useEffect, useRef, useState } from "react";
import { useRouter } from "next/navigation";

// Unsaved-changes navigation guard, shared by pages with editable state.
// Two parts, both only active while `dirty`:
//   - beforeunload: the browser asks before a tab close or reload.
//   - a capture-phase click listener on same-origin <a href> clicks:
//     the navigation is cancelled and the target stored in pendingNav so
//     the page can ask "Discard changes?" first. Modifier-clicks,
//     target=_blank, hash/mailto/external links, and links to the exact
//     current URL are left alone.
// confirmDiscard runs onDiscard (page cleanup) then router.push(target);
// cancelDiscard just clears pendingNav. Render whichever confirm UI the
// page prefers; never window.confirm.
export function useUnsavedChangesGuard({
  dirty,
  onDiscard,
}: {
  dirty: boolean;
  onDiscard?: () => void;
}) {
  const router = useRouter();
  const [pendingNav, setPendingNav] = useState<string | null>(null);
  const onDiscardRef = useRef(onDiscard);
  onDiscardRef.current = onDiscard;

  useEffect(() => {
    if (!dirty) return;
    const onBeforeUnload = (e: BeforeUnloadEvent) => {
      e.preventDefault();
    };
    window.addEventListener("beforeunload", onBeforeUnload);
    const onClick = (e: MouseEvent) => {
      if (
        e.defaultPrevented ||
        e.button !== 0 ||
        e.metaKey ||
        e.ctrlKey ||
        e.shiftKey ||
        e.altKey
      )
        return;
      const a = (e.target as HTMLElement).closest("a[href]");
      if (!a) return;
      // New-tab links never leave this page, so no prompt is needed.
      if ((a as HTMLAnchorElement).target === "_blank") return;
      const href = a.getAttribute("href");
      if (!href || href.startsWith("#") || href.startsWith("mailto:")) return;
      const url = new URL(href, window.location.href);
      if (url.origin !== window.location.origin) return;
      if (
        url.pathname === window.location.pathname &&
        url.search === window.location.search
      )
        return;
      e.preventDefault();
      e.stopPropagation();
      setPendingNav(url.pathname + url.search + url.hash);
    };
    document.addEventListener("click", onClick, true);
    return () => {
      window.removeEventListener("beforeunload", onBeforeUnload);
      document.removeEventListener("click", onClick, true);
    };
  }, [dirty]);

  const confirmDiscard = useCallback(() => {
    const href = pendingNav;
    setPendingNav(null);
    onDiscardRef.current?.();
    if (href) router.push(href);
  }, [pendingNav, router]);

  const cancelDiscard = useCallback(() => setPendingNav(null), []);

  return { pendingNav, confirmDiscard, cancelDiscard };
}
