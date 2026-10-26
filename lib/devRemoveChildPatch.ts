// TEMP: removeChild logging (dev only) — cleanup-2 crash investigation.
// Patches Node.prototype.removeChild so a failing call records the child,
// the expected parent, the child's real parent, and a stack — to
// console.error and sessionStorage["removeChildLog"] (survives the error
// overlay reload long enough to copy out). No-op in production.

if (typeof window !== "undefined" && process.env.NODE_ENV === "development") {
  const originalRemoveChild = Node.prototype.removeChild;

  Node.prototype.removeChild = function patchedRemoveChild<T extends Node>(
    child: T
  ): T {
    try {
      return originalRemoveChild.call(this, child) as T;
    } catch (err) {
      const describe = (node: Node | null): string => {
        if (node == null) return "null";
        if (node instanceof Element) {
          return `<${node.tagName.toLowerCase()}> ${node.outerHTML.slice(0, 300)}`;
        }
        return `${node.nodeName} "${String(node.textContent).slice(0, 120)}"`;
      };
      const entry = {
        at: new Date().toISOString(),
        child: describe(child),
        expectedParent: describe(this as Node),
        realParent: describe(child.parentNode),
        stack: new Error().stack,
      };
      try {
        console.error("removeChild failed", entry);
        const prev = sessionStorage.getItem("removeChildLog");
        sessionStorage.setItem(
          "removeChildLog",
          (prev ?? "") + "\n" + JSON.stringify(entry)
        );
      } catch {
        // sessionStorage unavailable/full — the console copy stands.
      }
      throw err;
    }
  };
}

export {};
