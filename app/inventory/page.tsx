"use client";

import { useEffect, useMemo, useRef, useState } from "react";
import { useRouter } from "next/navigation";
import Link from "next/link";
import * as XLSX from "xlsx";
import { Search, Package, Upload, Plus, X } from "lucide-react";
import { createClient } from "@/lib/supabase/client";
import { fetchCurrentEmployee, fetchStores, type Employee, type Store } from "@/lib/journeys/queries";
import {
  fetchProductsWithStock,
  updateProductStock,
  upsertProduct,
  type Product,
  type ProductWithStock,
} from "@/lib/inventory/queries";

type ImportMapping = {
  SKU: number | null;
  "Item Name": number | null;
  Brand: number | null;
  Cost: number | null;
  Price: number | null;
  "Sale Price": number | null;
};

const REQUIRED_FIELDS = ["SKU", "Item Name"] as const;
const ALL_FIELDS = [
  "SKU",
  "Item Name",
  "Brand",
  "Cost",
  "Price",
  "Sale Price",
] as const;

function coerceMoney(value: unknown): number | null {
  if (value === undefined || value === null) return null;
  const str = String(value).trim();
  if (str === "") return null;
  const cleaned = str.replace(/[$,\s]/g, "");
  const n = parseFloat(cleaned);
  if (Number.isNaN(n)) return null;
  return n;
}

