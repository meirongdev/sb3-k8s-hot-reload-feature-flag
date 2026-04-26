import { useEffect, useMemo, useState } from 'react'
import { ProviderEvents } from '@openfeature/web-sdk'
import { ffClient, initOpenFeature, setUserContext } from './openfeature'
import { fetchOrder, fetchPricing, type OrderResponse, type PricingResponse } from './api'

const USERS = [
  { id: '', label: 'Anonymous' },
  { id: 'u-normal-001', label: 'u-normal-001 (regular)' },
  { id: 'u-vip-001', label: 'u-vip-001 (VIP)' },
]

function Pill({ text, color }: { text: string; color: string }) {
  return (
    <span
      style={{
        display: 'inline-block',
        padding: '2px 8px',
        marginLeft: 6,
        background: color,
        color: '#fff',
        borderRadius: 999,
        fontSize: 12,
        fontWeight: 600,
      }}
    >
      {text}
    </span>
  )
}

export default function App() {
  const [ready, setReady] = useState(false)
  const [userId, setUserId] = useState<string>('')
  const [orderTier, setOrderTier] = useState<string>('standard')
  const [newPricing, setNewPricing] = useState<boolean>(false)
  const [reloadTick, setReloadTick] = useState(0)
  const [order, setOrder] = useState<OrderResponse | null>(null)
  const [pricing, setPricing] = useState<PricingResponse | null>(null)
  const [error, setError] = useState<string | null>(null)

  useEffect(() => {
    initOpenFeature()
      .then(() => setReady(true))
      .catch((e) => setError(`OpenFeature init failed: ${e.message}`))
  }, [])

  // Re-evaluate flags whenever the user context changes OR flagd pushes a change.
  useEffect(() => {
    if (!ready) return
    const client = ffClient()
    const reEvaluate = () => {
      setOrderTier(client.getStringValue('order-tier', 'standard'))
      setNewPricing(client.getBooleanValue('new-pricing-algo', false))
    }
    setUserContext(userId || null).then(reEvaluate)
    const onChanged = () => {
      setReloadTick((t) => t + 1)
      reEvaluate()
    }
    OpenFeatureSubscribe(onChanged)
    return () => OpenFeatureUnsubscribe(onChanged)
  }, [ready, userId])

  const tierBadge = useMemo(
    () =>
      orderTier === 'premium' ? (
        <Pill text="VIP" color="#7c3aed" />
      ) : (
        <Pill text="Standard" color="#64748b" />
      ),
    [orderTier],
  )

  async function placeOrder() {
    setError(null)
    try {
      setOrder(await fetchOrder(`o-${Date.now() % 1000}`, userId || null))
    } catch (e) {
      setError((e as Error).message)
    }
  }
  async function loadPricing() {
    setError(null)
    try {
      setPricing(await fetchPricing('sku-A', userId || null))
    } catch (e) {
      setError((e as Error).message)
    }
  }

  return (
    <div style={{ fontFamily: 'system-ui, sans-serif', maxWidth: 760, margin: '40px auto', padding: 16 }}>
      <h1>
        SB3 Demo UI
        {newPricing && <Pill text="New Pricing!" color="#0ea5e9" />}
        {tierBadge}
      </h1>

      <section style={{ marginBottom: 24 }}>
        <label>
          User context (drives flag targeting):{' '}
          <select value={userId} onChange={(e) => setUserId(e.target.value)}>
            {USERS.map((u) => (
              <option key={u.id} value={u.id}>
                {u.label}
              </option>
            ))}
          </select>
        </label>
      </section>

      <section style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 16, marginBottom: 24 }}>
        <div style={card()}>
          <h3>OpenFeature flags (client-side)</h3>
          <div>order-tier: <code>{orderTier}</code></div>
          <div>new-pricing-algo: <code>{String(newPricing)}</code></div>
          <div style={{ fontSize: 12, color: '#64748b', marginTop: 8 }}>
            tick #{reloadTick} · evaluated against the same flagd as the Spring gateway, via OFREP
          </div>
        </div>
        <div style={card()}>
          <h3>Backend calls</h3>
          <button onClick={placeOrder}>Place order</button>{' '}
          <button onClick={loadPricing}>Get price</button>
          {error && <div style={{ color: '#dc2626', marginTop: 8 }}>{error}</div>}
        </div>
      </section>

      {order && (
        <pre style={pre()}>
          <strong>order:</strong> {JSON.stringify(order, null, 2)}
        </pre>
      )}
      {pricing && (
        <pre style={pre()}>
          <strong>pricing:</strong> {JSON.stringify(pricing, null, 2)}
        </pre>
      )}
    </div>
  )
}

// Lightweight subscription — the web SDK exposes ProviderEvents.ConfigurationChanged
// and Ready; we use ConfigurationChanged for hot-reload reactivity.
function OpenFeatureSubscribe(handler: () => void) {
  ffClient().addHandler(ProviderEvents.ConfigurationChanged, handler)
}
function OpenFeatureUnsubscribe(handler: () => void) {
  ffClient().removeHandler(ProviderEvents.ConfigurationChanged, handler)
}

function card(): React.CSSProperties {
  return { border: '1px solid #e2e8f0', borderRadius: 8, padding: 16, background: '#f8fafc' }
}
function pre(): React.CSSProperties {
  return { background: '#0f172a', color: '#e2e8f0', padding: 12, borderRadius: 8, overflow: 'auto', fontSize: 12 }
}
