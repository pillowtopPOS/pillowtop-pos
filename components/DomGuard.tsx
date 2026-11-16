"use client";

import { useEffect } from "react";

// Diagnostic + mitigation for the NotFoundError removeChild crash seen
// on /delivery/day in one browser: something outside React moves or
// replaces DOM nodes, so a parent React asks to remove a child from is
// no longer that child's parent. This patch makes removeChild a no-op
// (returning the child) instead of throwing when the parent does not
// match, and logs a capped set of readable warnings so we can see what
// is being moved. It patches Node.prototype.removeChild only, installs
// once per page load, and changes nothing else.

const MAX_WARNINGS = 10;
const FLAG = "__pillowtopDomGuardInstalled";

type GuardedWindow = Window & { [FLAG]?: boolean };

function describeNode(node: Node | null): string {
  if (!node) return "null";
  let detail = "";
  if (node instanceof Element) {
    detail = (node as Element).outerHTML.slice(0, 160);
  } else {
    detail = (node.textContent ?? "").slice(0, 160);
  }
  return `${node.nodeName} ${detail}`.trim();
}

export function installDomGuard(): void {
  if (typeof window === "undefined") return;
  const w = window as GuardedWindow;
  if (w[FLAG]) return;
  w[FLAG] = true;

  const original = Node.prototype.removeChild;
  let warnings = 0;

  Node.prototype.removeChild = function <T extends Node>(child: T): T {
    if (child.parentNode !== this) {
      if (warnings < MAX_WARNINGS) {
        warnings += 1;
        const actual = child.parentNode ? child.parentNode.nodeName : "null";
        console.warn(
          `DOM guard: removeChild skipped child=${describeNode(child)} ` +
            `parent=${this.nodeName} actualParent=${actual}`
        );
      }
      // React believes this child is being removed. Leaving it under its
      // real parent orphans a visible node (the stale select bug), so
      // remove it from wherever it actually lives instead of skipping.
      // Still never throws, which is why the guard exists.
      child.parentNode?.removeChild(child);
      return child;
    }
    return original.call(this, child) as T;
  };
}

// Install at module evaluation so the patch is in place before React
// hydrates and commits, not just after this component mounts.
installDomGuard();

export default function DomGuard() {
  useEffect(() => {
    installDomGuard();
  }, []);
  return null;
}
