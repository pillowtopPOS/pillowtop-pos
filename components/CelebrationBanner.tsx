"use client";

import { useEffect, useState } from "react";
import { PartyPopper, X } from "lucide-react";
import {
  fetchTodaysCelebrations,
  type Celebration,
} from "@/lib/journeys/queries";

function message(celebration: Celebration) {
  if (celebration.type === "birthday") {
    return `Happy Birthday, ${celebration.first_name}!`;
  }
  return `Happy ${celebration.years}-Year Work Anniversary, ${celebration.first_name}!`;
}

export default function CelebrationBanner() {
  const [celebrations, setCelebrations] = useState<Celebration[]>([]);
  const [dismissed, setDismissed] = useState(false);

  useEffect(() => {
    fetchTodaysCelebrations().then(setCelebrations);
  }, []);

  if (dismissed || celebrations.length === 0) {
    return null;
  }

  return (
    <div className="border-b border-amber-200 bg-amber-50 px-6 py-3">
      <div className="flex items-start justify-between gap-4">
        <div className="flex items-start gap-3">
          <PartyPopper className="mt-0.5 h-5 w-5 shrink-0 text-amber-600" />
          <ul className="space-y-0.5">
            {celebrations.map((c) => (
              <li
                key={`${c.employee_id}-${c.type}`}
                className="text-sm font-medium text-amber-900"
              >
                {message(c)}
              </li>
            ))}
          </ul>
        </div>
        <button
          onClick={() => setDismissed(true)}
          className="rounded p-1 text-amber-600 hover:bg-amber-100"
          aria-label="Dismiss"
        >
          <X className="h-4 w-4" />
        </button>
      </div>
    </div>
  );
}
