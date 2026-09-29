'use client';

import { useEffect, useMemo, useState } from 'react';

const SWEETNESS_LEVELS = ['Normal', 'Less sugar', 'No sugar'];

function isDrink(item) {
  return (item?.options || '').toLowerCase().includes('drink');
}

function lineId(sku, sweetness) {
  return `${sku}::${sweetness || ''}`;
}

export default function CustomerOrder({ tenantRef, tableToken }) {
  const [data, setData] = useState(null);
  const [error, setError] = useState('');
  const [loading, setLoading] = useState(true);
  const [activeGroup, setActiveGroup] = useState('');
  // Cart lines: the same item can appear several times when the sweetness
  // differs (e.g. one Teh O "Less sugar" and one "Normal").
  const [cart, setCart] = useState([]);
  const [sweetness, setSweetness] = useState({});
  const [note, setNote] = useState('');
  const [cartOpen, setCartOpen] = useState(false);
  const [addOnFor, setAddOnFor] = useState(null);
  const [submitting, setSubmitting] = useState(false);
  const [placed, setPlaced] = useState(null);

  useEffect(() => {
    let cancelled = false;
    (async () => {
      try {
        const response = await fetch(
          `/api/public/menu?t=${encodeURIComponent(tenantRef)}&table=${encodeURIComponent(tableToken)}`,
          { cache: 'no-store' }
        );
        const json = await response.json().catch(() => ({}));
        if (!response.ok) throw new Error(json.error || 'Could not load the menu');
        if (cancelled) return;
        setData(json);
        setActiveGroup(json.groups?.[0]?.name || '');
      } catch (loadError) {
        if (!cancelled) setError(loadError.message);
      } finally {
        if (!cancelled) setLoading(false);
      }
    })();
    return () => {
      cancelled = true;
    };
  }, [tenantRef, tableToken]);

  const currency = data?.currency || 'RM';

  const itemCount = cart.reduce((sum, line) => sum + line.qty, 0);
  const total = cart.reduce(
    (sum, line) => sum + line.qty * line.item.price,
    0
  );
  const items = useMemo(
    () => (data?.menu || []).filter((item) => item.group === activeGroup),
    [data, activeGroup]
  );
  const groupAddOns = useMemo(() => {
    const map = {};
    for (const group of data?.groups || []) {
      map[group.name] = group.addOns || [];
    }
    return map;
  }, [data]);

  function currentSweetness(sku) {
    return sweetness[sku] || 'Normal';
  }

  /// Total units of an item across all cart lines (shown under the Add button).
  function qtyForSku(sku) {
    return cart.reduce(
      (sum, line) => sum + (line.item.sku === sku ? line.qty : 0),
      0
    );
  }

  function removeLine(line) {
    setCart((previous) => previous.filter((entry) => entry.id !== line.id));
  }

  /// Picks the sweetness that the Add button on the menu row will use.
  function pickSweetness(item, level) {
    setSweetness((previous) => ({ ...previous, [item.sku]: level }));
  }

  /// Adds (or removes) one unit for the item at its currently picked sweetness.
  function add(item, delta) {
    const level = isDrink(item) ? currentSweetness(item.sku) : '';
    const id = lineId(item.sku, level);
    setCart((previous) => {
      const index = previous.findIndex((line) => line.id === id);
      if (index === -1) {
        if (delta <= 0) return previous;
        return [...previous, { id, item, qty: delta, sweetness: level }];
      }
      const next = [...previous];
      const qty = next[index].qty + delta;
      if (qty <= 0) next.splice(index, 1);
      else next[index] = { ...next[index], qty };
      return next;
    });
  }

  function changeLineQty(line, delta) {
    setCart((previous) => {
      const index = previous.findIndex((entry) => entry.id === line.id);
      if (index === -1) return previous;
      const next = [...previous];
      const qty = next[index].qty + delta;
      if (qty <= 0) next.splice(index, 1);
      else next[index] = { ...next[index], qty };
      return next;
    });
  }

  /// Changes one line's sweetness, merging it with a sibling line that already
  /// has that sweetness.
  function changeLineSweetness(line, level) {
    setSweetness((previous) => ({ ...previous, [line.item.sku]: level }));
    setCart((previous) => {
      const index = previous.findIndex((entry) => entry.id === line.id);
      if (index === -1) return previous;
      const mergedId = lineId(line.item.sku, level);
      const next = [...previous];
      const sibling = next.findIndex(
        (entry, position) => position !== index && entry.id === mergedId
      );
      if (sibling !== -1) {
        next[sibling] = {
          ...next[sibling],
          qty: next[sibling].qty + next[index].qty,
        };
        next.splice(index, 1);
      } else {
        next[index] = { ...next[index], id: mergedId, sweetness: level };
      }
      return next;
    });
  }

  /// Adds the tapped item, then offers its add-on groups (e.g. a Roti Canai
  /// offers Lauk-pauk curries) in a popup. The add-ons print on the parent's
  /// station, so the roti and its curry share one ticket.
  function startAdd(item) {
    add(item, 1);

    const addOnGroups = groupAddOns[item.group] || [];
    const options = (data?.menu || []).filter((entry) =>
      addOnGroups.includes(entry.group)
    );
    if (options.length > 0) setAddOnFor({ parent: item, options });
  }

  function sweetnessChips(selected, onPick) {
    return (
      <div className="inline" style={{ flexWrap: 'wrap', gap: 6, marginTop: 6 }}>
        {SWEETNESS_LEVELS.map((level) => (
          <button
            key={level}
            type="button"
            className={`btn btn-sm${selected === level ? ' btn-primary' : ''}`}
            onClick={() => onPick(level)}
          >
            {level}
          </button>
        ))}
      </div>
    );
  }

  async function submit() {
    if (cart.length === 0) return;
    setSubmitting(true);
    setError('');
    try {
      const response = await fetch('/api/public/orders', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({
          t: tenantRef,
          table: tableToken,
          note,
          items: cart.map((line) => ({
            sku: line.item.sku,
            qty: line.qty,
            note:
              line.sweetness && line.sweetness !== 'Normal'
                ? line.sweetness
                : '',
          })),
        }),
      });
      const json = await response.json().catch(() => ({}));
      if (!response.ok) throw new Error(json.error || 'Could not send the order');
      setPlaced(json);
      setCart([]);
      setSweetness({});
      setNote('');
      setCartOpen(false);
    } catch (submitError) {
      setError(submitError.message);
    } finally {
      setSubmitting(false);
    }
  }

  if (loading) {
    return <div className="notice">Loading menu…</div>;
  }

  if (error && !data) {
    return <div className="notice notice-error">{error}</div>;
  }

  if (placed) {
    return (
      <div className="card">
        <header>
          <h2>Order sent</h2>
        </header>
        <div className="card-body">
          <p>
            Your order for <strong>Table {placed.table?.label}</strong> has been
            sent to the counter.
          </p>
          <p className="muted">
            Reference <span className="mono">{placed.ref}</span> · Total{' '}
            <strong>
              {currency}
              {Number(placed.total || 0).toFixed(2)}
            </strong>
          </p>
          <div className="notice">
            Please pay at the counter. Food and drinks are prepared once the
            kitchen receives your order.
          </div>
          <div className="actions">
            <button
              type="button"
              className="btn btn-primary"
              onClick={() => setPlaced(null)}
            >
              Order more
            </button>
          </div>
        </div>
      </div>
    );
  }

  return (
    <div className="stack" style={{ paddingBottom: itemCount > 0 ? 116 : 0 }}>
      <div className="card">
        <header>
          <h2>{data?.restaurant || 'Menu'}</h2>
          <span className="spacer" />
          <span className="badge">Table {data?.table?.label}</span>
        </header>
      </div>

      {error ? <div className="notice notice-error">{error}</div> : null}

      {(data?.groups || []).length > 0 ? (
        <div className="inline" style={{ flexWrap: 'wrap', gap: 8 }}>
          {data.groups.map((group) => (
            <button
              key={group.name}
              type="button"
              className={`btn btn-sm${group.name === activeGroup ? ' btn-primary' : ''}`}
              onClick={() => setActiveGroup(group.name)}
            >
              {group.name} ({group.count})
            </button>
          ))}
        </div>
      ) : null}

      <div className="card">
        <div className="card-body tight">
          {items.length === 0 ? (
            <div className="empty">Nothing available in this group.</div>
          ) : (
            <div>
              {items.map((item) => {
                const qty = qtyForSku(item.sku);
                return (
                  <div
                    key={item.sku}
                    style={{
                      display: 'flex',
                      alignItems: 'flex-start',
                      gap: 12,
                      padding: '14px 4px',
                      borderBottom: '1px solid rgba(128,128,128,0.14)',
                    }}
                  >
                    <div style={{ flex: 1, minWidth: 0, paddingRight: 4 }}>
                      <div
                        style={{
                          fontWeight: 600,
                          marginBottom: 4,
                          lineHeight: 1.3,
                        }}
                      >
                        {item.name}
                      </div>
                      <div className="muted small">
                        {currency}
                        {Number(item.price).toFixed(2)}
                      </div>
                      {isDrink(item)
                        ? sweetnessChips(currentSweetness(item.sku), (level) =>
                            pickSweetness(item, level)
                          )
                        : null}
                    </div>
                    <div style={{ paddingTop: 2, textAlign: 'center' }}>
                      <button
                        type="button"
                        className="btn btn-sm btn-primary"
                        onClick={() => startAdd(item)}
                      >
                        Add
                      </button>
                      {qty > 0 ? (
                        <div
                          className="muted small"
                          style={{ marginTop: 4, fontWeight: 600 }}
                        >
                          {qty} in cart
                        </div>
                      ) : null}
                    </div>
                  </div>
                );
              })}
            </div>
          )}
        </div>
      </div>

      {itemCount > 0 ? (
        <div
          style={{
            position: 'fixed',
            left: 0,
            right: 0,
            bottom: 0,
            zIndex: 40,
            padding: '12px 16px',
            borderTop: '1px solid var(--line)',
            background: 'var(--panel)',
            color: 'var(--text)',
            display: 'flex',
            gap: 12,
            alignItems: 'center',
          }}
        >
          <div style={{ flex: 1 }}>
            <div style={{ fontWeight: 600 }}>
              {itemCount} item{itemCount === 1 ? '' : 's'} in cart
            </div>
            <div className="muted small">
              {currency}
              {total.toFixed(2)}
            </div>
          </div>
          <button
            type="button"
            className="btn btn-primary"
            onClick={() => setCartOpen(true)}
          >
            View cart
          </button>
        </div>
      ) : null}

      {cartOpen ? (
        <div style={{ position: 'fixed', inset: 0, zIndex: 50 }}>
          <button
            type="button"
            aria-label="Close cart"
            onClick={() => setCartOpen(false)}
            style={{
              position: 'absolute',
              inset: 0,
              background: 'rgba(0,0,0,0.45)',
              border: 0,
              padding: 0,
              cursor: 'pointer',
            }}
          />
          <div
            style={{
              position: 'absolute',
              left: 0,
              right: 0,
              bottom: 0,
              maxHeight: '85vh',
              display: 'flex',
              flexDirection: 'column',
              background: 'var(--panel)',
              color: 'var(--text)',
              borderTop: '1px solid var(--line)',
              borderTopLeftRadius: 16,
              borderTopRightRadius: 16,
              padding: '14px 16px 18px',
              boxShadow: '0 -8px 30px rgba(0,0,0,0.25)',
            }}
          >
            <div className="inline" style={{ alignItems: 'center', gap: 8 }}>
              <strong style={{ flex: 1, fontSize: 16 }}>Your order</strong>
              <span className="muted small">Table {data?.table?.label}</span>
              <button
                type="button"
                className="btn btn-sm"
                onClick={() => setCartOpen(false)}
              >
                Close
              </button>
            </div>

            <div style={{ overflowY: 'auto', margin: '10px 0' }}>
              {cart.length === 0 ? (
                <div className="muted small" style={{ padding: '14px 0' }}>
                  Your cart is empty.
                </div>
              ) : (
                cart.map((line) => (
                  <div
                    key={line.id}
                    style={{
                      display: 'flex',
                      alignItems: 'flex-start',
                      gap: 10,
                      padding: '10px 0',
                      borderBottom: '1px solid var(--line-soft)',
                    }}
                  >
                    <div style={{ flex: 1, minWidth: 0, paddingRight: 4 }}>
                      <div
                        style={{
                          fontWeight: 600,
                          marginBottom: 3,
                          lineHeight: 1.3,
                        }}
                      >
                        {line.item.name}
                      </div>
                      <div className="muted small">
                        {currency}
                        {Number(line.item.price).toFixed(2)} each
                      </div>
                      {isDrink(line.item)
                        ? sweetnessChips(line.sweetness || 'Normal', (level) =>
                            changeLineSweetness(line, level)
                          )
                        : null}
                    </div>
                    <div style={{ textAlign: 'right' }}>
                      <div
                        className="inline"
                        style={{ gap: 6, alignItems: 'center' }}
                      >
                        <button
                          type="button"
                          className="btn btn-sm"
                          onClick={() => changeLineQty(line, -1)}
                        >
                          −
                        </button>
                        <span style={{ minWidth: 18, textAlign: 'center' }}>
                          {line.qty}
                        </span>
                        <button
                          type="button"
                          className="btn btn-sm"
                          onClick={() => changeLineQty(line, 1)}
                        >
                          +
                        </button>
                      </div>
                      <div style={{ marginTop: 6, fontWeight: 600 }}>
                        {currency}
                        {(line.item.price * line.qty).toFixed(2)}
                      </div>
                      <button
                        type="button"
                        className="btn btn-sm btn-danger"
                        style={{ marginTop: 6 }}
                        onClick={() => removeLine(line)}
                      >
                        Remove
                      </button>
                    </div>
                  </div>
                ))
              )}
            </div>

            <label className="field">
              <span>Notes (optional)</span>
              <input
                type="text"
                value={note}
                placeholder="e.g. less sugar, no chilli"
                onChange={(event) => setNote(event.target.value)}
              />
            </label>

            <div
              className="inline"
              style={{ justifyContent: 'space-between', margin: '8px 0 12px' }}
            >
              <span className="muted small">
                {itemCount} item{itemCount === 1 ? '' : 's'}
              </span>
              <strong>
                Total {currency}
                {total.toFixed(2)}
              </strong>
            </div>

            <button
              type="button"
              className="btn btn-primary"
              disabled={submitting || cart.length === 0}
              onClick={submit}
            >
              {submitting ? 'Sending…' : 'Send order'}
            </button>
          </div>
        </div>
      ) : null}

      {addOnFor ? (
        <div style={{ position: 'fixed', inset: 0, zIndex: 60 }}>
          <button
            type="button"
            aria-label="Close add-ons"
            onClick={() => setAddOnFor(null)}
            style={{
              position: 'absolute',
              inset: 0,
              background: 'rgba(0,0,0,0.45)',
              border: 0,
              padding: 0,
              cursor: 'pointer',
            }}
          />
          <div
            style={{
              position: 'absolute',
              left: 0,
              right: 0,
              bottom: 0,
              maxHeight: '80vh',
              display: 'flex',
              flexDirection: 'column',
              background: 'var(--panel)',
              color: 'var(--text)',
              borderTop: '1px solid var(--line)',
              borderTopLeftRadius: 16,
              borderTopRightRadius: 16,
              padding: '14px 16px 18px',
              boxShadow: '0 -8px 30px rgba(0,0,0,0.25)',
            }}
          >
            <div className="inline" style={{ alignItems: 'center', gap: 8 }}>
              <strong style={{ flex: 1, fontSize: 16 }}>
                Add on to {addOnFor.parent.name}?
              </strong>
              <button
                type="button"
                className="btn btn-sm"
                onClick={() => setAddOnFor(null)}
              >
                Done
              </button>
            </div>
            <p className="muted small" style={{ margin: '6px 0 8px' }}>
              Optional — pick any extras, then tap Done.
            </p>
            <div style={{ overflowY: 'auto' }}>
              {addOnFor.options.map((option) => {
                const qty = cart
                  .filter((line) => line.item.sku === option.sku)
                  .reduce((sum, line) => sum + line.qty, 0);
                return (
                  <div
                    key={option.sku}
                    style={{
                      display: 'flex',
                      alignItems: 'center',
                      gap: 10,
                      padding: '10px 0',
                      borderBottom: '1px solid var(--line-soft)',
                    }}
                  >
                    <div style={{ flex: 1, minWidth: 0 }}>
                      <div
                        style={{
                          fontWeight: 600,
                          marginBottom: 3,
                          lineHeight: 1.3,
                        }}
                      >
                        {option.name}
                      </div>
                      <div className="muted small">
                        {currency}
                        {Number(option.price).toFixed(2)}
                      </div>
                    </div>
                    {qty > 0 ? (
                      <span className="badge">{qty} added</span>
                    ) : null}
                    <button
                      type="button"
                      className="btn btn-sm btn-primary"
                      onClick={() => add(option, 1)}
                    >
                      Add
                    </button>
                  </div>
                );
              })}
            </div>
          </div>
        </div>
      ) : null}
    </div>
  );
}
