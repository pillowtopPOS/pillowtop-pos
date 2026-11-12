"use client";

import { Suspense, useCallback, useEffect, useMemo, useRef, useState } from "react";
import Link from "next/link";
import { useRouter, useSearchParams } from "next/navigation";
import { createClient } from "@/lib/supabase/client";
import Modal from "@/components/Modal";
import TempErrorBoundary from "@/components/TempErrorBoundary";
import DeliveryBookingModal from "@/components/delivery/DeliveryBookingModal";
import JourneyPeek from "@/components/delivery/JourneyPeek";
import {
  fetchDeliveryDayPlan,
  fetchDeliveryManageCalendar,
  fetchDeliveryDaySettings,
  fetchDeliverySetWindows,
  saveDeliveryDayRoute,
  setDeliveryStopWindows,
  closeDeliveryDay,
  reopenDeliveryDay,
  cancelDeliveryStop,
  type DeliveryDayPlan,
  type DeliveryDayPlanStop,
  type DeliveryDayPlanTruck,
  type DeliveryRouteStopInput,
  type DeliverySettings,
  type DeliveryStopWindowInput,
} from "@/lib/delivery/queries";
import {
  fillMissingWindows,
  minutesToLabel,
  minutesToTimeStr,
  suggestWindows,
  timeStrToMinutes,
  validateWindowDraft,
  windowLabel,
  windowSelectOptions,
} from "@/lib/delivery/windows";

const MONTHS = [
  "Jan", "Feb", "Mar", "Apr", "May", "Jun",
  "Jul", "Aug", "Sep", "Oct", "Nov", "Dec",
];

function dateLabel(iso: string): string {
  const d = new Date(`${iso}T00:00:00Z`);
  return `${MONTHS[d.getUTCMonth()]} ${d.getUTCDate()}, ${d.getUTCFullYear()}`;
}

// The on-screen draft: ordered stop lists per truck plus the unrouted
// bucket. Initialized from the RPC payload; every mutation marks dirty.
type Draft = {
  trucks: Record<string, DeliveryDayPlanStop[]>;
  unrouted: DeliveryDayPlanStop[];
};

function buildDraft(plan: DeliveryDayPlan): Draft {
  const trucks: Record<string, DeliveryDayPlanStop[]> = {};
  for (const t of plan.trucks) trucks[t.truck_id] = [];
  const routed = plan.stops
    .filter((s) => s.truck_id)
    .sort(
      (a, b) =>
        (a.route_position ?? 9999) - (b.route_position ?? 9999) ||
        a.booked_at.localeCompare(b.booked_at)
    );
  for (const s of routed) {
    const key = s.truck_id as string;
    (trucks[key] ??= []).push(s);
  }
  const unrouted = plan.stops
    .filter((s) => !s.truck_id)
    .sort((a, b) => a.booked_at.localeCompare(b.booked_at));
  return { trucks, unrouted };
}

function cloneDraft(d: Draft): Draft {
  const trucks: Record<string, DeliveryDayPlanStop[]> = {};
  for (const [k, v] of Object.entries(d.trucks)) trucks[k] = [...v];
  return { trucks, unrouted: [...d.unrouted] };
}

// Where a stop currently lives: [listKey, index]. listKey is a truck_id
// or null for the unrouted bucket.
function locateStop(
  d: Draft,
  stopId: string
): { key: string | null; index: number } | null {
  for (const [key, stops] of Object.entries(d.trucks)) {
    const i = stops.findIndex((s) => s.stop_id === stopId);
    if (i >= 0) return { key, index: i };
  }
  const i = d.unrouted.findIndex((s) => s.stop_id === stopId);
  if (i >= 0) return { key: null, index: i };
  return null;
}

function findStop(d: Draft, stopId: string): DeliveryDayPlanStop | null {
  for (const stops of Object.values(d.trucks)) {
    const s = stops.find((x) => x.stop_id === stopId);
    if (s) return s;
  }
  return d.unrouted.find((x) => x.stop_id === stopId) ?? null;
}

function removeStop(d: Draft, stopId: string): void {
  const loc = locateStop(d, stopId);
  if (!loc) return;
  const list = loc.key === null ? d.unrouted : d.trucks[loc.key];
  list.splice(loc.index, 1);
}

function pushStop(d: Draft, stop: DeliveryDayPlanStop, truckId: string | null): void {
  if (truckId === null) d.unrouted.push(stop);
  else (d.trucks[truckId] ??= []).push(stop);
}

function buildPayload(d: Draft): DeliveryRouteStopInput[] {
  const out: DeliveryRouteStopInput[] = [];
  for (const [truckId, stops] of Object.entries(d.trucks)) {
    stops.forEach((s, i) =>
      out.push({ stop_id: s.stop_id, truck_id: truckId, route_position: i + 1 })
    );
  }
  for (const s of d.unrouted) {
    out.push({ stop_id: s.stop_id, truck_id: null, route_position: null });
  }
  return out;
}

// Arrival-window editor choices: 6:00 AM to 10:00 PM in 15-minute steps.
const WINDOW_EDIT_OPTIONS = Array.from({ length: 65 }, (_, i) => 360 + i * 15);

// Unsaved window edits, keyed by stop_id. "HH:MM" strings or null;
// `suggested` marks machine-filled values not yet saved.
type WinDraftEntry = { start: string | null; end: string | null; suggested?: boolean };
type WinDraft = Record<string, WinDraftEntry>;

function savedWindow(s: DeliveryDayPlanStop): { start: string | null; end: string | null } {
  return {
    start: s.window_start ? s.window_start.slice(0, 5) : null,
    end: s.window_end ? s.window_end.slice(0, 5) : null,
  };
}

function sameWindow(
  a: { start: string | null; end: string | null },
  b: { start: string | null; end: string | null }
): boolean {
  return a.start === b.start && a.end === b.end;
}

type Warning = { kind: string; text: string };

