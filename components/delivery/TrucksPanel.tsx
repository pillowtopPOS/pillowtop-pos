"use client";

import { useEffect, useRef, useState } from "react";
import { X } from "lucide-react";
import {
  createDeliveryTruck,
  updateDeliveryTruck,
  setDeliveryTruckArchived,
  setTruckWeekdayPattern,
  type DeliveryTruckInfo,
  type ArchivedDeliveryTruck,
} from "@/lib/delivery/queries";
import { fetchStores } from "@/lib/journeys/queries";

const WEEKDAY_NUMS = [1, 2, 3, 4, 5, 6, 7];
const WEEKDAY_NAMES = [
  "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday", "Sunday",
];

function WeekdayToggles({
  pattern,
  disabled,
  startDay = 1,
  onToggle,
}: {
  pattern: number[];
  disabled?: boolean;
  startDay?: number;
  onToggle: (weekday: number) => void;
}) {
  // Display order follows the company's week-start setting; the stored
  // pattern stays ISO (1=Mon..7=Sun) either way.
  const ordered = [...WEEKDAY_NUMS].sort(
    (a, b) => ((a - startDay + 7) % 7) - ((b - startDay + 7) % 7)
  );
  return (
    <div className="flex gap-1">
      {ordered.map((num) => {
        const on = pattern.includes(num);
        return (
          <button
            key={num}
            type="button"
            disabled={disabled}
            onClick={() => onToggle(num)}
            title={`${WEEKDAY_NAMES[num - 1]}${on ? " — runs" : " — off"}`}
            className={`flex h-7 w-7 items-center justify-center rounded border text-xs font-medium ${
              on
                ? "border-brand-600 bg-brand-600 text-white"
                : "border-slate-300 bg-white text-slate-500 hover:bg-slate-50"
            } disabled:cursor-not-allowed disabled:opacity-50`}
          >
            {WEEKDAY_NAMES[num - 1][0]}
          </button>
        );
      })}
    </div>
  );
}

function TruckFormFields({
  name,
  setName,
  stopCap,
  setStopCap,
  pattern,
  setPattern,
  startDay = 1,
  nameError,
  capError,
  patternError,
  showPattern = true,
  onLastDayBlocked,
}: {
  name: string;
  setName: (v: string) => void;
  stopCap: string;
  setStopCap: (v: string) => void;
  pattern: number[];
  setPattern: (v: number[]) => void;
  startDay?: number;
  nameError?: string;
  capError?: string;
  patternError?: string;
  showPattern?: boolean;
  onLastDayBlocked?: () => void;
}) {
  const toggleDay = (num: number) => {
    if (pattern.includes(num)) {
      if (pattern.length <= 1) {
        onLastDayBlocked?.();
        return;
      }
      setPattern(pattern.filter((d) => d !== num));
    } else {
      setPattern([...pattern, num].sort((a, b) => a - b));
    }
  };

  return (
    <div className="space-y-3">
      <div>
        <label className="mb-1 block text-xs font-medium text-slate-600">
          Name
        </label>
        <input
          type="text"
          value={name}
          onChange={(e) => setName(e.target.value)}
          placeholder="e.g. Truck 1"
          className="w-full rounded-md border border-slate-300 px-3 py-2 text-sm focus:border-brand-500 focus:outline-none"
        />
        {nameError && <p className="mt-1 text-xs text-red-600">{nameError}</p>}
      </div>

      <div>
        <label className="mb-1 block text-xs font-medium text-slate-600">
          Daily stop cap
        </label>
        <input
          type="number"
          min={1}
          max={50}
          step={1}
          value={stopCap}
          onChange={(e) => setStopCap(e.target.value)}
          className="w-24 rounded-md border border-slate-300 px-3 py-2 text-sm focus:border-brand-500 focus:outline-none"
        />
        {capError && <p className="mt-1 text-xs text-red-600">{capError}</p>}
      </div>

      {showPattern && (
        <div>
          <label className="mb-1 block text-xs font-medium text-slate-600">
            Runs on
          </label>
          <WeekdayToggles pattern={pattern} startDay={startDay} onToggle={toggleDay} />
          {patternError && (
            <p className="mt-1 text-xs text-red-600">{patternError}</p>
          )}
        </div>
      )}
    </div>
  );
}

