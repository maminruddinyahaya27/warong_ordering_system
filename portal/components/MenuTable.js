'use client';

import Link from 'next/link';
import { useRouter } from 'next/navigation';
import { useState } from 'react';

export default function MenuTable({ items, currency, showGroup = true }) {
  const router = useRouter();
  const [draftPrices, setDraftPrices] = useState({});
  const [busyId, setBusyId] = useState(null);
  const [error, setError] = useState('');
  const [notice, setNotice] = useState('');

  function priceValue(item) {
    if (draftPrices[item.id] !== undefined) return draftPrices[item.id];
    return Number(item.price).toFixed(2);
  }

  function isDirty(item) {
    if (draftPrices[item.id] === undefined) return false;
    const parsed = Number(draftPrices[item.id]);
    if (!Number.isFinite(parsed) || parsed < 0) return true;
    return (
      Math.round(parsed * 100) / 100 !==
      Math.round(Number(item.price) * 100) / 100
    );
  }

  async function request(url, options) {
    const response = await fetch(url, {
      headers: { 'Content-Type': 'application/json' },
      ...options,
    });
    const data = await response.json().catch(() => ({}));
    if (!response.ok) {
      throw new Error(data.error || `Request failed (${response.status})`);
    }
    return data;
  }

  async function savePrice(item) {
    const parsed = Number(draftPrices[item.id]);
    if (!Number.isFinite(parsed) || parsed < 0) {
      setError('Enter a price of 0 or more.');
      return;
    }

    setBusyId(item.id);
    setError('');
    setNotice('');
    try {
      await request(`/api/menu/${item.id}`, {
        method: 'PATCH',
        body: JSON.stringify({ price: parsed, note: 'Inline price edit' }),
      });
      setDraftPrices((previous) => {
        const next = { ...previous };
        delete next[item.id];
        return next;
      });
      setNotice(`${item.name} price updated to ${currency} ${parsed.toFixed(2)}`);
      router.refresh();
    } catch (requestError) {
      setError(requestError.message);
    } finally {
      setBusyId(null);
    }
  }

  async function toggleAvailable(item) {
    setBusyId(item.id);
    setError('');
    setNotice('');
    try {
      await request(`/api/menu/${item.id}`, {
        method: 'PATCH',
        body: JSON.stringify({ available: !item.available }),
      });
      setNotice(
        `${item.name} marked ${item.available ? 'sold out / hidden' : 'available'}`
      );
      router.refresh();
    } catch (requestError) {
      setError(requestError.message);
    } finally {
      setBusyId(null);
    }
  }

  async function remove(item) {
    if (!window.confirm(`Delete ${item.name} (${item.sku})? This cannot be undone.`)) {
      return;
    }

    setBusyId(item.id);
    setError('');
    setNotice('');
    try {
      await request(`/api/menu/${item.id}`, { method: 'DELETE' });
      setNotice(`${item.name} deleted`);
      router.refresh();
    } catch (requestError) {
      setError(requestError.message);
    } finally {
      setBusyId(null);
    }
  }

  if (items.length === 0) {
    return (
      <div className="empty">
        No menu items match this filter. <Link href="/menu/new">Add one</Link> or{' '}
        <Link href="/menu">clear the filters</Link>.
      </div>
    );
  }

  return (
    <div className="card-body tight">
      {error ? <div className="notice notice-error" style={{ margin: 16 }}>{error}</div> : null}
      {notice ? <div className="notice notice-ok" style={{ margin: 16 }}>{notice}</div> : null}

      <div className="table-scroll">
        <table className="data">
          <thead>
            <tr>
              <th>SKU</th>
              <th>Item</th>
              <th>Station</th>
              {showGroup ? <th>Group</th> : null}
              <th style={{ textAlign: 'right' }}>Price</th>
              <th>Status</th>
              <th style={{ textAlign: 'right' }}>Actions</th>
            </tr>
          </thead>
          <tbody>
            {items.map((item) => {
              const dirty = isDirty(item);
              const busy = busyId === item.id;

              return (
                <tr key={item.id}>
                  <td className="mono small">{item.sku}</td>
                  <td>
                    <div style={{ fontWeight: 600 }}>{item.name}</div>
                    <div className="muted small">
                      {item.options === 'drink' ? 'Drink' : 'Food'}
                    </div>
                  </td>
                  <td>
                    <span className="badge">{item.station}</span>
                  </td>
                  {showGroup ? (
                    <td>
                      {item.group ? (
                        <span className="badge badge-accent">{item.group}</span>
                      ) : (
                        <span className="muted small">Ungrouped</span>
                      )}
                    </td>
                  ) : null}
                  <td style={{ textAlign: 'right' }}>
                    <div className="inline" style={{ justifyContent: 'flex-end' }}>
                      <input
                        className="price-input"
                        type="number"
                        min="0"
                        step="0.05"
                        value={priceValue(item)}
                        disabled={busy}
                        onChange={(event) =>
                          setDraftPrices((previous) => ({
                            ...previous,
                            [item.id]: event.target.value,
                          }))
                        }
                        onKeyDown={(event) => {
                          if (event.key === 'Enter') {
                            event.preventDefault();
                            if (dirty) savePrice(item);
                          }
                        }}
                        aria-label={`Price for ${item.name}`}
                      />
                      {dirty ? (
                        <button
                          className="btn btn-primary btn-sm"
                          type="button"
                          disabled={busy}
                          onClick={() => savePrice(item)}
                        >
                          {busy ? '…' : 'Save'}
                        </button>
                      ) : null}
                    </div>
                  </td>
                  <td>
                    {item.available ? (
                      <span className="badge badge-ok">Available</span>
                    ) : (
                      <span className="badge badge-err">Sold out</span>
                    )}
                  </td>
                  <td style={{ textAlign: 'right' }}>
                    <div className="inline" style={{ justifyContent: 'flex-end' }}>
                      <button
                        className="btn btn-sm"
                        type="button"
                        disabled={busy}
                        onClick={() => toggleAvailable(item)}
                      >
                        {item.available ? 'Mark sold out' : 'Mark available'}
                      </button>
                      <Link className="btn btn-sm" href={`/menu/${item.id}`}>
                        Edit
                      </Link>
                      <button
                        className="btn btn-danger btn-sm"
                        type="button"
                        disabled={busy}
                        onClick={() => remove(item)}
                      >
                        Delete
                      </button>
                    </div>
                  </td>
                </tr>
              );
            })}
          </tbody>
        </table>
      </div>
    </div>
  );
}
