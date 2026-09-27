"use client";

import { useEffect, useRef, type ReactNode } from "react";

// Shared overlay for every pop-up. Handles:
//   - click on the dimmed area closes (only when the press both starts
//     AND ends on the backdrop — dragging a text selection out of a
//     form does not close it)
//   - Escape closes
//   - only the topmost layer responds, so a modal over the journey
//     detail panel closes alone
//   - `dirty` asks "Discard changes?" first; `saving` blocks closing
//     entirely while a save is in flight.
// Keep existing Cancel / X buttons unchanged — they call the same
// onClose but bypass the confirm.

const layerStack: symbol[] = [];

export default function Modal({
  onClose,
  dirty = false,
  saving = false,
  children,
  overlayClassName = "fixed inset-0 z-50 flex items-center justify-center bg-slate-900/50 p-4",
}: {
  onClose: () => void;
  dirty?: boolean;
  saving?: boolean;
  children: ReactNode;
  overlayClassName?: string;
}) {
  const layer = useRef(Symbol("modal"));
  const downOnOverlay = useRef(false);
  const latest = useRef({ onClose, dirty, saving });
  latest.current = { onClose, dirty, saving };

  function requestClose() {
    const { onClose: close, dirty: d, saving: s } = latest.current;
    if (s) return;
    if (d && !window.confirm("Discard changes?")) return;
    close();
  }

  useEffect(() => {
    const me = layer.current;
    layerStack.push(me);
    function onKeyDown(e: KeyboardEvent) {
      if (e.key !== "Escape") return;
      if (layerStack[layerStack.length - 1] !== me) return;
      e.preventDefault();
      requestClose();
    }
    document.addEventListener("keydown", onKeyDown);
    return () => {
      const i = layerStack.indexOf(me);
      if (i >= 0) layerStack.splice(i, 1);
      document.removeEventListener("keydown", onKeyDown);
    };
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []);

  return (
    <div
      className={overlayClassName}
      onPointerDown={(e) => {
        downOnOverlay.current = e.target === e.currentTarget;
      }}
      onPointerUp={(e) => {
        if (downOnOverlay.current && e.target === e.currentTarget) {
          requestClose();
        }
        downOnOverlay.current = false;
      }}
    >
      {children}
    </div>
  );
}
