"use client";

import { useEffect, useRef, useState, type ReactNode } from "react";

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
  // Dirty-close confirmation replaces window.confirm — a second Modal on
  // the layer stack, so Escape/backdrop close only it, never the form.
  const [confirmDiscard, setConfirmDiscard] = useState(false);

  function requestClose() {
    const { onClose: close, dirty: d, saving: s } = latest.current;
    if (s) return;
    if (d && !confirmDiscard) {
      setConfirmDiscard(true);
      return;
    }
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
      {confirmDiscard && (
        <DiscardLayer
          onDiscard={() => {
            setConfirmDiscard(false);
            latest.current.onClose();
          }}
          onKeep={() => setConfirmDiscard(false)}
        />
      )}
    </div>
  );
}

// The "Discard changes?" layer — itself a Modal so it lands on top of the
// layer stack: Escape/backdrop close only this layer (its dirty=false,
// so a close here never re-prompts), and the parent stays mounted.
function DiscardLayer({
  onDiscard,
  onKeep,
}: {
  onDiscard: () => void;
  onKeep: () => void;
}) {
  return (
    <Modal onClose={onKeep}>
      <div className="w-full max-w-xs rounded-lg border border-slate-200 bg-white p-5 shadow-lg">
        <h2 className="mb-2 text-base font-semibold text-slate-900">
          Discard changes?
        </h2>
        <div className="mt-4 flex gap-2">
          <button
            onClick={onDiscard}
            className="flex-1 rounded-md bg-red-600 px-3 py-2 text-sm font-medium text-white hover:bg-red-700"
          >
            Discard changes
          </button>
          <button
            onClick={onKeep}
            className="flex-1 rounded-md border border-slate-300 bg-white px-3 py-2 text-sm font-medium text-slate-700 hover:bg-slate-50"
          >
            Keep editing
          </button>
        </div>
      </div>
    </Modal>
  );
}
