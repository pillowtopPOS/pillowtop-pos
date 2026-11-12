"use client";

import { useEffect, useRef, useState } from "react";

// Small inline "Copy" button for phone numbers / emails. Shows a brief
// "Copied" state; never uses native dialogs.
export default function CopyButton({
  value,
  testId,
  label = "Copy",
}: {
  value: string;
  testId?: string;
  label?: string;
}) {
  const [copied, setCopied] = useState(false);
  const timer = useRef<ReturnType<typeof setTimeout> | null>(null);

  useEffect(
    () => () => {
      if (timer.current) clearTimeout(timer.current);
    },
    []
  );

  async function copy() {
    try {
      await navigator.clipboard.writeText(value);
    } catch {
      // Clipboard API can fail outside secure contexts; try the legacy path.
      try {
        const ta = document.createElement("textarea");
        ta.value = value;
        ta.style.position = "fixed";
        ta.style.opacity = "0";
        document.body.appendChild(ta);
        ta.select();
        document.execCommand("copy");
        document.body.removeChild(ta);
      } catch {
        return;
      }
    }
    setCopied(true);
    if (timer.current) clearTimeout(timer.current);
    timer.current = setTimeout(() => setCopied(false), 1500);
  }

  return (
    <button
      type="button"
      data-testid={testId}
      onClick={copy}
      className="inline-flex min-h-[40px] items-center rounded-md border border-slate-300 bg-white px-2.5 text-xs font-medium text-slate-600 hover:bg-slate-50"
    >
      {copied ? "Copied" : label}
    </button>
  );
}
