// Same-origin API calls — nginx proxies /api/* to the Spring gateway.

export type OrderResponse = {
  service: string
  thread: string
  orderId: string
  userId: string
  handler: string
  tier: string
  newPricingHint: boolean
  fulfillmentMode: string
}

export type PricingResponse = {
  service: string
  thread: string
  sku: string
  algorithm: string
  tier: string
  price: number
  currency: string
  discountPercent: number
}

export type SharedFlagsResponse = {
  orderTier: string
  newPricing: boolean
  fulfillmentMode: string
}

function headers(userId: string | null, tenantId: string | null): HeadersInit {
  const h: HeadersInit = { Accept: 'application/json' }
  if (userId) h['X-User-Id'] = userId
  if (tenantId) h['X-Tenant-Id'] = tenantId
  return h
}

export async function fetchOrder(id: string, userId: string | null, tenantId: string | null): Promise<OrderResponse> {
  const r = await fetch(`/api/orders/${id}`, { headers: headers(userId, tenantId) })
  if (!r.ok) throw new Error(`order request failed: ${r.status}`)
  return r.json()
}

export async function fetchPricing(sku: string, userId: string | null, tenantId: string | null): Promise<PricingResponse> {
  const r = await fetch(`/api/pricing/${sku}`, { headers: headers(userId, tenantId) })
  if (!r.ok) throw new Error(`pricing request failed: ${r.status}`)
  return r.json()
}

export async function fetchSharedFlags(
  userId: string | null,
  tenantId: string | null,
): Promise<SharedFlagsResponse> {
  const r = await fetch('/api/experience/shared-flags', { headers: headers(userId, tenantId) })
  if (!r.ok) throw new Error(`shared flags request failed: ${r.status}`)
  return r.json()
}