export default function InventoryPage() {
  const router = useRouter();
  const [employee, setEmployee] = useState<Employee | null>(null);
  const [stores, setStores] = useState<Store[]>([]);
  const [currentStoreId, setCurrentStoreId] = useState<string>("");
  const [products, setProducts] = useState<ProductWithStock[]>([]);
  const [loading, setLoading] = useState(true);
  const [search, setSearch] = useState("");

  const [editingProduct, setEditingProduct] = useState<Product | null>(null);

  const [uploadStep, setUploadStep] = useState<"idle" | "mapping" | "preview" | "summary">("idle");
  const [rawRows, setRawRows] = useState<unknown[][]>([]);
  const [headers, setHeaders] = useState<string[]>([]);
  const [mapping, setMapping] = useState<ImportMapping>({
    SKU: null,
    "Item Name": null,
    Brand: null,
    Cost: null,
    Price: null,
    "Sale Price": null,
  });
  const [importSummary, setImportSummary] = useState<{
    created: number;
    updated: number;
    skipped: { row: number; reason: string }[];
  } | null>(null);

  const canViewAll = employee?.role === "owner" || employee?.role === "manager";

  const companyId = useMemo(() => {
    if (!employee?.home_store_id) return null;
    return stores.find((s) => s.id === employee.home_store_id)?.company_id ?? null;
  }, [employee, stores]);

  useEffect(() => {
    const supabase = createClient();
    supabase.auth.getSession().then(({ data: { session } }) => {
      if (!session?.user) {
        router.push("/login");
        return;
      }
      Promise.all([fetchCurrentEmployee(), fetchStores()]).then(([e, s]) => {
        setEmployee(e);
        setStores(s);
        const active =
          session.user.user_metadata?.active_store_id ?? e?.home_store_id ?? s[0]?.id ?? "";
        setCurrentStoreId(active);
        loadProducts(active);
      });
    });
  }, [router]);

  async function loadProducts(storeId: string) {
    setLoading(true);
    const data = await fetchProductsWithStock(storeId);
    setProducts(data);
    setLoading(false);
  }

  const filtered = useMemo(() => {
    const term = search.trim().toLowerCase();
    if (!term) return products;
    return products.filter((p) =>
      p.search_text?.toLowerCase().includes(term)
    );
  }, [products, search]);

  function onFileSelected(file: File) {
    const reader = new FileReader();
    reader.onload = (e) => {
      const data = e.target?.result;
      if (!data) return;
      const workbook = XLSX.read(data, { type: "array" });
      const sheetName = workbook.SheetNames[0];
      const sheet = workbook.Sheets[sheetName];
      const rows = XLSX.utils.sheet_to_json(sheet, { header: 1 }) as unknown[][];
      if (rows.length < 1) return;

      const h = rows[0].map((x) => (x === undefined ? "" : String(x).trim()));
      setHeaders(h);
      setRawRows(rows.slice(1));

      const guess: Partial<ImportMapping> = {};
      h.forEach((header, idx) => {
        const lower = header.toLowerCase();
        if (!guess.SKU && /\bsku\b/i.test(lower)) guess.SKU = idx;
        if (!guess["Item Name"] && /\b(item\s?name|product\s?name|name)\b/i.test(lower)) guess["Item Name"] = idx;
        if (!guess.Brand && /\bbrand\b/i.test(lower)) guess.Brand = idx;
        if (!guess.Cost && /\bcost\b/i.test(lower)) guess.Cost = idx;
        if (!guess.Price && /\bprice\b/i.test(lower) && !/sale/i.test(lower)) guess.Price = idx;
        if (!guess["Sale Price"] && /\b(sale\s?price|sale)\b/i.test(lower)) guess["Sale Price"] = idx;
      });

      setMapping((m) => ({ ...m, ...guess }));
      setUploadStep("mapping");
    };
    reader.readAsArrayBuffer(file);
  }

  function canPreview() {
    return REQUIRED_FIELDS.every((f) => mapping[f] !== null);
  }

  function mappedRows() {
    const out: Record<string, unknown>[] = [];
    for (const row of rawRows) {
      const obj: Record<string, unknown> = {};
      for (const field of ALL_FIELDS) {
        const idx = mapping[field];
        obj[field] = idx !== null ? row[idx] : undefined;
      }
      out.push(obj);
    }
    return out;
  }

  async function runImport() {
    if (!companyId) return;
    const rows = mappedRows();
    const records: Partial<Product & { company_id: string }>[] = [];
    const skipped: { row: number; reason: string }[] = [];

    rows.forEach((row, idx) => {
      const sku = (row.SKU ?? "").toString().trim();
      const itemName = (row["Item Name"] ?? "").toString().trim();
      if (!sku || !itemName) {
        skipped.push({ row: idx + 2, reason: "Missing SKU or Item Name" });
        return;
      }

      const brand = (row.Brand ?? "").toString().trim() || null;
      const cost = coerceMoney(row.Cost);
      const price = coerceMoney(row.Price);
      const salePrice = coerceMoney(row["Sale Price"]);

      if (row.Cost !== undefined && row.Cost !== null && row.Cost.toString().trim() !== "" && cost === null) {
        skipped.push({ row: idx + 2, reason: "Cost is not a valid number" });
        return;
      }
      if (row.Price !== undefined && row.Price !== null && row.Price.toString().trim() !== "" && price === null) {
        skipped.push({ row: idx + 2, reason: "Price is not a valid number" });
        return;
      }
      if (row["Sale Price"] !== undefined && row["Sale Price"] !== null && row["Sale Price"].toString().trim() !== "" && salePrice === null) {
        skipped.push({ row: idx + 2, reason: "Sale Price is not a valid number" });
        return;
      }

      records.push({
        company_id: companyId,
        sku,
        item_name: itemName,
        brand,
        cost,
        price,
        sale_price: salePrice,
      });
    });

    const supabase = createClient();
    const { error } = await supabase
      .from("products")
      .upsert(records, { onConflict: "company_id,sku", ignoreDuplicates: false });

    if (error) {
      window.alert(error.message);
      return;
    }

    const created = records.length;
    setImportSummary({
      created,
      updated: 0,
      skipped,
    });
    setUploadStep("summary");
    loadProducts(currentStoreId);
  }

  async function saveStock(productId: string, value: string) {
    const qty = Math.max(0, Math.floor(Number(value) || 0));
    await updateProductStock(productId, currentStoreId, qty);
    setProducts((prev) =>
      prev.map((p) => (p.id === productId ? { ...p, stock: qty } : p))
    );
  }

  async function saveProduct(product: Product | null) {
    if (!companyId || !product) return;
    await upsertProduct({ ...product, company_id: companyId });
    setEditingProduct(null);
    loadProducts(currentStoreId);
  }

  return (
    <main className="min-h-screen bg-slate-50 p-6">
      <header className="mb-4 flex flex-wrap items-center justify-between gap-4">
        <h1 className="text-2xl font-semibold text-slate-900">Inventory</h1>
        <div className="flex items-center gap-2">
          <Link
            href="/board"
            className="rounded-md border border-slate-300 bg-white px-3 py-2 text-sm font-medium text-slate-700 hover:bg-slate-50"
          >
            Back to Board
          </Link>
        </div>
      </header>

      <div className="mb-4 flex flex-wrap items-center gap-3">
        <div className="relative">
          <Search className="absolute left-2.5 top-2.5 h-4 w-4 text-slate-400" />
          <input
            type="text"
            value={search}
            onChange={(e) => setSearch(e.target.value)}
            placeholder="Search products"
            className="w-64 rounded-md border border-slate-300 py-2 pl-9 pr-3 text-sm focus:border-brand-500 focus:outline-none focus:ring-1 focus:ring-brand-500"
          />
        </div>

        {canViewAll && (
          <select
            value={currentStoreId}
            onChange={(e) => {
              setCurrentStoreId(e.target.value);
              loadProducts(e.target.value);
            }}
            className="rounded-md border border-slate-300 bg-white px-3 py-2 text-sm focus:border-brand-500 focus:outline-none focus:ring-1 focus:ring-brand-500"
          >
            {stores.map((s) => (
              <option key={s.id} value={s.id}>
                {s.name}
              </option>
            ))}
          </select>
        )}

        {employee?.role === "owner" || employee?.role === "manager" ? (
          <>
            <label className="inline-flex cursor-pointer items-center gap-2 rounded-md bg-brand-600 px-3 py-2 text-sm font-medium text-white hover:bg-brand-700">
              <Upload className="h-4 w-4" /> Upload file
              <input
                type="file"
                accept=".csv,.xlsx"
                className="hidden"
                onChange={(e) => {
                  const file = e.target.files?.[0];
                  if (file) onFileSelected(file);
                  e.target.value = "";
                }}
              />
            </label>
            <button
              onClick={() =>
                setEditingProduct({
                  id: "",
                  company_id: companyId ?? "",
                  sku: "",
                  item_name: "",
                  brand: null,
                  cost: null,
                  price: null,
                  sale_price: null,
                  search_text: "",
                  created_at: "",
                  updated_at: "",
                })
              }
              className="inline-flex items-center gap-2 rounded-md border border-slate-300 bg-white px-3 py-2 text-sm font-medium text-slate-700 hover:bg-slate-50"
            >
              <Plus className="h-4 w-4" /> Add product
            </button>
          </>
        ) : null}
      </div>

      {loading ? (
        <p className="text-sm text-slate-500">Loading…</p>
      ) : (
        <div className="overflow-x-auto rounded-lg border border-slate-200 bg-white">
          <table className="w-full text-sm">
            <thead className="border-b border-slate-200 bg-slate-50 text-left">
              <tr>
                <th className="px-4 py-2 font-medium text-slate-700">SKU</th>
                <th className="px-4 py-2 font-medium text-slate-700">Item Name</th>
                <th className="px-4 py-2 font-medium text-slate-700">Brand</th>
                <th className="px-4 py-2 font-medium text-slate-700">Cost</th>
                <th className="px-4 py-2 font-medium text-slate-700">Price</th>
                <th className="px-4 py-2 font-medium text-slate-700">Sale Price</th>
                <th className="px-4 py-2 font-medium text-slate-700">Stock</th>
                <th className="px-4 py-2 font-medium text-slate-700"></th>
              </tr>
            </thead>
            <tbody>
              {filtered.map((p) => (
                <tr key={p.id} className="border-b border-slate-100 hover:bg-slate-50">
                  <td className="px-4 py-2">{p.sku}</td>
                  <td className="px-4 py-2 font-medium text-slate-900">{p.item_name}</td>
                  <td className="px-4 py-2">{p.brand ?? "—"}</td>
                  <td className="px-4 py-2">{p.cost?.toFixed(2) ?? "—"}</td>
                  <td className="px-4 py-2">{p.price?.toFixed(2) ?? "—"}</td>
                  <td className="px-4 py-2">{p.sale_price?.toFixed(2) ?? "—"}</td>
                  <td className="px-4 py-2">
                    <input
                      type="number"
                      min={0}
                      defaultValue={p.stock ?? 0}
                      onBlur={(e) => saveStock(p.id, e.target.value)}
                      className="w-20 rounded-md border border-slate-300 px-2 py-1 text-sm focus:border-brand-500 focus:outline-none focus:ring-1 focus:ring-brand-500"
                    />
                  </td>
                  <td className="px-4 py-2">
                    <button
                      onClick={() => setEditingProduct(p)}
                      className="text-sm text-brand-600 hover:text-brand-700"
                    >
                      Edit
                    </button>
                  </td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      )}

      {uploadStep !== "idle" && (
        <div className="fixed inset-0 z-50 flex items-center justify-center bg-slate-900/50 p-4">
          <div className="w-full max-w-2xl max-h-[90vh] overflow-y-auto rounded-lg border border-slate-200 bg-white p-6 shadow-lg">
            <div className="mb-4 flex items-center justify-between">
              <h2 className="text-lg font-semibold text-slate-900">
                {uploadStep === "mapping" && "Map columns"}
                {uploadStep === "preview" && "Preview import"}
                {uploadStep === "summary" && "Import summary"}
              </h2>
              <button
                onClick={() => setUploadStep("idle")}
                className="rounded-md p-1 text-slate-500 hover:bg-slate-100"
              >
                <X className="h-5 w-5" />
              </button>
            </div>

            {uploadStep === "mapping" && (
              <div className="space-y-4">
                <p className="text-sm text-slate-600">
                  Match each required field to a column from the uploaded file. {rawRows.length} rows found.
                </p>
                <div className="grid grid-cols-2 gap-4">
                  {ALL_FIELDS.map((field) => (
                    <div key={field}>
                      <label className="block text-sm font-medium text-slate-700">
                        {field} {REQUIRED_FIELDS.includes(field as any) && <span className="text-red-500">*</span>}
                      </label>
                      <select
                        value={mapping[field] ?? ""}
                        onChange={(e) =>
                          setMapping((m) => ({
                            ...m,
                            [field]: e.target.value === "" ? null : Number(e.target.value),
                          }))
                        }
                        className="mt-1 w-full rounded-md border border-slate-300 bg-white px-3 py-2 text-sm focus:border-brand-500 focus:outline-none focus:ring-1 focus:ring-brand-500"
                      >
                        <option value="">—</option>
                        {headers.map((h, idx) => (
                          <option key={idx} value={idx}>
                            {h}
                          </option>
                        ))}
                      </select>
                    </div>
                  ))}
                </div>
                <button
                  onClick={() => canPreview() && setUploadStep("preview")}
                  disabled={!canPreview()}
                  className="rounded-md bg-brand-600 px-4 py-2 text-sm font-medium text-white hover:bg-brand-700 disabled:opacity-50"
                >
                  Preview
                </button>
              </div>
            )}

            {uploadStep === "preview" && (
              <div className="space-y-4">
                <p className="text-sm text-slate-600">First rows after mapping:</p>
                <div className="overflow-x-auto rounded-md border border-slate-200">
                  <table className="w-full text-sm">
                    <thead className="bg-slate-50">
                      <tr>
                        {ALL_FIELDS.map((f) => (
                          <th key={f} className="px-3 py-2 text-left font-medium text-slate-700">
                            {f}
                          </th>
                        ))}
                      </tr>
                    </thead>
                    <tbody>
                      {mappedRows().slice(0, 10).map((row, idx) => (
                        <tr key={idx} className="border-b border-slate-100">
                          {ALL_FIELDS.map((f) => (
                            <td key={f} className="px-3 py-2">{String(row[f] ?? "—")}</td>
                          ))}
                        </tr>
                      ))}
                    </tbody>
                  </table>
                </div>
                <div className="flex gap-2">
                  <button
                    onClick={runImport}
                    className="rounded-md bg-brand-600 px-4 py-2 text-sm font-medium text-white hover:bg-brand-700"
                  >
                    Import {rawRows.length} rows
                  </button>
                  <button
                    onClick={() => setUploadStep("mapping")}
                    className="rounded-md border border-slate-300 bg-white px-4 py-2 text-sm font-medium text-slate-700 hover:bg-slate-50"
                  >
                    Back
                  </button>
                </div>
              </div>
            )}

            {uploadStep === "summary" && importSummary && (
              <div className="space-y-4">
                <p className="text-sm text-slate-600">
                  Imported <strong>{importSummary.created}</strong> rows.
                </p>
                {importSummary.skipped.length > 0 && (
                  <div>
                    <p className="text-sm font-medium text-amber-700">
                      {importSummary.skipped.length} rows skipped
                    </p>
                    <ul className="mt-1 max-h-40 overflow-y-auto rounded-md border border-slate-200 bg-slate-50 p-2 text-xs text-slate-600">
                      {importSummary.skipped.map((s, idx) => (
                        <li key={idx}>Row {s.row}: {s.reason}</li>
                      ))}
                    </ul>
                  </div>
                )}
                <button
                  onClick={() => setUploadStep("idle")}
                  className="rounded-md bg-brand-600 px-4 py-2 text-sm font-medium text-white hover:bg-brand-700"
                >
                  Done
                </button>
              </div>
            )}
          </div>
        </div>
      )}

      {editingProduct && (
        <ProductModal
          product={editingProduct}
          onClose={() => setEditingProduct(null)}
          onSave={(p) => {
            setEditingProduct(p);
            saveProduct(p);
          }}
        />
      )}
    </main>
  );
}

function ProductModal({
  product,
  onClose,
  onSave,
}: {
  product: Product;
  onClose: () => void;
  onSave: (p: Product) => void;
}) {
  const [p, setP] = useState<Product>(product);

  return (
    <div className="fixed inset-0 z-50 flex items-center justify-center bg-slate-900/50 p-4">
      <div className="w-full max-w-md rounded-lg border border-slate-200 bg-white p-6 shadow-lg">
        <div className="mb-4 flex items-center justify-between">
          <h2 className="text-lg font-semibold text-slate-900">
            {product.id ? "Edit product" : "Add product"}
          </h2>
          <button onClick={onClose} className="rounded-md p-1 text-slate-500 hover:bg-slate-100">
            <X className="h-5 w-5" />
          </button>
        </div>
        <div className="space-y-3">
          <div>
            <label className="block text-sm font-medium text-slate-700">SKU *</label>
            <input
              value={p.sku}
              onChange={(e) => setP((x) => ({ ...x, sku: e.target.value }))}
              className="mt-1 w-full rounded-md border border-slate-300 px-3 py-2 text-sm focus:border-brand-500 focus:outline-none focus:ring-1 focus:ring-brand-500"
            />
          </div>
          <div>
            <label className="block text-sm font-medium text-slate-700">Item Name *</label>
            <input
              value={p.item_name}
              onChange={(e) => setP((x) => ({ ...x, item_name: e.target.value }))}
              className="mt-1 w-full rounded-md border border-slate-300 px-3 py-2 text-sm focus:border-brand-500 focus:outline-none focus:ring-1 focus:ring-brand-500"
            />
          </div>
          <div>
            <label className="block text-sm font-medium text-slate-700">Brand</label>
            <input
              value={p.brand ?? ""}
              onChange={(e) => setP((x) => ({ ...x, brand: e.target.value || null }))}
              className="mt-1 w-full rounded-md border border-slate-300 px-3 py-2 text-sm focus:border-brand-500 focus:outline-none focus:ring-1 focus:ring-brand-500"
            />
          </div>
          <div className="grid grid-cols-3 gap-2">
            <div>
              <label className="block text-sm font-medium text-slate-700">Cost</label>
              <input
                type="number"
                value={p.cost ?? ""}
                onChange={(e) =>
                  setP((x) => ({ ...x, cost: e.target.value === "" ? null : Number(e.target.value) }))
                }
                className="mt-1 w-full rounded-md border border-slate-300 px-3 py-2 text-sm focus:border-brand-500 focus:outline-none focus:ring-1 focus:ring-brand-500"
              />
            </div>
            <div>
              <label className="block text-sm font-medium text-slate-700">Price</label>
              <input
                type="number"
                value={p.price ?? ""}
                onChange={(e) =>
                  setP((x) => ({ ...x, price: e.target.value === "" ? null : Number(e.target.value) }))
                }
                className="mt-1 w-full rounded-md border border-slate-300 px-3 py-2 text-sm focus:border-brand-500 focus:outline-none focus:ring-1 focus:ring-brand-500"
              />
            </div>
            <div>
              <label className="block text-sm font-medium text-slate-700">Sale Price</label>
              <input
                type="number"
                value={p.sale_price ?? ""}
                onChange={(e) =>
                  setP((x) => ({ ...x, sale_price: e.target.value === "" ? null : Number(e.target.value) }))
                }
                className="mt-1 w-full rounded-md border border-slate-300 px-3 py-2 text-sm focus:border-brand-500 focus:outline-none focus:ring-1 focus:ring-brand-500"
              />
            </div>
          </div>
        </div>
        <div className="mt-4 flex gap-2">
          <button
            onClick={() => onSave(p)}
            disabled={!p.sku || !p.item_name}
            className="flex-1 rounded-md bg-brand-600 px-3 py-2 text-sm font-medium text-white hover:bg-brand-700 disabled:opacity-50"
          >
            Save
          </button>
          <button
            onClick={onClose}
            className="flex-1 rounded-md border border-slate-300 bg-white px-3 py-2 text-sm font-medium text-slate-700 hover:bg-slate-50"
          >
            Cancel
          </button>
        </div>
      </div>
    </div>
  );
}