function DeliveryDayInner() {
  const router = useRouter();
  const searchParams = useSearchParams();
  const date = searchParams.get("date") ?? "";

  const [plan, setPlan] = useState<DeliveryDayPlan | null>(null);
  const [draft, setDraft] = useState<Draft | null>(null);
  const [canManage, setCanManage] = useState(false);
  const [canSetWindows, setCanSetWindows] = useState(false);
  const [daySettings, setDaySettings] = useState<DeliverySettings | null>(null);
  const [winDraft, setWinDraft] = useState<WinDraft>({});
  const [winEditing, setWinEditing] = useState<string | null>(null);
  const [resuggestTruck, setResuggestTruck] = useState<string | null>(null);
  const [peekJourneyId, setPeekJourneyId] = useState<string | null>(null);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);
  const [actionError, setActionError] = useState<string | null>(null);
  const [conflict, setConflict] = useState(false);
  const [dirty, setDirty] = useState(false);
  const [busy, setBusy] = useState(false);
  const [suggestMsg, setSuggestMsg] = useState<string | null>(null);
  const [closeConfirm, setCloseConfirm] = useState(false);
  const [pendingNav, setPendingNav] = useState<string | null>(null);
  const [movingStop, setMovingStop] = useState<DeliveryDayPlanStop | null>(null);
  const [cancellingStop, setCancellingStop] = useState<DeliveryDayPlanStop | null>(null);
  const [cancelReason, setCancelReason] = useState("");
  const [cancelBusy, setCancelBusy] = useState(false);
  const [cancelError, setCancelError] = useState<string | null>(null);
  const [notice, setNotice] = useState<string | null>(null);
  const loadSeq = useRef(0);

  const validDate = /^\d{4}-\d{2}-\d{2}$/.test(date);

  const load = useCallback(async () => {
    if (!validDate) {
      setLoading(false);
      setError("Pick a delivery day.");
      return;
    }
    const seq = ++loadSeq.current;
    setLoading(true);
    setError(null);
    setActionError(null);
    setConflict(false);
    try {
      const [p, perm, permWin, settings] = await Promise.all([
        fetchDeliveryDayPlan(date),
        fetchDeliveryManageCalendar(),
        fetchDeliverySetWindows(),
        fetchDeliveryDaySettings(),
      ]);
      if (seq !== loadSeq.current) return;
      setPlan(p);
      setDraft(buildDraft(p));
      setCanManage(perm);
      setCanSetWindows(permWin);
      setDaySettings(settings);
      setWinDraft({});
      setWinEditing(null);
      setResuggestTruck(null);
      setDirty(false);
      setSuggestMsg(null);
      setNotice(null);
    } catch {
      if (seq !== loadSeq.current) return;
      setError("We couldn't load this delivery day. Please try again.");
      setPlan(null);
      setDraft(null);
    } finally {
      if (seq === loadSeq.current) setLoading(false);
    }
  }, [date, validDate]);

  useEffect(() => {
    const supabase = createClient();
    supabase.auth.getSession().then(({ data: { session } }) => {
      if (!session?.user) {
        router.push("/login");
        return;
      }
      load();
    });
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []);

  const isPast = !!plan && !!plan.today_local && date < plan.today_local;
  const isClosed = plan?.plan.status === "CLOSED";
  // Windows show only in 'window' day mode; day_only hides all of it.
  const showWindows =
    !!daySettings && daySettings.delivery_day_mode !== "day_only";
  // Window edits need set_windows OR manage_calendar, and work on CLOSED
  // days (the RPC supports it) but never on past days.
  const canEditWindows =
    (canSetWindows || canManage) && !isPast && showWindows;
  const winLenMin = Math.round(
    (daySettings?.delivery_window_hours ?? 3) * 60
  );
  const dayStartMin =
    timeStrToMinutes(daySettings?.delivery_day_start) ?? 0;
  const dayEndMin =
    timeStrToMinutes(daySettings?.delivery_day_end) ?? 24 * 60;
  // winDraft only ever holds real changes (equal values are removed on
  // write), so its size IS the unsaved-window-change count.
  const winDirtyCount = Object.keys(winDraft).length;

  // Unsaved-changes guard: browser unload + in-app anchor clicks.
  // Covers route AND window drafts.
  useEffect(() => {
    if (!(dirty || winDirtyCount > 0)) return;
    const onBeforeUnload = (e: BeforeUnloadEvent) => {
      e.preventDefault();
    };
    window.addEventListener("beforeunload", onBeforeUnload);
    const onClick = (e: MouseEvent) => {
      if (
        e.defaultPrevented ||
        e.button !== 0 ||
        e.metaKey ||
        e.ctrlKey ||
        e.shiftKey ||
        e.altKey
      )
        return;
      const a = (e.target as HTMLElement).closest("a[href]");
      if (!a) return;
      const href = a.getAttribute("href");
      if (!href || href.startsWith("#") || href.startsWith("mailto:")) return;
      const url = new URL(href, window.location.href);
      if (url.origin !== window.location.origin) return;
      if (url.pathname === "/delivery/day" && url.search === window.location.search)
        return;
      e.preventDefault();
      e.stopPropagation();
      setPendingNav(url.pathname + url.search + url.hash);
    };
    document.addEventListener("click", onClick, true);
    return () => {
      window.removeEventListener("beforeunload", onBeforeUnload);
      document.removeEventListener("click", onClick, true);
    };
  }, [dirty, winDirtyCount]);

  const canEdit = canManage && !isPast && !isClosed;
  // Move/cancel are exits, not route edits: allowed on a CLOSED day too.
  const canExit = canManage && !isPast;
  // A clean draft can still "save" once to clear the released-stops banner.
  const canMarkReviewed =
    canEdit && (plan?.released_after_review.length ?? 0) > 0;

  // Client-side window draft validation: both-or-neither and end after
  // start. Invalid drafts block Save (route and windows) but never the
  // draft itself; the database rules are unchanged.
  const invalidWinCount = useMemo(() => {
    if (!draft) return 0;
    let n = 0;
    for (const stops of [...Object.values(draft.trucks), draft.unrouted]) {
      for (const s of stops) {
        const e = winDraft[s.stop_id];
        if (e && validateWindowDraft(e.start, e.end)) n += 1;
      }
    }
    return n;
  }, [draft, winDraft]);

  // Truck columns: every truck from the plan plus any truck the draft
  // references that the plan didn't list (archived-after-assignment edge).
  const allTrucks = useMemo<DeliveryDayPlanTruck[]>(() => {
    if (!plan || !draft) return [];
    const out = [...plan.trucks];
    for (const key of Object.keys(draft.trucks)) {
      if (!out.some((t) => t.truck_id === key)) {
        out.push({
          truck_id: key,
          name: "Truck",
          stop_cap: draft.trucks[key]?.length ?? 0,
          on: true,
          assigned_off: false,
        });
      }
    }
    return out;
  }, [plan, draft]);

  // Counts and warnings derive from the CURRENT draft every render.
  const warnings = useMemo<Warning[]>(() => {
    if (!plan || !draft) return [];
    const w: Warning[] = [];
    for (const t of allTrucks) {
      const n = draft.trucks[t.truck_id]?.length ?? 0;
      if (!t.on && n > 0) {
        w.push({
          kind: "off-truck",
          text: `${t.name} is off for this day but has ${n} stop${n === 1 ? "" : "s"}. Turn it on, move the stops, or add a spot.`,
        });
      } else if (t.on && n > t.stop_cap) {
        w.push({
          kind: "over-cap",
          text: `${t.name} has ${n} stops, its cap is ${t.stop_cap}.`,
        });
      } else if (t.on && n === 0) {
        w.push({
          kind: "no-stops",
          text: `${t.name} has no stops yet.`,
        });
      }
    }
    if (draft.unrouted.length > 0) {
      w.push({
        kind: "unrouted",
        text: `${draft.unrouted.length} stop${draft.unrouted.length === 1 ? " is" : "s are"} not on a truck yet.`,
      });
    }
    if (plan.booked_count > plan.capacity) {
      w.push({
        kind: "over-capacity",
        text: `${plan.booked_count} orders are booked but this day only has capacity for ${plan.capacity}.`,
      });
    }
    return w;
  }, [plan, draft, allTrucks]);

  const mutate = (fn: (d: Draft) => void) => {
    setDraft((prev) => {
      if (!prev) return prev;
      const next = cloneDraft(prev);
      fn(next);
      return next;
    });
    setDirty(true);
    setSuggestMsg(null);
  };

  const moveStop = (stopId: string, dir: -1 | 1) => {
    mutate((d) => {
      const loc = locateStop(d, stopId);
      if (!loc) return;
      const list = loc.key === null ? d.unrouted : d.trucks[loc.key];
      const j = loc.index + dir;
      if (j < 0 || j >= list.length) return;
      [list[loc.index], list[j]] = [list[j], list[loc.index]];
    });
  };

  const setStopTruck = (stopId: string, truckId: string | null) => {
    mutate((d) => {
      const stop = findStop(d, stopId);
      if (!stop) return;
      removeStop(d, stopId);
      pushStop(d, stop, truckId);
    });
  };

  // Draft-only suggestion: unrouted stops sorted by zip then booked
  // order fill each ON truck's remaining room in contiguous blocks.
  // Stops already on a truck in the draft never move. Never saves.
  const applySuggestion = () => {
    if (!draft || busy) return;
    const d = cloneDraft(draft);
    const sorted = [...d.unrouted].sort((a, b) => {
      if (a.zip_code == null && b.zip_code == null)
        return a.booked_at.localeCompare(b.booked_at);
      if (a.zip_code == null) return 1;
      if (b.zip_code == null) return -1;
      return (
        a.zip_code.localeCompare(b.zip_code) ||
        a.booked_at.localeCompare(b.booked_at)
      );
    });
    let idx = 0;
    let moved = 0;
    for (const t of allTrucks) {
      if (!t.on) continue;
      const room = Math.max(0, t.stop_cap - (d.trucks[t.truck_id]?.length ?? 0));
      const take = sorted.slice(idx, idx + room);
      idx += take.length;
      for (const s of take) {
        removeStop(d, s.stop_id);
        pushStop(d, s, t.truck_id);
        moved += 1;
      }
    }
    d.unrouted = sorted.slice(idx);
    setDraft(d);
    if (moved > 0) setDirty(true);
    setSuggestMsg(
      moved > 0
        ? "Rough grouping by zip — review it before saving."
        : "No unrouted stops fit on the trucks — nothing changed."
    );
  };

  // ---- arrival window draft -------------------------------------------
  // winDraft holds ONLY unsaved changes; a value equal to the stop's
  // saved window removes the entry, so the draft size is the change count.

  const winValue = (s: DeliveryDayPlanStop): WinDraftEntry =>
    winDraft[s.stop_id] ?? { ...savedWindow(s) };

  const setWinEntry = (
    stop: DeliveryDayPlanStop,
    start: string | null,
    end: string | null,
    suggested = false
  ) => {
    setWinDraft((prev) => {
      const next = { ...prev };
      const entry = { start, end, suggested };
      if (sameWindow(entry, savedWindow(stop))) delete next[stop.stop_id];
      else next[stop.stop_id] = entry;
      return next;
    });
  };

  // Per-stop inline edit. Picking a start auto-fills the end at the
  // company window length; the person can still change the end.
  const editWinStart = (stop: DeliveryDayPlanStop, startHHMM: string) => {
    const startMin = timeStrToMinutes(startHHMM);
    if (startMin === null) return;
    const endMin = Math.min(
      startMin + winLenMin,
      WINDOW_EDIT_OPTIONS[WINDOW_EDIT_OPTIONS.length - 1]
    );
    setWinEntry(stop, startHHMM, minutesToTimeStr(Math.max(360, endMin)));
  };

  const editWinEnd = (stop: DeliveryDayPlanStop, endHHMM: string) => {
    if (!endHHMM) return;
    const cur = winValue(stop);
    setWinEntry(stop, cur.start, endHHMM);
  };

  const clearWin = (stop: DeliveryDayPlanStop) => {
    setWinEntry(stop, null, null);
    setWinEditing(null);
  };

  // Suggest windows for one truck's stops, in route order. Only fills
  // stops that currently have no window; spacing is computed over ALL
  // stops on the truck so hand-set windows keep their place.
  const applyTruckWindows = (truckId: string, all = false) => {
    if (!draft || !daySettings || busy) return;
    const stops = draft.trucks[truckId] ?? [];
    if (stops.length === 0) return;
    const dStart = timeStrToMinutes(daySettings.delivery_day_start) ?? 0;
    const dEnd = timeStrToMinutes(daySettings.delivery_day_end) ?? 24 * 60;
    const current = stops.map((s) => {
      const w = winValue(s);
      const sm = timeStrToMinutes(w.start);
      const em = timeStrToMinutes(w.end);
      return sm !== null && em !== null ? { start: sm, end: em } : null;
    });
    const filled = all
      ? stops.map((_, i) =>
          suggestWindows(stops.length, dStart, dEnd, winLenMin)[i]
        )
      : fillMissingWindows(current, dStart, dEnd, winLenMin);
    setWinDraft((prev) => {
      const next = { ...prev };
      stops.forEach((s, i) => {
        const sug = filled[i];
        if (!sug) return;
        const entry = {
          start: minutesToTimeStr(sug.start),
          end: minutesToTimeStr(sug.end),
          suggested: true,
        };
        if (sameWindow(entry, savedWindow(s))) delete next[s.stop_id];
        else next[s.stop_id] = entry;
      });
      return next;
    });
  };

  const isConflict = (e: unknown) =>
    /changed by someone else/i.test((e as Error)?.message ?? "");

  const winSaveItems = (): DeliveryStopWindowInput[] => {
    if (!draft) return [];
    const live = new Set(
      [...Object.values(draft.trucks).flat(), ...draft.unrouted].map(
        (s) => s.stop_id
      )
    );
    return Object.entries(winDraft)
      .filter(([id]) => live.has(id))
      .map(([id, w]) => ({
        stop_id: id,
        window_start: w.start,
        window_end: w.end,
      }));
  };

  const doSave = async () => {
    if (!plan || !draft || busy || invalidWinCount > 0) return;
    const items = winSaveItems();
    // canMarkReviewed keeps the old "save a clean draft to clear the
    // released-stops banner" path working through the same button.
    const doRoute = canEdit && (dirty || canMarkReviewed);
    const doWindows = items.length > 0 && canEditWindows;
    if (!doRoute && !doWindows) return;
    setBusy(true);
    setActionError(null);
    setNotice(null);
    let routeNote = "";
    let winNote = "";
    try {
      if (doRoute) {
        try {
          await saveDeliveryDayRoute(date, plan.plan.version, buildPayload(draft));
          routeNote = "Route saved.";
        } catch (e) {
          if (isConflict(e)) {
            setConflict(true);
            return;
          }
          throw e;
        }
      }
      if (doWindows) {
        try {
          const n = await setDeliveryStopWindows(date, items);
          winNote = n > 0 ? `Windows saved (${n} stop${n === 1 ? "" : "s"}).` : "No window changes to save.";
          setWinDraft({});
          setWinEditing(null);
        } catch (e) {
          // Route may already be saved: reload to show it, keep the
          // window draft, and report both results separately.
          const msg = (e as Error)?.message ?? "Couldn't save the windows. Please try again.";
          winNote = routeNote
            ? `Windows were not saved: ${msg}`
            : msg;
          const keepWin = winDraft;
          await load();
          setWinDraft(keepWin);
          setActionError(routeNote ? `${routeNote} ${winNote}` : winNote);
          return;
        }
      }
      await load();
      if (routeNote || winNote) setNotice([routeNote, winNote].filter(Boolean).join(" "));
    } catch (e) {
      setActionError(
        routeNote
          ? `${routeNote} ${(e as Error)?.message ?? "Couldn't save. Please try again."}`
          : ((e as Error)?.message ?? "Couldn't save. Please try again.")
      );
      if (routeNote) {
        // Route landed; refresh so the screen matches, keep drafts.
        const keepWin = winDraft;
        await load();
        setWinDraft(keepWin);
      }
    } finally {
      setBusy(false);
    }
  };

  const discardChanges = () => {
    if (!plan) return;
    setDraft(buildDraft(plan));
    setWinDraft({});
    setWinEditing(null);
    setDirty(false);
    setResuggestTruck(null);
  };

  const doClose = async () => {
    if (!plan || !draft || busy) return;
    setBusy(true);
    setActionError(null);
    setCloseConfirm(false);
    // A dirty draft is saved first — closing must never discard unsaved
    // route work. The close then uses the version save returned.
    let saved = false;
    try {
      const version = dirty
        ? await saveDeliveryDayRoute(date, plan.plan.version, buildPayload(draft))
        : plan.plan.version;
      saved = dirty;
      await closeDeliveryDay(date, version);
      await load();
    } catch (e) {
      if (isConflict(e)) {
        setConflict(true);
      } else {
        const msg =
          (e as Error)?.message ?? "Couldn't close the day. Please try again.";
        if (saved) {
          // The route save already landed — reload so the screen shows
          // the saved state, then surface the close error.
          await load();
        }
        setActionError(msg);
      }
    } finally {
      setBusy(false);
    }
  };

  const doReopen = async () => {
    if (!plan || busy) return;
    setBusy(true);
    setActionError(null);
    try {
      await reopenDeliveryDay(date, plan.plan.version);
      await load();
    } catch (e) {
      if (isConflict(e)) setConflict(true);
      else setActionError((e as Error)?.message ?? "Couldn't reopen the day. Please try again.");
    } finally {
      setBusy(false);
    }
  };

  // After a stop leaves this day (cancelled or moved away): drop it from
  // the draft but keep every other unsaved change and the dirty flag.
  // The plan is refetched so version/counts/warnings/banner stay right —
  // a dirty draft must never be thrown away by a full load().
  const afterStopRemoved = async (stopId: string, msg: string) => {
    // A gone stop must not linger in the window draft — the windows RPC
    // would reject its id on save.
    setWinDraft((prev) => {
      if (!(stopId in prev)) return prev;
      const next = { ...prev };
      delete next[stopId];
      return next;
    });
    setWinEditing((cur) => (cur === stopId ? null : cur));
    // Full reload only when nothing else is unsaved; window drafts for
    // other stops must survive a stop leaving the day.
    if (!dirty && winDirtyCount === 0) {
      await load();
      setNotice(msg);
      return;
    }
    try {
      const p = await fetchDeliveryDayPlan(date);
      setPlan(p);
      setDraft((prev) => {
        if (!prev) return prev;
        const next = cloneDraft(prev);
        removeStop(next, stopId);
        return next;
      });
      setNotice(msg);
    } catch {
      setActionError("The delivery changed but the plan couldn't refresh. Reload to see the latest.");
    }
  };

  const submitCancel = async () => {
    if (!cancellingStop || !cancelReason.trim() || cancelBusy) return;
    setCancelBusy(true);
    setCancelError(null);
    try {
      await cancelDeliveryStop(cancellingStop.stop_id, cancelReason.trim());
      const stopId = cancellingStop.stop_id;
      setCancellingStop(null);
      setCancelReason("");
      await afterStopRemoved(stopId, "Delivery cancelled.");
    } catch (e) {
      setCancelError(
        (e as Error)?.message ?? "Couldn't cancel the delivery. Please try again."
      );
    } finally {
      setCancelBusy(false);
    }
  };

  const requestClose = () => {
    if (warnings.length > 0) setCloseConfirm(true);
    else doClose();
  };

  const stopRow = (s: DeliveryDayPlanStop, listKey: string | null, index: number, listLen: number) => {
    const editable = canEdit && !busy;
    return (
      <div
        key={s.stop_id}
        data-testid={`delivery-day-stop-${s.stop_id}`}
        className="flex gap-3 border-b border-slate-100 px-3 py-2 last:border-b-0"
      >
        <span className="w-6 shrink-0 pt-0.5 text-center text-xs font-semibold text-slate-400">
          {index + 1}
        </span>
        <div className="min-w-0 flex-1">
          <div className="flex flex-wrap items-center gap-x-2 gap-y-0.5">
            <button
              type="button"
              data-testid={`delivery-day-journey-${s.journey_id}`}
              onClick={() => setPeekJourneyId(s.journey_id)}
              className="text-sm font-medium text-blue-700 hover:underline"
            >
              {s.journey_number ?? "Order"}
            </button>
            <span className="text-sm text-slate-800">{s.customer_name}</span>
            {s.inside_cutoff && (
              <span className="rounded bg-amber-100 px-1.5 py-0.5 text-[11px] font-medium text-amber-800">
                Inside cutoff
              </span>
            )}
          </div>
          <div className="text-xs text-slate-500">
            {s.delivery_address ?? "No address"}
            {s.phone ? ` · ${s.phone}` : ""}
            {s.booked_by_name ? ` · booked by ${s.booked_by_name}` : ""}
          </div>
          {showWindows &&
            (() => {
              const w = winValue(s);
              const wStart = timeStrToMinutes(w.start);
              const wEnd = timeStrToMinutes(w.end);
              const hasWin = wStart !== null && wEnd !== null;
              const outside =
                hasWin && (wStart < dayStartMin || wEnd > dayEndMin);
              const canEditWin = canEditWindows && !busy;
              const problem = winDraft[s.stop_id]
                ? validateWindowDraft(w.start, w.end)
                : null;
              if (winEditing === s.stop_id && canEditWin) {
                return (
                  <div
                    data-testid={`delivery-day-window-editor-${s.stop_id}`}
                    className="mt-1 flex flex-wrap items-center gap-1.5 text-xs"
                  >
                    <select
                      data-testid={`delivery-day-window-start-${s.stop_id}`}
                      value={w.start ?? ""}
                      onChange={(e) => editWinStart(s, e.target.value)}
                      className="rounded border border-slate-300 px-1.5 py-1 text-xs text-slate-700"
                    >
                      <option value="">Start</option>
                      {windowSelectOptions(w.start).map((m) => (
                        <option key={m} value={minutesToTimeStr(m)}>
                          {minutesToLabel(m)}
                        </option>
                      ))}
                    </select>
                    <span className="text-slate-400">to</span>
                    <select
                      data-testid={`delivery-day-window-end-${s.stop_id}`}
                      value={w.end ?? ""}
                      onChange={(e) => editWinEnd(s, e.target.value)}
                      className="rounded border border-slate-300 px-1.5 py-1 text-xs text-slate-700"
                    >
                      <option value="">End</option>
                      {windowSelectOptions(w.end).map((m) => (
                        <option key={m} value={minutesToTimeStr(m)}>
                          {minutesToLabel(m)}
                        </option>
                      ))}
                    </select>
                    <button
                      type="button"
                      data-testid={`delivery-day-window-clear-${s.stop_id}`}
                      onClick={() => clearWin(s)}
                      className="rounded border border-slate-300 px-2 py-1 text-xs text-slate-600 hover:bg-slate-50"
                    >
                      Clear
                    </button>
                    <button
                      type="button"
                      data-testid={`delivery-day-window-done-${s.stop_id}`}
                      onClick={() => setWinEditing(null)}
                      className="rounded border border-slate-300 px-2 py-1 text-xs text-slate-600 hover:bg-slate-50"
                    >
                      Done
                    </button>
                    {problem === "end_not_after_start" && (
                      <span className="text-red-600">
                        End must be after the start.
                      </span>
                    )}
                    {problem === "incomplete" && (
                      <span className="text-red-600">
                        Pick both a start and an end, or clear the window.
                      </span>
                    )}
                  </div>
                );
              }
              return (
                <div className="mt-0.5 flex flex-wrap items-center gap-x-2 gap-y-0.5 text-xs">
                  {canEditWin ? (
                    <button
                      type="button"
                      data-testid={`delivery-day-window-${s.stop_id}`}
                      onClick={() => setWinEditing(s.stop_id)}
                      className="text-left text-slate-600 underline decoration-dotted decoration-slate-300 underline-offset-2 hover:text-slate-900"
                    >
                      {hasWin ? windowLabel(wStart, wEnd) : "No window yet"}
                    </button>
                  ) : (
                    <span
                      data-testid={`delivery-day-window-${s.stop_id}`}
                      className={hasWin ? "text-slate-600" : "text-slate-400"}
                    >
                      {hasWin ? windowLabel(wStart, wEnd) : "No window yet"}
                    </span>
                  )}
                  {hasWin && w.suggested && (
                    <span className="rounded bg-blue-50 px-1.5 py-0.5 text-[11px] font-medium text-blue-700">
                      Suggested, not saved yet
                    </span>
                  )}
                  {outside && (
                    <span className="rounded bg-amber-100 px-1.5 py-0.5 text-[11px] font-medium text-amber-800">
                      Outside driver hours
                    </span>
                  )}
                  {problem === "end_not_after_start" && (
                    <span className="text-red-600">
                      End must be after the start.
                    </span>
                  )}
                  {problem === "incomplete" && (
                    <span className="text-red-600">
                      Pick both a start and an end, or clear the window.
                    </span>
                  )}
                </div>
              );
            })()}
          {(editable || canExit) && (
            <div className="mt-1 flex flex-col gap-1 sm:flex-row sm:flex-wrap sm:items-center sm:gap-x-2">
              {editable && (
                <>
                  <div className="flex items-center gap-1">
                    <button
                      type="button"
                      data-testid={`delivery-day-up-${s.stop_id}`}
                      disabled={index === 0}
                      onClick={() => moveStop(s.stop_id, -1)}
                      className="rounded border border-slate-300 px-2 py-1 text-xs text-slate-600 hover:bg-slate-50 disabled:opacity-40"
                    >
                      Up
                    </button>
                    <button
                      type="button"
                      data-testid={`delivery-day-down-${s.stop_id}`}
                      disabled={index === listLen - 1}
                      onClick={() => moveStop(s.stop_id, 1)}
                      className="rounded border border-slate-300 px-2 py-1 text-xs text-slate-600 hover:bg-slate-50 disabled:opacity-40"
                    >
                      Down
                    </button>
                  </div>
                  <select
                    data-testid={`delivery-day-truck-select-${s.stop_id}`}
                    value={listKey ?? ""}
                    onChange={(e) => setStopTruck(s.stop_id, e.target.value || null)}
                    className="w-full rounded border border-slate-300 px-2 py-1 text-xs text-slate-700 sm:w-32"
                  >
                    <option value="">Unrouted</option>
                    {allTrucks.map((t) => (
                      <option key={t.truck_id} value={t.truck_id}>
                        {t.name}
                      </option>
                    ))}
                  </select>
                </>
              )}
              {canExit && (
                <div className="flex items-center gap-3">
                  <button
                    type="button"
                    data-testid={`delivery-day-move-${s.stop_id}`}
                    onClick={() => setMovingStop(s)}
                    className="text-xs text-slate-500 hover:text-slate-800 hover:underline"
                  >
                    Move to another day
                  </button>
                  <button
                    type="button"
                    data-testid={`delivery-day-cancel-${s.stop_id}`}
                    onClick={() => {
                      setCancellingStop(s);
                      setCancelReason("");
                      setCancelError(null);
                    }}
                    className="text-xs text-slate-500 hover:text-red-700 hover:underline"
                  >
                    Cancel delivery
                  </button>
                </div>
              )}
            </div>
          )}
        </div>
      </div>
    );
  };

  return (
    <div className="mx-auto max-w-6xl px-4 py-6" data-testid="delivery-day-page">
      <div className="mb-4">
        <Link
          href="/delivery"
          className="text-sm text-blue-700 hover:underline"
        >
          ← Delivery calendar
        </Link>
      </div>

      {loading && (
        <p className="py-10 text-center text-sm text-slate-500">Loading…</p>
      )}

      {!loading && error && (
        <div
          data-testid="delivery-day-error"
          className="rounded-lg border border-red-200 bg-red-50 px-4 py-6 text-center"
        >
          <p className="text-sm text-red-700">{error}</p>
          <button
            onClick={load}
            data-testid="delivery-day-reload"
            className="mt-3 rounded-md border border-red-300 px-3 py-1.5 text-sm text-red-700 hover:bg-red-100"
          >
            Try again
          </button>
        </div>
      )}

      {!loading && !error && plan && draft && (
        <>
          {/* Header */}
          <div className="mb-4 flex flex-wrap items-center gap-x-4 gap-y-2">
            <h1 className="text-xl font-semibold text-slate-900">
              {dateLabel(date)}
            </h1>
            <span
              data-testid="delivery-day-status"
              className={`rounded-full px-2.5 py-0.5 text-xs font-medium ${
                isClosed
                  ? "bg-slate-200 text-slate-700"
                  : "bg-green-100 text-green-800"
              }`}
            >
              {isClosed ? "Closed" : "Open"}
            </span>
            {isClosed && plan.plan.closed_by_name && (
              <span className="text-sm text-slate-500">
                Closed by {plan.plan.closed_by_name}
              </span>
            )}
            <span className="text-sm text-slate-600">
              {plan.booked_count} of {plan.capacity} booked
            </span>
            {dirty && (
              <span className="text-sm font-medium text-amber-700">
                Unsaved changes
              </span>
            )}
          </div>

          {isPast && (
            <p
              data-testid="delivery-day-readonly"
              className="mb-3 rounded-md border border-slate-200 bg-slate-50 px-3 py-2 text-sm text-slate-600"
            >
              This is a past day — it is read only.
            </p>
          )}
          {isClosed && (
            <p
              data-testid="delivery-day-readonly"
              className="mb-3 rounded-md border border-slate-200 bg-slate-50 px-3 py-2 text-sm text-slate-600"
            >
              This day is closed. Reopen it to change the route.
            </p>
          )}
          {!isPast && !isClosed && !canManage && !canEditWindows && (
            <p
              data-testid="delivery-day-readonly"
              className="mb-3 rounded-md border border-slate-200 bg-slate-50 px-3 py-2 text-sm text-slate-600"
            >
              You can view this plan but not change it.
            </p>
          )}

          {notice && (
            <p
              data-testid="delivery-day-notice"
              className="mb-3 rounded-md border border-green-300 bg-green-50 px-3 py-2 text-sm text-green-800"
            >
              {notice}
            </p>
          )}

          {/* Released-after-review banner */}
          {plan.released_after_review.length > 0 && (
            <div
              data-testid="delivery-day-released"
              className="mb-3 rounded-md border border-amber-300 bg-amber-50 px-3 py-2 text-sm text-amber-900"
            >
              <p className="mb-1 font-medium">Stops released after this day was last reviewed:</p>
              <ul className="list-disc pl-5">
                {plan.released_after_review.map((r) => (
                  <li key={r.stop_id}>
                    {r.customer_name} ({r.journey_number ?? "order"}){" "}
                    {r.reason_kind === "moved"
                      ? `was moved to ${r.moved_to_date ?? "another day"}.`
                      : `was released${r.cancel_reason ? `: ${r.cancel_reason}` : "."}`}
                  </li>
                ))}
              </ul>
            </div>
          )}

          {/* Warnings — warn only, never block */}
          {warnings.length > 0 && (
            <div className="mb-3 space-y-1">
              {warnings.map((w, i) => (
                <p
                  key={`${w.kind}-${i}`}
                  data-testid={`delivery-day-warning-${w.kind}`}
                  className={`rounded-md border px-3 py-2 text-sm ${
                    w.kind === "no-stops"
                      ? "border-slate-200 bg-slate-50 text-slate-600"
                      : "border-amber-300 bg-amber-50 text-amber-900"
                  }`}
                >
                  {w.text}
                </p>
              ))}
            </div>
          )}

          {suggestMsg && canEdit && (
            <p
              className={`mb-3 rounded-md border px-3 py-2 text-sm ${
                suggestMsg.startsWith("No ")
                  ? "border-slate-200 bg-slate-50 text-slate-600"
                  : "border-blue-200 bg-blue-50 text-blue-800"
              }`}
            >
              {suggestMsg}
            </p>
          )}

          {conflict && (
            <div
              data-testid="delivery-day-error"
              className="mb-3 flex flex-wrap items-center gap-3 rounded-md border border-red-300 bg-red-50 px-3 py-2 text-sm text-red-800"
            >
              <span>This day was changed by someone else. Reload and try again.</span>
              <button
                type="button"
                data-testid="delivery-day-reload"
                onClick={load}
                className="rounded-md border border-red-300 px-2.5 py-1 text-xs font-medium text-red-700 hover:bg-red-100"
              >
                Reload
              </button>
            </div>
          )}

          {actionError && !conflict && (
            <p
              data-testid="delivery-day-error"
              className="mb-3 rounded-md border border-red-300 bg-red-50 px-3 py-2 text-sm text-red-800"
            >
              {actionError}
            </p>
          )}

          {/* Empty / no-trucks states */}
          {plan.stops.length === 0 ? (
            <p className="rounded-lg border border-dashed border-slate-300 bg-white px-6 py-10 text-center text-sm text-slate-600">
              No deliveries are booked for this day.
            </p>
          ) : allTrucks.length === 0 ? (
            <p className="mb-3 rounded-md border border-slate-200 bg-slate-50 px-3 py-2 text-sm text-slate-600">
              No delivery trucks are on for this date.
            </p>
          ) : null}

          {/* Truck columns + unrouted */}
          {plan.stops.length > 0 && (
            <div className="grid grid-cols-1 gap-3 lg:grid-cols-2">
              {allTrucks.map((t) => {
                const stops = draft.trucks[t.truck_id] ?? [];
                const over = t.on && stops.length > t.stop_cap;
                return (
                  <div
                    key={t.truck_id}
                    data-testid={`delivery-day-truck-${t.truck_id}`}
                    className={`rounded-lg border bg-white ${
                      over ? "border-red-300" : "border-slate-200"
                    }`}
                  >
                    <div className="flex items-center justify-between border-b border-slate-100 px-3 py-2">
                      <span className="text-sm font-semibold text-slate-800">
                        {t.name}
                      </span>
                      <span className="flex items-center gap-2">
                      {showWindows && canEditWindows && stops.length > 0 && (
                        <span className="flex items-center gap-1">
                          <button
                            type="button"
                            data-testid={`delivery-day-win-suggest-${t.truck_id}`}
                            disabled={busy}
                            onClick={() => applyTruckWindows(t.truck_id, false)}
                            className="rounded border border-slate-300 px-1.5 py-0.5 text-[11px] text-slate-600 hover:bg-slate-50 disabled:opacity-50"
                          >
                            Suggest windows
                          </button>
                          <button
                            type="button"
                            data-testid={`delivery-day-win-resuggest-${t.truck_id}`}
                            disabled={busy}
                            onClick={() => setResuggestTruck(t.truck_id)}
                            className="rounded border border-slate-300 px-1.5 py-0.5 text-[11px] text-slate-500 hover:bg-slate-50 disabled:opacity-50"
                          >
                            Re-suggest all
                          </button>
                        </span>
                      )}
                      <span
                        className={`text-xs ${
                          over ? "font-medium text-red-700" : "text-slate-500"
                        }`}
                      >
                        {stops.length} of {t.stop_cap} stops
                        {!t.on && (
                          <span className="ml-2 rounded bg-slate-200 px-1.5 py-0.5 text-[11px] font-medium text-slate-700">
                            OFF
                          </span>
                        )}
                      </span>
                      </span>
                    </div>
                    {stops.length === 0 ? (
                      <p className="px-3 py-4 text-xs text-slate-400">
                        No stops on this truck.
                      </p>
                    ) : (
                      stops.map((s, i) => stopRow(s, t.truck_id, i, stops.length))
                    )}
                  </div>
                );
              })}

              <div
                data-testid="delivery-day-unrouted"
                className="rounded-lg border border-slate-200 bg-white"
              >
                <div className="flex items-center justify-between border-b border-slate-100 px-3 py-2">
                  <span className="text-sm font-semibold text-slate-800">
                    Unrouted
                  </span>
                  <span className="text-xs text-slate-500">
                    {draft.unrouted.length} stop{draft.unrouted.length === 1 ? "" : "s"}
                  </span>
                </div>
                {draft.unrouted.length === 0 ? (
                  <p className="px-3 py-4 text-xs text-slate-400">
                    Every stop is on a truck.
                  </p>
                ) : (
                  draft.unrouted.map((s, i) => stopRow(s, null, i, draft.unrouted.length))
                )}
              </div>
            </div>
          )}

          {/* Actions — one save bar covering route and window drafts.
              Windows stay editable on a CLOSED day; route controls do not. */}
          {(canManage || canEditWindows) && !isPast && (
            <div className="mt-4 flex flex-wrap items-center gap-2">
              {canEdit && (
                <button
                  type="button"
                  data-testid="delivery-day-suggest"
                  onClick={applySuggestion}
                  disabled={busy}
                  className="rounded-md border border-slate-300 px-3 py-1.5 text-sm text-slate-700 hover:bg-slate-50 disabled:opacity-50"
                >
                  Suggest assignments
                </button>
              )}
              {(dirty || winDirtyCount > 0 || (canManage && canMarkReviewed)) && (
                <>
                  {(dirty || winDirtyCount > 0) && (
                    <span
                      data-testid="delivery-day-unsaved-label"
                      className="text-sm text-slate-600"
                    >
                      {invalidWinCount > 0
                        ? "Fix the windows marked in red to save"
                        : dirty && winDirtyCount > 0
                          ? `Unsaved route changes and ${winDirtyCount} window change${winDirtyCount === 1 ? "" : "s"}`
                          : dirty
                            ? "Unsaved route changes"
                            : `${winDirtyCount} window change${winDirtyCount === 1 ? "" : "s"}`}
                    </span>
                  )}
                  <button
                    type="button"
                    data-testid="delivery-day-save"
                    onClick={doSave}
                    disabled={busy || invalidWinCount > 0}
                    className="rounded-md bg-slate-900 px-3 py-1.5 text-sm font-medium text-white disabled:opacity-40"
                  >
                    {dirty && winDirtyCount > 0
                      ? "Save route and windows"
                      : dirty
                        ? "Save route"
                        : canMarkReviewed && !dirty && winDirtyCount === 0
                          ? "Mark reviewed"
                          : "Save windows"}
                  </button>
                  {(dirty || winDirtyCount > 0) && (
                    <button
                      type="button"
                      data-testid="delivery-day-discard"
                      onClick={discardChanges}
                      disabled={busy}
                      className="rounded-md border border-slate-300 px-3 py-1.5 text-sm text-slate-700 hover:bg-slate-50 disabled:opacity-50"
                    >
                      Discard
                    </button>
                  )}
                </>
              )}
              {canManage && (!isClosed ? (
                <button
                  type="button"
                  data-testid="delivery-day-close"
                  onClick={requestClose}
                  disabled={busy}
                  className="rounded-md border border-slate-300 px-3 py-1.5 text-sm text-slate-700 hover:bg-slate-50 disabled:opacity-50"
                >
                  Close day
                </button>
              ) : (
                <button
                  type="button"
                  data-testid="delivery-day-reopen"
                  onClick={doReopen}
                  disabled={busy}
                  className="rounded-md border border-slate-300 px-3 py-1.5 text-sm text-slate-700 hover:bg-slate-50 disabled:opacity-50"
                >
                  Reopen day
                </button>
              ))}
            </div>
          )}
        </>
      )}

      {/* Read-only journey peek — opening/closing never touches drafts
          and never triggers the unsaved-changes guard (button, not link). */}
      {peekJourneyId && (
        <JourneyPeek
          journeyId={peekJourneyId}
          onClose={() => setPeekJourneyId(null)}
        />
      )}

      {/* Leave-page discard confirm */}
      {pendingNav && (
        <Modal onClose={() => setPendingNav(null)}>
          <div className="w-full max-w-xs rounded-lg border border-slate-200 bg-white p-5 shadow-lg">
            <h2 className="mb-2 text-base font-semibold text-slate-900">
              Discard changes?
            </h2>
            <p className="text-sm text-slate-600">
              You have unsaved changes for this day.
            </p>
            <div className="mt-4 flex gap-2">
              <button
                onClick={() => {
                  const href = pendingNav;
                  setPendingNav(null);
                  setDirty(false);
                  setWinDraft({});
                  setWinEditing(null);
                  router.push(href);
                }}
                className="flex-1 rounded-md bg-red-600 px-3 py-2 text-sm font-medium text-white hover:bg-red-700"
              >
                Discard changes
              </button>
              <button
                onClick={() => setPendingNav(null)}
                className="flex-1 rounded-md border border-slate-300 bg-white px-3 py-2 text-sm font-medium text-slate-700 hover:bg-slate-50"
              >
                Keep editing
              </button>
            </div>
          </div>
        </Modal>
      )}

      {/* Move-to-another-day: reuses the booking modal in reschedule mode */}
      {movingStop && (
        <DeliveryBookingModal
          journeyId={movingStop.journey_id}
          customerName={movingStop.customer_name ?? ""}
          journeyNumber={movingStop.journey_number}
          deliveryAddress={movingStop.delivery_address}
          mode="reschedule"
          stopId={movingStop.stop_id}
          currentDate={date}
          onClose={() => setMovingStop(null)}
          onDone={async () => {
            const stopId = movingStop.stop_id;
            setMovingStop(null);
            await afterStopRemoved(stopId, "Delivery moved.");
          }}
        />
      )}

      {/* Cancel delivery — same wording as the order panel's cancel window */}
      {cancellingStop && (
        <Modal onClose={() => setCancellingStop(null)}>
          <div
            data-testid="delivery-day-cancel-modal"
            className="w-full max-w-md rounded-lg border border-slate-200 bg-white p-5 shadow-lg"
          >
            <h2 className="text-lg font-semibold text-slate-900">
              Cancel delivery
            </h2>
            <p className="mt-1 text-sm text-slate-600">
              {cancellingStop.customer_name}
              {cancellingStop.journey_number
                ? ` · ${cancellingStop.journey_number}`
                : ""}
              {` · ${dateLabel(date)}`}
            </p>
            <label
              htmlFor="day-cancel-reason"
              className="mt-3 block text-sm font-medium text-slate-700"
            >
              Reason for cancelling
            </label>
            <textarea
              id="day-cancel-reason"
              data-testid="delivery-day-cancel-reason"
              value={cancelReason}
              onChange={(e) => setCancelReason(e.target.value)}
              rows={3}
              className="mt-1 w-full rounded-md border border-slate-300 px-3 py-2 text-sm focus:border-brand-500 focus:outline-none focus:ring-1 focus:ring-brand-500"
              placeholder="Why is this delivery being cancelled?"
            />
            {cancelError && (
              <p className="mt-2 text-sm text-red-600">{cancelError}</p>
            )}
            <div className="mt-4 flex gap-2">
              <button
                type="button"
                data-testid="delivery-day-cancel-dismiss"
                onClick={() => setCancellingStop(null)}
                disabled={cancelBusy}
                className="flex-1 rounded-md border border-slate-300 bg-white px-3 py-2 text-sm font-medium text-slate-700 hover:bg-slate-50 disabled:opacity-50"
              >
                Keep delivery
              </button>
              <button
                type="button"
                data-testid="delivery-day-cancel-confirm"
                onClick={submitCancel}
                disabled={!cancelReason.trim() || cancelBusy}
                className="flex-1 rounded-md bg-red-600 px-3 py-2 text-sm font-medium text-white hover:bg-red-700 disabled:opacity-50"
              >
                {cancelBusy ? "Cancelling…" : "Cancel delivery"}
              </button>
            </div>
          </div>
        </Modal>
      )}

      {/* Re-suggest all windows on a truck — replaces every window */}
      {resuggestTruck && (
        <Modal onClose={() => setResuggestTruck(null)}>
          <div className="w-full max-w-sm rounded-lg border border-slate-200 bg-white p-5 shadow-lg">
            <h2 className="mb-2 text-base font-semibold text-slate-900">
              Re-suggest all windows?
            </h2>
            <p className="text-sm text-slate-600">
              This replaces every arrival window on{" "}
              {allTrucks.find((t) => t.truck_id === resuggestTruck)?.name ??
                "this truck"}
              , including ones set by hand. Nothing is saved until you press
              Save.
            </p>
            <div className="mt-4 flex gap-2">
              <button
                type="button"
                data-testid="delivery-day-win-resuggest-confirm"
                onClick={() => {
                  applyTruckWindows(resuggestTruck, true);
                  setResuggestTruck(null);
                }}
                className="flex-1 rounded-md bg-slate-900 px-3 py-2 text-sm font-medium text-white hover:bg-slate-800"
              >
                Re-suggest all
              </button>
              <button
                type="button"
                onClick={() => setResuggestTruck(null)}
                className="flex-1 rounded-md border border-slate-300 bg-white px-3 py-2 text-sm font-medium text-slate-700 hover:bg-slate-50"
              >
                Go back
              </button>
            </div>
          </div>
        </Modal>
      )}

      {/* Close-with-warnings confirm */}
      {closeConfirm && plan && (
        <Modal onClose={() => setCloseConfirm(false)}>
          <div className="w-full max-w-md rounded-lg border border-slate-200 bg-white p-5 shadow-lg">
            <h2 className="mb-2 text-base font-semibold text-slate-900">
              Close this day anyway?
            </h2>
            <p className="mb-2 text-sm text-slate-600">
              These warnings are showing:
            </p>
            <ul className="mb-4 list-disc space-y-1 pl-5 text-sm text-slate-700">
              {warnings.map((w, i) => (
                <li key={`${w.kind}-${i}`}>{w.text}</li>
              ))}
            </ul>
            <div className="flex gap-2">
              <button
                onClick={doClose}
                className="flex-1 rounded-md bg-slate-900 px-3 py-2 text-sm font-medium text-white hover:bg-slate-800"
              >
                Close anyway
              </button>
              <button
                onClick={() => setCloseConfirm(false)}
                className="flex-1 rounded-md border border-slate-300 bg-white px-3 py-2 text-sm font-medium text-slate-700 hover:bg-slate-50"
              >
                Go back
              </button>
            </div>
          </div>
        </Modal>
      )}
    </div>
  );
}

export default function DeliveryDayPage() {
  return (
    <Suspense
      fallback={
        <div className="mx-auto max-w-6xl px-4 py-6">
          <p className="py-10 text-center text-sm text-slate-500">Loading…</p>
        </div>
      }
    >
      {/* TEMPORARY diagnostic boundary for the prod removeChild crash. */}
      <TempErrorBoundary>
        <DeliveryDayInner />
      </TempErrorBoundary>
    </Suspense>
  );
}
