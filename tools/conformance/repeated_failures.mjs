// The time a case that repeats a refused call is given for each refusal.

// About three times the slowest measured: on CI's WebKit, a refusal through
// the WebAssembly binding took about 16 ms, measured 2026-11-20.
export const FAILURE_BUDGET_MS = 50
