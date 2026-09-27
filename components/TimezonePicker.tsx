"use client";

import { useEffect, useMemo, useRef, useState } from "react";
import { allTimezones } from "@/lib/timezones";

type Props = {
  value: string | null;
  onChange: (tz: string | null) => void;
  allowEmpty?: boolean;
  emptyLabel?: string;
  disabled?: boolean;
  id?: string;
};

const MAX_RESULTS = 100;

export default function TimezonePicker({
  value,
  onChange,
  allowEmpty = false,
  emptyLabel = "Use company timezone",
  disabled = false,
  id,
}: Props) {
  const zones = useMemo(() => allTimezones(), []);
  const rootRef = useRef<HTMLDivElement>(null);
  const [open, setOpen] = useState(false);
  // null query = show the committed value; a string = the user is searching.
  const [query, setQuery] = useState<string | null>(null);

  const filtered = useMemo(() => {
    const q = (query ?? "").trim().toLowerCase();
    const list = q
      ? zones.filter((z) => z.toLowerCase().includes(q))
      : zones;
    return list.slice(0, MAX_RESULTS);
  }, [zones, query]);

  useEffect(() => {
    function onDocClick(e: MouseEvent) {
      if (rootRef.current && !rootRef.current.contains(e.target as Node)) {
        setOpen(false);
        setQuery(null);
      }
    }
    document.addEventListener("mousedown", onDocClick);
    return () => document.removeEventListener("mousedown", onDocClick);
  }, []);

  function commit(tz: string | null) {
    if (tz !== value) onChange(tz);
    setQuery(null);
    setOpen(false);
  }

  return (
    <div ref={rootRef} className="relative">
      <input
        id={id}
        type="text"
        role="combobox"
        aria-expanded={open}
        disabled={disabled}
        value={query ?? value ?? ""}
        placeholder={allowEmpty ? emptyLabel : "Search timezones…"}
        onFocus={() => {
          setQuery("");
          setOpen(true);
        }}
        onChange={(e) => {
          setQuery(e.target.value);
          setOpen(true);
        }}
        onKeyDown={(e) => {
          if (e.key === "Escape") {
            setOpen(false);
            setQuery(null);
          } else if (e.key === "Enter") {
            e.preventDefault();
            if (filtered.length === 1) commit(filtered[0]);
          }
        }}
        className="w-full rounded-md border border-slate-300 px-3 py-2 text-sm focus:border-brand-500 focus:outline-none focus:ring-1 focus:ring-brand-500 disabled:bg-slate-100"
      />
      {open && !disabled && (
        <ul className="absolute z-20 mt-1 max-h-60 w-full overflow-auto rounded-md border border-slate-200 bg-white py-1 shadow-lg">
          {allowEmpty && (
            <li>
              <button
                type="button"
                onMouseDown={(e) => {
                  e.preventDefault();
                  commit(null);
                }}
                className={`w-full px-3 py-2 text-left text-sm hover:bg-brand-50 ${
                  value === null
                    ? "font-medium text-brand-700"
                    : "text-slate-600 italic"
                }`}
              >
                {emptyLabel}
              </button>
            </li>
          )}
          {filtered.map((tz) => (
            <li key={tz}>
              <button
                type="button"
                onMouseDown={(e) => {
                  e.preventDefault();
                  commit(tz);
                }}
                className={`w-full px-3 py-2 text-left text-sm hover:bg-brand-50 ${
                  tz === value ? "font-medium text-brand-700" : "text-slate-700"
                }`}
              >
                {tz}
              </button>
            </li>
          ))}
          {filtered.length === 0 && (
            <li className="px-3 py-2 text-sm text-slate-500">
              No matching timezone
            </li>
          )}
        </ul>
      )}
    </div>
  );
}
