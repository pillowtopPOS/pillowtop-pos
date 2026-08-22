export type UserLike = {
  user_metadata?: {
    active_store_confirmed_at?: string;
    active_store_id?: string;
  };
};

export function isStoreConfirmedToday(user: UserLike | null | undefined): boolean {
  const confirmedAt = user?.user_metadata?.active_store_confirmed_at;
  if (!confirmedAt) return false;
  return new Date(confirmedAt).toDateString() === new Date().toDateString();
}

export function storeSelectUrl(returnTo: string): string {
  return `/store-select?returnTo=${encodeURIComponent(returnTo)}`;
}
