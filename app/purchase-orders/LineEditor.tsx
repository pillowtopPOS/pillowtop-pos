"use client";

export default function LineEditor({
  name,
  quantity,
  unitCost,
  minQty = 1,
  onQuantity,
  onCost,
  onBlurCommit,
  onRemove,
}: {
  name: string;
  quantity: number;
  unitCost: number;
  minQty?: number;
  onQuantity: (v: number) => void;
  onCost: (v: number) => void;
  onBlurCommit?: () => void;
  onRemove?: () => void;
}) {
  return (
    <div className="grid grid-cols-[1fr_4.5rem_6rem_auto] items-end gap-2 border-t pt-2 text-sm">
      <span className="pb-1.5">{name}</span>
      <label className="block text-xs text-slate-500">
        Qty
        <input
          type="number"
          min={minQty}
          value={quantity}
          onChange={(e) => onQuantity(Number(e.target.value))}
          onBlur={onBlurCommit}
          className="mt-0.5 block w-full rounded border px-2 py-1 text-sm"
        />
      </label>
      <label className="block text-xs text-slate-500">
        Unit cost
        <input
          type="number"
          min={0}
          step=".01"
          value={unitCost}
          onChange={(e) => onCost(Number(e.target.value))}
          onBlur={onBlurCommit}
          className="mt-0.5 block w-full rounded border px-2 py-1 text-sm"
        />
      </label>
      {onRemove ? (
        <button
          type="button"
          onClick={onRemove}
          className="pb-1.5 text-xs text-red-600 hover:text-red-800"
        >
          Remove
        </button>
      ) : (
        <span className="pb-1.5 text-xs text-slate-400">Received</span>
      )}
    </div>
  );
}
