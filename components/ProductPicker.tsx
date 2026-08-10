"use client";

import { useEffect, useState } from "react";
import { Search } from "lucide-react";
import { searchProducts, fetchProductStock, type Product } from "@/lib/inventory/queries";

export type ProductSelection = {
  productId: string | null;
  productSummary: string;
  price: number | null;
};

type ProductPickerProps = {
  storeId?: string;
  onSelect: (selection: ProductSelection) => void;
};

export default function ProductPicker({ storeId, onSelect }: ProductPickerProps) {
  const [query, setQuery] = useState("");
  const [debouncedQuery, setDebouncedQuery] = useState("");
  const [results, setResults] = useState<Product[]>([]);
  const [stockMap, setStockMap] = useState<Record<string, number>>({});
  const [loading, setLoading] = useState(false);
  const [custom, setCustom] = useState(false);
  const [customSummary, setCustomSummary] = useState("");
  const [selectedProduct, setSelectedProduct] = useState<Product | null>(null);

  useEffect(() => {
    const timeout = setTimeout(() => setDebouncedQuery(query), 300);
    return () => clearTimeout(timeout);
  }, [query]);

  useEffect(() => {
    if (!debouncedQuery.trim()) {
      setResults([]);
      return;
    }
    setLoading(true);
    searchProducts(debouncedQuery).then(async (products) => {
      setResults(products);
      if (storeId && products.length > 0) {
        const map = await fetchProductStock(
          products.map((p) => p.id),
          storeId
        );
        setStockMap(map);
      }
      setLoading(false);
    });
  }, [debouncedQuery, storeId]);

  function selectProduct(product: Product) {
    setSelectedProduct(product);
    setCustom(false);
    setQuery(product.item_name);
    setResults([]);
    onSelect({
      productId: product.id,
      productSummary: product.item_name,
      price: product.price ?? null,
    });
  }

  function useCustom() {
    const summary = custom ? customSummary : query;
    setCustom(true);
    setCustomSummary(summary);
    setSelectedProduct(null);
    setResults([]);
    onSelect({ productId: null, productSummary: summary, price: null });
  }

  function updateCustomSummary(value: string) {
    setCustomSummary(value);
    onSelect({ productId: null, productSummary: value, price: null });
  }

  return (
    <div className="space-y-2">
      <label className="block text-sm font-medium text-slate-700">
        Search products
      </label>
      <div className="relative">
        <Search className="absolute left-2.5 top-2.5 h-4 w-4 text-slate-400" />
        <input
          type="text"
          value={query}
          onChange={(e) => {
            setQuery(e.target.value);
            setCustom(false);
            if (selectedProduct) {
              setSelectedProduct(null);
            }
          }}
          placeholder="e.g. Helix Midnight"
          className="w-full rounded-md border border-slate-300 py-2 pl-9 pr-3 text-sm focus:border-brand-500 focus:outline-none focus:ring-1 focus:ring-brand-500"
        />
      </div>

      {loading && <p className="text-xs text-slate-500">Searching…</p>}

      {!loading && results.length > 0 && (
        <ul className="max-h-48 overflow-y-auto rounded-md border border-slate-200 bg-white shadow-sm">
          {results.map((product) => (
            <li
              key={product.id}
              onClick={() => selectProduct(product)}
              className="cursor-pointer border-b border-slate-100 p-2 text-sm hover:bg-slate-50 last:border-b-0"
            >
              <div className="flex items-center justify-between">
                <span className="font-medium text-slate-900">{product.item_name}</span>
                <span className="text-xs text-slate-500">
                  {product.brand ? `${product.brand} · ` : ""}
                  ${product.price?.toFixed(2) ?? "—"}
                </span>
              </div>
              {storeId && (
                <p className="text-xs text-slate-500">
                  Stock: {stockMap[product.id] ?? 0} · SKU: {product.sku}
                </p>
              )}
            </li>
          ))}
        </ul>
      )}

      {!loading && debouncedQuery && results.length === 0 && !custom && (
        <button
          onClick={useCustom}
          className="text-left text-sm text-brand-600 hover:text-brand-700"
        >
          Use &ldquo;{query}&rdquo; as a custom item
        </button>
      )}

      {custom && (
        <div>
          <label className="block text-sm font-medium text-slate-700">
            Custom product description
          </label>
          <textarea
            value={customSummary}
            onChange={(e) => updateCustomSummary(e.target.value)}
            placeholder="Describe the product"
            rows={3}
            className="mt-1 w-full rounded-md border border-slate-300 px-3 py-2 text-sm focus:border-brand-500 focus:outline-none focus:ring-1 focus:ring-brand-500"
          />
        </div>
      )}

      {selectedProduct && !custom && (
        <p className="text-sm text-slate-600">
          Selected: <span className="font-medium text-slate-900">{selectedProduct.item_name}</span>
          {selectedProduct.brand ? ` (${selectedProduct.brand})` : ""}
        </p>
      )}
    </div>
  );
}
