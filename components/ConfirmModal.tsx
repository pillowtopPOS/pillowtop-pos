"use client";

import Modal from "@/components/Modal";

// Shared replacement for window.confirm: the same question, a primary
// button named for the action (never "OK"), and Cancel which does
// nothing but close. danger=false renders the primary in brand color.
export default function ConfirmModal({
  title,
  message,
  actionLabel,
  danger = true,
  busy = false,
  onConfirm,
  onCancel,
}: {
  title: string;
  message: string;
  actionLabel: string;
  danger?: boolean;
  busy?: boolean;
  onConfirm: () => void;
  onCancel: () => void;
}) {
  return (
    <Modal onClose={onCancel} saving={busy}>
      <div className="w-full max-w-sm rounded-lg border border-slate-200 bg-white p-6 shadow-lg">
        <h2 className="mb-2 text-lg font-semibold text-slate-900">{title}</h2>
        <p className="mb-3 text-sm text-slate-600">{message}</p>
        <div className="mt-4 flex gap-2">
          <button
            onClick={onConfirm}
            disabled={busy}
            className={`flex-1 rounded-md px-3 py-2 text-sm font-medium text-white disabled:opacity-50 ${
              danger
                ? "bg-red-600 hover:bg-red-700"
                : "bg-brand-600 hover:bg-brand-700"
            }`}
          >
            {actionLabel}
          </button>
          <button
            onClick={onCancel}
            className="flex-1 rounded-md border border-slate-300 bg-white px-3 py-2 text-sm font-medium text-slate-700 hover:bg-slate-50"
          >
            Cancel
          </button>
        </div>
      </div>
    </Modal>
  );
}
