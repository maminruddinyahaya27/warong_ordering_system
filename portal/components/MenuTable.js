'use client';

import Link from 'next/link';
import { useRouter, useSearchParams } from 'next/navigation';
import { useState } from 'react';

import BulkBar from '@/components/BulkBar';
import useBulkSelection from '@/components/useBulkSelection';

export default function MenuTable({ items, currency, showGroup = true, groups = [] }) {
  const router = useRouter();
  // Carry the current filters through an edit, so saving returns to the same
  // filtered list instead of dropping the search/group/station.
  const searchParams = useSearchParams();
  const query = searchParams.toString();
  const listUrl = query ? `/menu?${query}` : '/menu';
  const editUrl = (id) =>
    `/menu/${id}?from=${encodeURIComponent(listUrl)}`;
  const newUrl = `/menu/new?from=${encodeURIComponent(listUrl)}`;
  const [draftPrices, setDraftPrices] = useState({});
  const [busyId, setBusyId] = useState(null);
  const [error, setError] = useState('');
  const [notice, setNotice] = useState('');
  const [bulkBusy, setBulkBusy] = useState(false);
  const { selected, count, isSelected, toggle, replace, clear } =
    useBulkSelection();

  function priceValue(item) {
    if (draftPrices[item.id] !== undefined) return draftPrices[item.id];
    return Number(item.price).toFixed(2);
  }

  // An item's own station wins; the group's station is the fallback for items
  // that leave it empty (see app/api/export/route.js).
  const stationByGroup = new Map(
    (groups || []).map((group) => [group.name, (group.station || '').trim()])
  );
  const printedStation = (item) =>
    (item.station || '').trim() || stationByGroup.get(item.group) || 'KITCHEN';
  const groupRouted = (item) => {
    const own = (item.station || '').trim();
    const fromGroup = stationByGroup.get(item.group);
    return !own && !!fromGroup;
  };
  // `options` carries the drink keywords, e.g. "drink,sugar,ice".
  const optionsOf = (item) => (item.options || '').split(',').filter(Boolean);
  const isDrink = (item) => optionsOf(item).includes('drink');
  const drinkOptions = (item) =>
    optionsOf(item)
      .filter((option) => option !== 'drink')
      .join(', ');

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

  async function bulkDelete() {
    if (
      !window.confirm(
        `Delete ${count} menu item(s)? This cannot be undone.`
      )
    ) {
      return;
    }
    setBulkBusy(true);
    setError('');
    setNotice('');
    try {
      const data = await request('/api/menu/bulk', {
        method: 'POST',
        body: JSON.stringify({ ids: selected }),
      });
      setNotice(`${data.deleted} menu item(s) deleted`);
      clear();
      router.refresh();
    } catch (requestError) {
      setError(requestError.message);
    } finally {
      setBulkBusy(false);
    }
  }

  if (items.length === 0) {
    return (
      <div className="empty">
        No menu items match this filter. <Link href={newUrl}>Add one</Link> or{' '}
        <Link href="/menu">clear the filters</Link>.
      </div>
    );
  }

  return (
    <div className="card-body tight">
      {error ? <div className="notice notice-error" style={{ margin: 16 }}>{error}</div> : null}
      {notice ? <div className="notice notice-ok" style={{ margin: 16 }}>{notice}</div> : null}
      {count > 0 ? (
        <div style={{ margin: 16 }}>
          <BulkBar
            count={count}
            busy={bulkBusy}
            onClear={clear}
            onDelete={bulkDelete}
            noun="menu item"
          />
        </div>
      ) : null}

      <div className="table-scroll">
        <table className="data">
          <thead>
            <tr>
              <th style={{ width: 34 }}>
                <input
                  type="checkbox"
                  aria-label="Select all menu items"
                  checked={count > 0 && count === items.length}
                  onChange={(event) =>
                    replace(event.target.checked ? items.map((item) => item.id) : [])
                  }
                />
              </th>
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
                  <td>
                    <input
                      type="checkbox"
                      aria-label={`Select ${item.name}`}
                      checked={isSelected(item.id)}
                      onChange={() => toggle(item.id)}
                    />
                  </td>
                  <td className="mono small">{item.sku}</td>
                  <td>
                    <div style={{ fontWeight: 600 }}>{item.name}</div>
                    <div className="muted small">
                      {isDrink(item)
                        ? `Drink${drinkOptions(item) ? ` · ${drinkOptions(item)}` : ''}`
                        : 'Food'}
                    </div>
                  </td>
                  <td>
                    <span className="badge">{printedStation(item)}</span>
                    {groupRouted(item) ? (
                      <div className="muted small" style={{ marginTop: 2 }}>
                        from {item.group}
                      </div>
                    ) : null}
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
                      <Link className="btn btn-sm" href={editUrl(item.id)}>
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
