export const BACKEND_RESTART_DELAYS_MS = [1_000, 3_000, 10_000] as const

export function backendRestartDelay(attempt: number): number | null {
  if (!Number.isInteger(attempt) || attempt < 0) return null
  return BACKEND_RESTART_DELAYS_MS[attempt] ?? null
}
