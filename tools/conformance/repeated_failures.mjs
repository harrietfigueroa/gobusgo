// The time a case that repeats a refused call is given for each refusal.

// About three times the 16 ms a refusal through the WebAssembly binding took
// on CI's WebKit, measured 2026-11-20 in
// https://github.com/harrietfigueroa/gobusgo/actions/runs/44824925872.
export const FAILURE_BUDGET_MS = 50