const PATTERN_ERROR =
  "A truck needs at least one day it runs. Archive it instead if you don't want to use it.";
const SAVE_ERROR = "Couldn't save the truck. Please try again.";

export default function TrucksPanel({
  trucks,
  archivedTrucks,
  weekStartDay,
  onClose,
  onChanged,
  startInAddMode = false,
}: {
  trucks: DeliveryTruckInfo[];
  archivedTrucks: ArchivedDeliveryTruck[];
  weekStartDay: number;
  onClose: () => void;
  onChanged: () => void;
  startInAddMode?: boolean;
}) {
  const [hubLocationId, setHubLocationId] = useState<string | null>(null);
  const [showAdd, setShowAdd] = useState(startInAddMode);

  // Add form state
  const [addName, setAddName] = useState("");
  const [addCap, setAddCap] = useState("8");
  const [addPattern, setAddPattern] = useState<number[]>([1, 2, 3, 4, 5, 6]);
  const [addNameError, setAddNameError] = useState("");
  const [addCapError, setAddCapError] = useState("");
  const [addPatternError, setAddPatternError] = useState("");
  const [addSaving, setAddSaving] = useState(false);
  const [addError, setAddError] = useState("");
  // Synchronous in-flight guards — React state updates are async, so two
  // clicks in the same tick would both pass a state check. Refs are read
  // and written synchronously.
  const addInFlight = useRef(false);
  const editInFlight = useRef(false);
  const patternInFlight = useRef<Set<string>>(new Set());

  // Edit state: truck id -> draft fields
  const [editingId, setEditingId] = useState<string | null>(null);
  const [editName, setEditName] = useState("");
  const [editCap, setEditCap] = useState("8");
  const [editNameError, setEditNameError] = useState("");
  const [editCapError, setEditCapError] = useState("");
  const [editSaving, setEditSaving] = useState(false);
  const [editError, setEditError] = useState("");

  // Pattern saves + archive confirm
  const [patternSaving, setPatternSaving] = useState<Set<string>>(new Set());
  const [patternErrors, setPatternErrors] = useState<Map<string, string>>(new Map());
  const [confirmArchiveId, setConfirmArchiveId] = useState<string | null>(null);
  const [archiveSaving, setArchiveSaving] = useState(false);
  const [rowError, setRowError] = useState("");
  const [showArchived, setShowArchived] = useState(false);
  const [restoreSaving, setRestoreSaving] = useState<Set<string>>(new Set());

  useEffect(() => {
    fetchStores(true).then((list) => {
      const usable = list.filter((s) => s.location_type !== "WAREHOUSE_QUARANTINE");
      // Hub rule: new trucks silently home at the main warehouse.
      const hub =
        usable.find((s) => s.location_type === "WAREHOUSE") ?? usable[0];
      if (hub) setHubLocationId(hub.id);
    });
  }, []);

  useEffect(() => {
    const onKey = (e: KeyboardEvent) => {
      if (e.key === "Escape") onClose();
    };
    window.addEventListener("keydown", onKey);
    return () => window.removeEventListener("keydown", onKey);
  }, [onClose]);

  const startEdit = (t: DeliveryTruckInfo) => {
    setEditingId(t.id);
    setEditName(t.name);
    setEditCap(String(t.default_stop_cap));
    setEditNameError("");
    setEditCapError("");
    setEditError("");
    setConfirmArchiveId(null);
  };

  const validateCap = (raw: string): number | null => {
    const n = Number(raw);
    if (!Number.isInteger(n) || n < 1 || n > 50) return null;
    return n;
  };

  // Case/space-insensitive duplicate check across active AND archived
  // trucks. excludeId skips the truck being edited.
  const nameTaken = (raw: string, excludeId?: string) => {
    const n = raw.trim().toLowerCase();
    if (!n) return false;
    return [...trucks, ...archivedTrucks].some(
      (t) => t.id !== excludeId && t.name.trim().toLowerCase() === n
    );
  };

  const submitAdd = async () => {
    if (addInFlight.current) return;
    setAddNameError("");
    setAddCapError("");
    setAddPatternError("");
    setAddError("");
    let ok = true;
    if (!addName.trim()) {
      setAddNameError("Give the truck a name.");
      ok = false;
    } else if (nameTaken(addName)) {
      setAddNameError(
        `A truck named '${addName.trim()}' already exists. Pick a different name.`
      );
      ok = false;
    }
    const cap = validateCap(addCap);
    if (cap === null) {
      setAddCapError("Enter a whole number from 1 to 50.");
      ok = false;
    }
    if (addPattern.length === 0) {
      setAddPatternError(PATTERN_ERROR);
      ok = false;
    }
    if (!ok) return;
    addInFlight.current = true;
    setAddSaving(true);
    try {
      await createDeliveryTruck({
        name: addName.trim(),
        homeLocationId: hubLocationId,
        defaultStopCap: cap!,
        weeklyPattern: addPattern,
      });
      setAddName("");
      setAddCap("8");
      setAddPattern([1, 2, 3, 4, 5, 6]);
      setShowAdd(false);
      onChanged();
    } catch {
      setAddError(SAVE_ERROR);
    } finally {
      addInFlight.current = false;
      setAddSaving(false);
    }
  };

  const submitEdit = async (truck: DeliveryTruckInfo) => {
    const truckId = truck.id;
    if (editInFlight.current) return;
    setEditNameError("");
    setEditCapError("");
    setEditError("");
    let ok = true;
    if (!editName.trim()) {
      setEditNameError("Give the truck a name.");
      ok = false;
    } else if (nameTaken(editName, truckId)) {
      setEditNameError(
        `A truck named '${editName.trim()}' already exists. Pick a different name.`
      );
      ok = false;
    }
    const cap = validateCap(editCap);
    if (cap === null) {
      setEditCapError("Enter a whole number from 1 to 50.");
      ok = false;
    }
    if (!ok) return;
    editInFlight.current = true;
    setEditSaving(true);
    try {
      await updateDeliveryTruck({
        truckId,
        name: editName.trim(),
        // Home location is not editable in the UI — pass the truck's
        // current value through unchanged.
        homeLocationId: truck.home_location_id,
        defaultStopCap: cap!,
      });
      setEditingId(null);
      onChanged();
    } catch {
      setEditError(SAVE_ERROR);
    } finally {
      editInFlight.current = false;
      setEditSaving(false);
    }
  };

  const togglePatternDay = async (truck: DeliveryTruckInfo, num: number) => {
    const current = truck.weekly_pattern;
    if (patternInFlight.current.has(truck.id)) return;
    let next: number[];
    if (current.includes(num)) {
      if (current.length <= 1) {
        setPatternErrors((m) => new Map(m).set(truck.id, PATTERN_ERROR));
        return;
      }
      next = current.filter((d) => d !== num);
      setPatternErrors((m) => {
        const n = new Map(m);
        n.delete(truck.id);
        return n;
      });
    } else {
      next = [...current, num].sort((a, b) => a - b);
      setPatternErrors((m) => {
        const n = new Map(m);
        n.delete(truck.id);
        return n;
      });
    }
    patternInFlight.current.add(truck.id);
    setPatternSaving((prev) => new Set(prev).add(truck.id));
    try {
      await setTruckWeekdayPattern(truck.id, next);
      onChanged();
    } catch {
      setRowError(SAVE_ERROR);
    } finally {
      patternInFlight.current.delete(truck.id);
      setPatternSaving((prev) => {
        const n = new Set(prev);
        n.delete(truck.id);
        return n;
      });
    }
  };

  const confirmArchive = async (truckId: string) => {
    if (archiveSaving) return;
    setArchiveSaving(true);
    setRowError("");
    try {
      await setDeliveryTruckArchived(truckId, true);
      setConfirmArchiveId(null);
      setEditingId(null);
      onChanged();
    } catch {
      setRowError(SAVE_ERROR);
    } finally {
      setArchiveSaving(false);
    }
  };

  const restoreTruck = async (truckId: string) => {
    if (restoreSaving.has(truckId)) return;
    setRestoreSaving((prev) => new Set(prev).add(truckId));
    setRowError("");
    try {
      await setDeliveryTruckArchived(truckId, false);
      onChanged();
    } catch {
      setRowError(SAVE_ERROR);
    } finally {
      setRestoreSaving((prev) => {
        const n = new Set(prev);
        n.delete(truckId);
        return n;
      });
    }
  };

  return (
    <div className="fixed inset-0 z-40">
      <div className="absolute inset-0 bg-slate-900/20" onClick={onClose} />
      <aside className="absolute inset-y-0 right-0 flex w-full max-w-md flex-col bg-white shadow-xl">
        <div className="flex items-center justify-between border-b border-slate-200 px-4 py-3">
          <h2 className="text-base font-semibold text-slate-900">Trucks</h2>
          <button
            type="button"
            onClick={onClose}
            aria-label="Close"
            className="rounded-md p-1.5 text-slate-500 hover:bg-slate-100"
          >
            <X className="h-5 w-5" />
          </button>
        </div>

        <div className="flex-1 overflow-y-auto px-4 py-4">
          {rowError && (
            <p className="mb-3 rounded-md bg-red-50 px-3 py-2 text-xs text-red-700">
              {rowError}
            </p>
          )}

          {/* Active trucks */}
          <div className="space-y-3">
            {trucks.map((t) => (
              <div
                key={t.id}
                className="rounded-lg border border-slate-200 p-3"
              >
                {editingId === t.id ? (
                  <div className="space-y-3">
                    <TruckFormFields
                      name={editName}
                      setName={setEditName}
                      stopCap={editCap}
                      setStopCap={setEditCap}
                      pattern={t.weekly_pattern}
                      setPattern={() => {}}
                      startDay={weekStartDay}
                      nameError={editNameError}
                      capError={editCapError}
                      showPattern={false}
                    />
                    <p className="text-xs text-slate-400">
                      Weekly days save as you toggle them.
                    </p>
                    {editError && (
                      <p className="text-xs text-red-600">{editError}</p>
                    )}
                    <div className="flex gap-2">
                      <button
                        type="button"
                        disabled={editSaving}
                        onClick={() => submitEdit(t)}
                        className="rounded-md bg-brand-600 px-3 py-1.5 text-sm font-medium text-white hover:bg-brand-700 disabled:opacity-50"
                      >
                        {editSaving ? "Saving…" : "Save"}
                      </button>
                      <button
                        type="button"
                        onClick={() => setEditingId(null)}
                        className="rounded-md border border-slate-300 px-3 py-1.5 text-sm text-slate-600 hover:bg-slate-50"
                      >
                        Cancel
                      </button>
                    </div>
                  </div>
                ) : (
                  <>
                    <div className="flex items-start justify-between gap-2">
                      <div className="min-w-0">
                        <p className="truncate text-sm font-medium text-slate-800">
                          {t.name}
                        </p>
                        <p className="text-xs text-slate-500">
                          {t.default_stop_cap} stops/day
                        </p>
                      </div>
                      <div className="flex shrink-0 gap-1">
                        <button
                          type="button"
                          onClick={() => startEdit(t)}
                          className="rounded border border-slate-300 px-2 py-1 text-xs text-slate-600 hover:bg-slate-50"
                        >
                          Edit
                        </button>
                        <button
                          type="button"
                          onClick={() => setConfirmArchiveId(t.id)}
                          className="rounded border border-slate-300 px-2 py-1 text-xs text-slate-600 hover:bg-slate-50"
                        >
                          Archive
                        </button>
                      </div>
                    </div>
                    <div className="mt-2 flex items-center gap-2">
                      <WeekdayToggles
                        pattern={t.weekly_pattern}
                        startDay={weekStartDay}
                        disabled={patternSaving.has(t.id)}
                        onToggle={(num) => togglePatternDay(t, num)}
                      />
                      {patternSaving.has(t.id) && (
                        <span className="text-xs text-slate-400">Saving…</span>
                      )}
                    </div>
                    {patternErrors.get(t.id) && (
                      <p className="mt-1 text-xs text-red-600">
                        {patternErrors.get(t.id)}
                      </p>
                    )}
                    {confirmArchiveId === t.id && (
                      <div className="mt-2 rounded-md bg-amber-50 px-3 py-2">
                        <p className="text-xs text-amber-800">
                          Archive {t.name}? It will leave the calendar. You can
                          restore it from Archived trucks.
                        </p>
                        <div className="mt-2 flex gap-2">
                          <button
                            type="button"
                            disabled={archiveSaving}
                            onClick={() => confirmArchive(t.id)}
                            className="rounded-md bg-amber-600 px-2.5 py-1 text-xs font-medium text-white hover:bg-amber-700 disabled:opacity-50"
                          >
                            {archiveSaving ? "Archiving…" : "Archive"}
                          </button>
                          <button
                            type="button"
                            onClick={() => setConfirmArchiveId(null)}
                            className="rounded-md border border-slate-300 px-2.5 py-1 text-xs text-slate-600 hover:bg-white"
                          >
                            Cancel
                          </button>
                        </div>
                      </div>
                    )}
                  </>
                )}
              </div>
            ))}
            {trucks.length === 0 && !showAdd && (
              <p className="text-sm text-slate-500">No trucks yet.</p>
            )}
          </div>

          {/* Add truck */}
          <div className="mt-5">
            {showAdd ? (
              <div className="rounded-lg border border-slate-200 p-3">
                <p className="mb-3 text-sm font-medium text-slate-800">
                  Add truck
                </p>
                <TruckFormFields
                  name={addName}
                  setName={setAddName}
                  stopCap={addCap}
                  setStopCap={setAddCap}
                  pattern={addPattern}
                  setPattern={(v) => {
                    setAddPattern(v);
                    setAddPatternError("");
                  }}
                  startDay={weekStartDay}
                  nameError={addNameError}
                  capError={addCapError}
                  patternError={addPatternError}
                  onLastDayBlocked={() => setAddPatternError(PATTERN_ERROR)}
                />
                {addError && (
                  <p className="mt-2 text-xs text-red-600">{addError}</p>
                )}
                <div className="mt-3 flex gap-2">
                  <button
                    type="button"
                    disabled={addSaving}
                    onClick={submitAdd}
                    className="rounded-md bg-brand-600 px-3 py-1.5 text-sm font-medium text-white hover:bg-brand-700 disabled:opacity-50"
                  >
                    {addSaving ? "Adding…" : "Add truck"}
                  </button>
                  <button
                    type="button"
                    onClick={() => setShowAdd(false)}
                    className="rounded-md border border-slate-300 px-3 py-1.5 text-sm text-slate-600 hover:bg-slate-50"
                  >
                    Cancel
                  </button>
                </div>
              </div>
            ) : (
              <button
                type="button"
                onClick={() => setShowAdd(true)}
                className="w-full rounded-md border border-dashed border-slate-300 px-3 py-2 text-sm text-slate-600 hover:bg-slate-50"
              >
                + Add truck
              </button>
            )}
          </div>

          {/* Archived trucks */}
          {archivedTrucks.length > 0 && (
            <div className="mt-6">
              <button
                type="button"
                onClick={() => setShowArchived((v) => !v)}
                className="text-xs font-semibold uppercase tracking-wide text-slate-500 hover:text-slate-700"
              >
                Archived trucks ({archivedTrucks.length}){" "}
                {showArchived ? "▾" : "▸"}
              </button>
              {showArchived && (
                <div className="mt-2 space-y-2">
                  {archivedTrucks.map((t) => (
                    <div
                      key={t.id}
                      className="flex items-center justify-between rounded-lg border border-slate-200 bg-slate-50 px-3 py-2"
                    >
                      <div className="min-w-0">
                        <p className="truncate text-sm text-slate-600">
                          {t.name}
                        </p>
                        <p className="text-xs text-slate-400">
                          {t.default_stop_cap} stops/day
                        </p>
                      </div>
                      <button
                        type="button"
                        disabled={restoreSaving.has(t.id)}
                        onClick={() => restoreTruck(t.id)}
                        className="ml-2 shrink-0 rounded border border-slate-300 bg-white px-2 py-1 text-xs text-slate-600 hover:bg-slate-50 disabled:opacity-50"
                      >
                        {restoreSaving.has(t.id) ? "Restoring…" : "Restore"}
                      </button>
                    </div>
                  ))}
                </div>
              )}
            </div>
          )}

        </div>
      </aside>
    </div>
  );
}
