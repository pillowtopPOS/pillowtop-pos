"use client";

import { useEffect, useState } from "react";
import { Search } from "lucide-react";
import { searchProducts, type Product } from "@/lib/inventory/queries";

export default function ProductSearch({
  placeholder = "Search products to add…",
  excludeIds = [],
  disabled = false,
  onSelect,
}: {
  placeholder?: string;
  excludeIds?: string[];
  disabled?: boolean;
  onSelect: (product: Product) => void;
}) {
  const [query, setQuery] = useState("");
  const [options, setOptions] = useState<Product[]>([]);

  useEffect(() => {
    const q = query.trim();
    if (!q) {
      setOptions([]);
      return;
    }
    const t = setTimeout(() => {
      searchProducts(q).then(setOptions);
    }, 200);
    return () => clearTimeout(t);
  }, [query]);

  return (
    <div className="relative">
      <Search className="absolute left-3 top-2.5 h-4 w-4 text-slate-400" />
      <input
        value={query}
        onChange={(e) => setQuery(e.target.value)}
        placeholder={placeholder}
        disabled={disabled}
        className="w-full rounded-md border border-slate-300 bg-white py-2 pl-9 pr-3 text-sm"
      />
      {options.length > 0 && (
        <div className="absolute z-10 mt-1 max-h-56 w-full overflow-y-auto rounded-md border border-slate-200 bg-white shadow-lg">
          {options.map((p) => {
            const excluded = excludeIds.includes(p.id);
            return (
              <button
                key={p.id}
                type="button"
                disabled={disabled || excluded}
                onClick={() => {
                  onSelect(p);
                  setQuery("");
                  setOptions([]);
                }}
                className="flex w-full items-center justify-between px-3 py-2 text-left text-sm hover:bg-slate-50 disabled:opacity-50"
              >
                <span>{p.item_name}</span>
                <span className="text-xs text-slate-400">
                  {p.sku}
                  {excluded && " · already on order"}
                </span>
              </button>
            );
          })}
        </div>
      )}
    </div>
  );
}
