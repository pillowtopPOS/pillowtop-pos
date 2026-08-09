import Link from "next/link";

export default function Home() {
  return (
    <main className="flex min-h-screen flex-col items-center justify-center p-8">
      <h1 className="text-3xl font-semibold text-slate-900">PillowTop POS</h1>
      <p className="mt-2 text-slate-600">Sleep Journey Workspace</p>
      <Link
        href="/login"
        className="mt-8 rounded-md bg-brand-600 px-4 py-2 text-sm font-medium text-white hover:bg-brand-700"
      >
        Sign in
      </Link>
    </main>
  );
}
