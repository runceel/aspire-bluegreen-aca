import { useEffect, useState } from 'react'

interface VersionInfo {
  version: string
  color: string
  label: string
}

interface Order {
  id: number
  customer: string
  total: number
}

interface OrdersResponse {
  configured: boolean
  source: string
  orders: Order[]
}

// Injected at build time from the APP_VERSION environment variable (see vite.config.ts).
const webVersion = __WEB_VERSION__

export default function App() {
  const [info, setInfo] = useState<VersionInfo | null>(null)
  const [error, setError] = useState<string | null>(null)
  const [orders, setOrders] = useState<OrdersResponse | null>(null)
  const [ordersError, setOrdersError] = useState<string | null>(null)

  useEffect(() => {
    fetch('/api/version')
      .then((r) => r.json())
      .then((d: VersionInfo) => setInfo(d))
      .catch((e) => setError(String(e)))
  }, [])

  const loadOrders = async () => {
    setOrdersError(null)
    try {
      const r = await fetch('/api/orders')
      setOrders((await r.json()) as OrdersResponse)
    } catch (e) {
      setOrdersError(String(e))
    }
  }

  const color = info?.color ?? '#888888'

  return (
    <div className="app" style={{ background: color }}>
      <main className="card">
        <h1>🛒 Online Orders</h1>

        {error && <p className="err">API への接続に失敗しました: {error}</p>}

        {info && (
          <>
            <p className="badge" style={{ background: color }}>
              {info.label.toUpperCase()}
            </p>
            <dl>
              <dt>API version</dt>
              <dd>{info.version}</dd>
              <dt>API color</dt>
              <dd>{info.color}</dd>
              <dt>Web version</dt>
              <dd>{webVersion}</dd>
            </dl>
          </>
        )}

        <button onClick={loadOrders}>注文一覧を読み込む</button>

        {ordersError && <p className="err">{ordersError}</p>}

        {orders && (
          <div className="orders">
            <p className="src">
              source: {orders.source}
              {orders.configured ? '' : '（SQL 未設定 / graceful degrade）'}
            </p>
            <ul>
              {orders.orders.map((o) => (
                <li key={o.id}>
                  #{o.id} {o.customer} — ¥{o.total.toLocaleString()}
                </li>
              ))}
            </ul>
          </div>
        )}
      </main>
    </div>
  )
}
