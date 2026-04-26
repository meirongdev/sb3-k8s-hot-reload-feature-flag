import { OpenFeature, type EvaluationContext } from '@openfeature/web-sdk'
import { OFREPWebProvider } from '@openfeature/ofrep-web-provider'

/**
 * Same flagd that the Spring gateway uses. The browser reaches it through
 * nginx's /ofrep/* reverse-proxy on the same origin (no CORS).
 *
 * In production the same indirection holds — flagd never gets exposed to
 * the public, and the OFREP base URL stays same-origin.
 */
const OFREP_BASE = `${window.location.origin}/ofrep`

let initialised = false

export async function initOpenFeature() {
  if (initialised) return
  initialised = true
  await OpenFeature.setProviderAndWait(
    new OFREPWebProvider({ baseUrl: OFREP_BASE, pollInterval: 5000 }),
  )
}

/**
 * Switching context re-evaluates all bound flags and notifies hooks/components.
 * The web SDK keeps a per-client snapshot keyed by context, so changes are
 * reactive without manually re-fetching.
 */
export function setUserContext(userId: string | null) {
  const ctx: EvaluationContext = userId ? { targetingKey: userId } : {}
  return OpenFeature.setContext(ctx)
}

export const ffClient = () => OpenFeature.getClient('ui')
