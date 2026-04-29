import { useEffect, useMemo, useState, type CSSProperties } from 'react'
import { ProviderEvents } from '@openfeature/web-sdk'
import { ffClient, initOpenFeature, setUserContext } from './openfeature'
import {
  fetchOrder,
  fetchPricing,
  fetchSharedFlags,
  type OrderResponse,
  type PricingResponse,
  type SharedFlagsResponse,
} from './api'

const USERS = [
  { id: '', label: 'Anonymous' },
  { id: 'u-normal-001', label: 'u-normal-001 (regular)' },
  { id: 'u-vip-001', label: 'u-vip-001 (VIP)' },
]

const TENANTS = [
  { id: '', label: 'default tenant' },
  { id: 'premium', label: 'premium tenant' },
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
  const [tenantId, setTenantId] = useState<string>('')
  const [homepageBanner, setHomepageBanner] = useState<string>('control')
  const [memberPerks, setMemberPerks] = useState<boolean>(false)
  const [reloadTick, setReloadTick] = useState(0)
  const [sharedFlags, setSharedFlags] = useState<SharedFlagsResponse | null>(null)
  const [order, setOrder] = useState<OrderResponse | null>(null)
  const [pricing, setPricing] = useState<PricingResponse | null>(null)
  const [error, setError] = useState<string | null>(null)

  useEffect(() => {
    initOpenFeature()
      .then(() => setReady(true))
      .catch((e) => setError(`OpenFeature init failed: ${e.message}`))
  }, [])

  useEffect(() => {
    if (!ready) return
    const client = ffClient()
    const reEvaluate = () => {
      setHomepageBanner(client.getStringValue('ui-homepage-banner', 'control'))
      setMemberPerks(client.getBooleanValue('ui-member-perks', false))
    }
    setUserContext(userId || null).then(reEvaluate)
    const onChanged = () => {
      setReloadTick((t) => t + 1)
      reEvaluate()
    }
    subscribeToFrontendFlags(onChanged)
    return () => unsubscribeFromFrontendFlags(onChanged)
  }, [ready, userId])

  useEffect(() => {
    fetchSharedFlags(userId || null, tenantId || null)
      .then(setSharedFlags)
      .catch((e) => setError(`Shared flag fetch failed: ${e.message}`))
  }, [userId, tenantId])

  const bannerBadge = useMemo(
    () =>
      homepageBanner === 'spring-sale' ? (
        <Pill text="Spring Sale" color="#ea580c" />
      ) : (
        <Pill text="Control Banner" color="#64748b" />
      ),
    [homepageBanner],
  )

  const tierBadge = useMemo(() => {
    if (sharedFlags?.orderTier === 'premium') {
      return <Pill text="VIP Shared Tier" color="#7c3aed" />
    }
    return <Pill text="Standard Shared Tier" color="#64748b" />
  }, [sharedFlags])

  async function placeOrder() {
    setError(null)
    try {
      setOrder(await fetchOrder(`o-${Date.now() % 1000}`, userId || null, tenantId || null))
    } catch (e) {
      setError((e as Error).message)
    }
  }

  async function loadPricing() {
    setError(null)
    try {
      setPricing(await fetchPricing('sku-B', userId || null, tenantId || null))
    } catch (e) {
      setError((e as Error).message)
    }
  }

  return (
    <div style={{ fontFamily: 'system-ui, sans-serif', maxWidth: 900, margin: '40px auto', padding: 16 }}>
      <h1>
        E-commerce OpenFeature Reference
        {bannerBadge}
        {tierBadge}
      </h1>

      <p style={{ color: '#475569', lineHeight: 1.5 }}>
        One stack, three scenarios: frontend-only presentation flags, backend-only operational flags, and
        full-stack shared business semantics.
      </p>

      <section style={{ display: 'flex', gap: 16, marginBottom: 24 }}>
        <label>
          User context:{' '}
          <select value={userId} onChange={(e) => setUserId(e.target.value)}>
            {USERS.map((u) => (
              <option key={u.id} value={u.id}>
                {u.label}
              </option>
            ))}
          </select>
        </label>
        <label>
          Tenant context:{' '}
          <select value={tenantId} onChange={(e) => setTenantId(e.target.value)}>
            {TENANTS.map((t) => (
              <option key={t.id} value={t.id}>
                {t.label}
              </option>
            ))}
          </select>
        </label>
      </section>

      <section style={sectionCard()}>
        <h2>Frontend-only flags</h2>
        <div>Banner variant via OFREP: <code>{homepageBanner}</code></div>
        <div>Member perks card: <code>{String(memberPerks)}</code></div>
        <div style={metaText()}>tick #{reloadTick} · browser evaluates only presentation-safe flags</div>
      </section>

      <section style={sectionCard()}>
        <h2>Backend-only flag</h2>
        <div>Gateway resolves fulfillment mode and propagates it to order-service without exposing OpenFeature downstream.</div>
        <button onClick={placeOrder}>Place order</button>
        {order && (
          <pre style={pre()}>
            <strong>order:</strong> {JSON.stringify(order, null, 2)}
          </pre>
        )}
      </section>

      <section style={sectionCard()}>
        <h2>Full-stack shared flags</h2>
        <div>Gateway snapshot: <code>{sharedFlags ? JSON.stringify(sharedFlags) : 'loading...'}</code></div>
        <button onClick={loadPricing}>Get shared-tier price</button>
        {pricing && (
          <pre style={pre()}>
            <strong>pricing:</strong> {JSON.stringify(pricing, null, 2)}
          </pre>
        )}
      </section>

      {error && <div style={{ color: '#dc2626', marginTop: 12 }}>{error}</div>}
    </div>
  )
}

function subscribeToFrontendFlags(handler: () => void) {
  ffClient().addHandler(ProviderEvents.ConfigurationChanged, handler)
}

function unsubscribeFromFrontendFlags(handler: () => void) {
  ffClient().removeHandler(ProviderEvents.ConfigurationChanged, handler)
}

function sectionCard(): CSSProperties {
  return {
    border: '1px solid #e2e8f0',
    borderRadius: 8,
    padding: 16,
    background: '#f8fafc',
    marginBottom: 20,
  }
}

function metaText(): CSSProperties {
  return {
    fontSize: 12,
    color: '#64748b',
    marginTop: 8,
  }
}

function pre(): CSSProperties {
  return {
    background: '#0f172a',
    color: '#e2e8f0',
    padding: 12,
    borderRadius: 8,
    overflow: 'auto',
    fontSize: 12,
    marginTop: 12,
  }
}
