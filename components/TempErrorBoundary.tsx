"use client";

// TEMPORARY DIAGNOSTICS — added to hunt the production-only
// "removeChild" crash (D1-c2b round 2). Logs the error, JS stack and
// React componentStack, and renders them in a visible panel. REMOVE
// this component and its usages once the crash is diagnosed.

import { Component, type ReactNode } from "react";

type Diag = {
  message: string;
  stack: string;
  componentStack: string;
};

type Props = { children: ReactNode };
type State = { diag: Diag | null };

export default class TempErrorBoundary extends Component<Props, State> {
  state: State = { diag: null };

  static getDerivedStateFromError(): State {
    return { diag: { message: "", stack: "", componentStack: "" } };
  }

  componentDidCatch(error: Error, info: { componentStack?: string | null }) {
    const diag: Diag = {
      message: error?.message ?? String(error),
      stack: error?.stack ?? "",
      componentStack: info?.componentStack ?? "",
    };
    // eslint-disable-next-line no-console
    console.error(
      "[TempErrorBoundary]",
      diag.message,
      "\nJS stack:\n" + diag.stack,
      "\ncomponentStack:\n" + diag.componentStack
    );
    this.setState({ diag });
  }

  render() {
    const { diag } = this.state;
    if (!diag) return this.props.children;
    const text = [
      `message: ${diag.message}`,
      "",
      "js stack:",
      diag.stack,
      "",
      "component stack:",
      diag.componentStack,
    ].join("\n");
    return (
      <div className="mx-auto max-w-3xl p-6">
        <div className="rounded-lg border border-red-300 bg-red-50 p-4">
          <p className="mb-2 text-sm font-semibold text-red-800">
            Something went wrong on this page (diagnostic mode).
          </p>
          <pre className="max-h-96 overflow-auto whitespace-pre-wrap break-all rounded bg-white p-3 text-xs text-slate-800">
            {text}
          </pre>
          <button
            type="button"
            onClick={() => window.location.reload()}
            className="mt-3 rounded-md bg-slate-900 px-3 py-1.5 text-sm font-medium text-white hover:bg-slate-800"
          >
            Reload page
          </button>
        </div>
      </div>
    );
  }
}
