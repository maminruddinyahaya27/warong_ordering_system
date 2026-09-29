'use client';

import { useEffect, useMemo, useState } from 'react';

const SUGAR_LEVELS = ['Normal sugar', 'Less sugar', 'No sugar'];
const ICE_LEVELS = ['Normal ice', 'Less ice', 'No ice'];

function isDrink(item) {
  return (item?.options || '').toLowerCase().includes('drink');
}

let lineSequence = 0;

/// Every line gets its own id: an item ordered with add-ons must stay separate
/// from another identical item, so each keeps its own add-ons on the ticket.
function newLineId(sku, note) {
  lineSequence += 1;
  return `${sku}::${note}::${lineSequence}`;
}

export default function CustomerOrder({ tenantRef, tableToken }) {
  const [data, setData] = useState(null);
  const [error, setError] = useState('');
  const [loading, setLoading] = useState(true);
  const [activeGroup, setActiveGroup] = useState('');
  // Cart lines: the same item can appear several times when the drink options
  // differ (e.g. one Teh O "Less sugar, Normal ice" and one all-normal).
  const [cart, setCart] = useState([]);
  const [drinkOptions, setDrinkOptions] = useState({});
  const [note, setNote] = useState('');
  const [cartOpen, setCartOpen] = useState(false);
  const [bundle, setBundle] = useState(null);
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
  const total = cart.reduce((sum, line) => sum + line.qty * line.item.price, 0);
  const items = useMemo(
    () => (data?.menu || []).filter((item) => item.group === activeGroup),
    [data, activeGroup]
  );

  function optionsFor(sku) {
    return drinkOptions[sku] || {};
  }

  function optionHas(item, tag) {
    return (item?.options || '')
      .toLowerCase()
      .split(',')
      .includes(tag);
  }

  function sugarOf(source) {
    return source?.sugar || SUGAR_LEVELS[0];
  }

  function iceOf(source) {
    return source?.ice || ICE_LEVELS[0];
  }

  /// The note printed for a drink: only the levels this item asks for, so a hot
  /// drink (drink,sugar) never mentions ice.
  function drinkNote(item, source) {
    return [
      optionHas(item, 'sugar') ? sugarOf(source) : null,
      optionHas(item, 'ice') ? iceOf(source) : null,
    ]
      .filter(Boolean)
      .join(', ');
  }

  function lineNote(line) {
    return isDrink(line.item) ? drinkNote(line.item, line) : '';
  }

  /// Menu items that are add-ons for the given item's group.
  function addOnOptionsFor(parent) {
    return (data?.menu || []).filter((entry) =>
      (entry.addOnFor || []).includes(parent.group)
    );
  }

  /// Tapping an item with add-ons opens the bundle sheet: pick the quantity,
  /// then any add-ons. Plain items are added straight away.
  function startAdd(item) {
    const options = addOnOptionsFor(item);
    if (options.length === 0) {
      add(item, 1);
      return;
    }
    setBundle({ parent: item, options, parentQty: 1, qty: {} });
  }

  function confirmBundle() {
    if (!bundle) return;
    add(bundle.parent, bundle.parentQty, { merge: false });
    for (const option of bundle.options) {
      const qty = bundle.qty[option.sku] || 0;
      if (qty > 0) add(option, qty, { merge: false });
    }
    setBundle(null);
  }

  function add(item, qty, { merge = true } = {}) {
    const sugar = isDrink(item) ? sugarOf(optionsFor(item.sku)) : '';
    const ice = isDrink(item) ? iceOf(optionsFor(item.sku)) : '';
    const note = isDrink(item) ? drinkNote(item, { sugar, ice }) : '';
    setCart((previous) => {
      const index = merge
        ? previous.findIndex(
            (line) => line.item.sku === item.sku && lineNote(line) === note
          )
        : -1;
      if (index === -1) {
        return [
          ...previous,
          { id: newLineId(item.sku, note), item, qty, sugar, ice },
        ];
      }
      const next = [...previous];
      next[index] = { ...next[index], qty: next[index].qty + qty };
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

  function removeLine(line) {
    setCart((previous) => previous.filter((entry) => entry.id !== line.id));
  }

  /// Changes one cart line's sugar/ice, merging with a sibling that ends up the
  /// same (so two identical drinks stay one line).
  function changeLineOption(line, kind, value) {
    setCart((previous) => {
      const index = previous.findIndex((entry) => entry.id === line.id);
      if (index === -1) return previous;
      const sugar = kind === 'sugar' ? value : line.sugar;
      const ice = kind === 'ice' ? value : line.ice;
      const note = drinkNote(line.item, { sugar, ice });
      const next = [...previous];
      const sibling = next.findIndex(
        (entry, position) =>
          position !== index &&
          entry.item.sku === line.item.sku &&
          lineNote(entry) === note
      );
      if (sibling !== -1) {
        next[sibling] = {
          ...next[sibling],
          qty: next[sibling].qty + next[index].qty,
        };
        next.splice(index, 1);
      } else {
        next[index] = { ...next[index], sugar, ice };
      }
      return next;
    });
  }

  function optionChips(current, onChange, askSugar, askIce) {
    if (!askSugar && !askIce) return null;
    const row = (label, options, selected, kind) => (
      <div className="inline" style={{ flexWrap: 'wrap', gap: 6 }}>
        <span className="muted small" style={{ minWidth: 42 }}>
          {label}
        </span>
        {options.map((level) => (
          <button
            key={level}
            type="button"
            className={`btn btn-sm${selected === level ? ' btn-primary' : ''}`}
            onClick={() => onChange(kind, level)}
          >
            {level}
          </button>
        ))}
      </div>
    );
    return (
      <div style={{ marginTop: 6, display: 'grid', gap: 6 }}>
        {askSugar ? row('Sugar', SUGAR_LEVELS, sugarOf(current), 'sugar') : null}
        {askIce ? row('Ice', ICE_LEVELS, iceOf(current), 'ice') : null}
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
            note: lineNote(line),
          })),
        }),
      });
      const json = await response.json().catch(() => ({}));
      if (!response.ok) throw new Error(json.error || 'Could not send the order');
      setPlaced(json);
      setCart([]);
      setDrinkOptions({});
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
                const qty = cart
                  .filter((line) => line.item.sku === item.sku)
                  .reduce((sum, line) => sum + line.qty, 0);
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
                        ? optionChips(
                            optionsFor(item.sku),
                            (kind, value) =>
                              setDrinkOptions((previous) => ({
                                ...previous,
                                [item.sku]: {
                                  ...previous[item.sku],
                                  [kind]: value,
                                },
                              })),
                            optionHas(item, 'sugar'),
                            optionHas(item, 'ice')
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
                        ? optionChips(
                            { sugar: line.sugar, ice: line.ice },
                            (kind, value) =>
                              changeLineOption(line, kind, value),
                            optionHas(line.item, 'sugar'),
                            optionHas(line.item, 'ice')
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
                placeholder="e.g. no chilli"
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

      {bundle ? (
        <div style={{ position: 'fixed', inset: 0, zIndex: 60 }}>
          <button
            type="button"
            aria-label="Close add-ons"
            onClick={() => setBundle(null)}
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
                {bundle.parent.name}
              </strong>
              <button
                type="button"
                className="btn btn-sm"
                onClick={() => setBundle(null)}
              >
                Cancel
              </button>
            </div>

            <div
              className="inline"
              style={{ alignItems: 'center', gap: 8, margin: '10px 0 4px' }}
            >
              <span style={{ flex: 1, fontWeight: 600 }}>Quantity</span>
              <button
                type="button"
                className="btn btn-sm"
                disabled={bundle.parentQty <= 1}
                onClick={() =>
                  setBundle({ ...bundle, parentQty: bundle.parentQty - 1 })
                }
              >
                −
              </button>
              <span style={{ minWidth: 18, textAlign: 'center' }}>
                {bundle.parentQty}
              </span>
              <button
                type="button"
                className="btn btn-sm"
                onClick={() =>
                  setBundle({ ...bundle, parentQty: bundle.parentQty + 1 })
                }
              >
                +
              </button>
            </div>

            <div className="muted small" style={{ marginTop: 6 }}>
              Add on (optional)
            </div>
            <div style={{ overflowY: 'auto' }}>
              {bundle.options.map((option) => {
                const qty = bundle.qty[option.sku] || 0;
                return (
                  <div
                    key={option.sku}
                    style={{
                      display: 'flex',
                      alignItems: 'center',
                      gap: 10,
                      padding: '8px 0',
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
                    <div
                      className="inline"
                      style={{ gap: 6, alignItems: 'center' }}
                    >
                      <button
                        type="button"
                        className="btn btn-sm"
                        disabled={qty === 0}
                        onClick={() =>
                          setBundle({
                            ...bundle,
                            qty: { ...bundle.qty, [option.sku]: qty - 1 },
                          })
                        }
                      >
                        −
                      </button>
                      <span style={{ minWidth: 18, textAlign: 'center' }}>
                        {qty}
                      </span>
                      <button
                        type="button"
                        className="btn btn-sm"
                        onClick={() =>
                          setBundle({
                            ...bundle,
                            qty: { ...bundle.qty, [option.sku]: qty + 1 },
                          })
                        }
                      >
                        +
                      </button>
                    </div>
                  </div>
                );
              })}
            </div>

            <button
              type="button"
              className="btn btn-primary"
              style={{ marginTop: 12 }}
              onClick={confirmBundle}
            >
              Add to order
            </button>
          </div>
        </div>
      ) : null}
    </div>
  );
}
