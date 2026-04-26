// Same-origin API calls — nginx proxies /api/* to the Spring gateway.

export type OrderResponse = {
  service: string
  thread: string
  orderId: string
  userId: string
  handler: string
  tier: string
  newPricingHint: boolean
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

function headers(userId: string | null): HeadersInit {
  const h: HeadersInit = { Accept: 'application/json' }
  if (userId) h['X-User-Id'] = userId
  return h
}

export async function fetchOrder(id: string, userId: string | null): Promise<OrderResponse> {
  const r = await fetch(`/api/orders/${id}`, { headers: headers(userId) })
  if (!r.ok) throw new Error(`order request failed: ${r.status}`)
  return r.json()
}

export async function fetchPricing(sku: string, userId: string | null): Promise<PricingResponse> {
  const r = await fetch(`/api/pricing/${sku}`, { headers: headers(userId) })
  if (!r.ok) throw new Error(`pricing request failed: ${r.status}`)
  return r.json()
}
