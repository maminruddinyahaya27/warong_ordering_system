'use client';

import { useEffect, useMemo, useState } from 'react';

const SUGAR_LEVELS = ['Normal sugar', 'Less sugar', 'No sugar'];
const ICE_LEVELS = ['Normal ice', 'Less ice', 'No ice'];

function isDrink(item) {
  return (item?.options || '').toLowerCase().includes('drink');
}

function optionHas(item, tag) {
  return (item?.options || '')
    .toLowerCase()
    .split(',')
    .includes(tag);
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
  // differ, or when it is ordered with different add-ons.
  const [cart, setCart] = useState([]);
  const [note, setNote] = useState('');
  const [cartOpen, setCartOpen] = useState(false);
  // One dialog at a time: a drink's sugar/ice, or an item's quantity + add-ons.
  const [modal, setModal] = useState(null);
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

  /// The note printed for a drink: only the levels this item asks for, so a hot
  /// drink (drink,sugar) never mentions ice.
  function drinkNoteFor(item, sugar, ice) {
    return [
      optionHas(item, 'sugar') ? sugar : null,
      optionHas(item, 'ice') ? ice : null,
    ]
      .filter(Boolean)
      .join(', ');
  }

  function lineNote(line) {
    return isDrink(line.item) ? line.note : '';
  }

  /// Menu items that are add-ons for the given item's group.
  function addOnOptionsFor(parent) {
    return (data?.menu || []).filter((entry) =>
      (entry.addOnFor || []).includes(parent.group)
    );
  }

  /// Same behaviour as the Hub and the waiter: tap an item and a dialog asks
  /// what it needs. Plain items are added straight away.
  function startAdd(item) {
    const options = addOnOptionsFor(item);
    if (options.length > 0) {
      setModal({
        type: 'bundle',
        item,
        options,
        parentQty: 1,
        qty: {},
      });
      return;
    }
    if (isDrink(item) && (optionHas(item, 'sugar') || optionHas(item, 'ice'))) {
      setModal({
        type: 'drink',
        item,
        sugar: SUGAR_LEVELS[0],
        ice: ICE_LEVELS[0],
      });
      return;
    }
    add(item, 1);
  }

  function closeModal() {
    setModal(null);
  }

  function confirmDrink() {
    if (!modal) return;
    const item = modal.item;
    add(item, 1, { note: drinkNoteFor(item, modal.sugar, modal.ice) });
    closeModal();
  }

  function confirmBundle() {
    if (!modal) return;
    // One cart entry per bundle: the parent line, with its add-ons linked to it
    // so the cart shows them nested (as the printed ticket does).
    const parentId = newLineId(modal.item.sku, '');
    setCart((previous) => {
      const next = [
        ...previous,
        {
          id: parentId,
          item: modal.item,
          qty: modal.parentQty,
          note: '',
          parentId: '',
        },
      ];
      for (const option of modal.options) {
        const qty = modal.qty[option.sku] || 0;
        if (qty <= 0) continue;
        next.push({
          id: newLineId(option.sku, ''),
          item: option,
          qty,
          note: '',
          parentId,
        });
      }
      return next;
    });
    closeModal();
  }

  function add(item, qty, { merge = true, note: lineNoteValue, parentId = '' } = {}) {
    const noteValue = lineNoteValue ?? '';
    setCart((previous) => {
      const index = merge
        ? previous.findIndex(
            (line) =>
              line.item.sku === item.sku &&
              line.note === noteValue &&
              !line.parentId
          )
        : -1;
      if (index === -1) {
        return [
          ...previous,
          {
            id: newLineId(item.sku, noteValue),
            item,
            qty,
            note: noteValue,
            parentId,
          },
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

  /// Removing an item also removes the add-ons ordered with it.
  function removeLine(line) {
    setCart((previous) =>
      previous.filter(
        (entry) => entry.id !== line.id && entry.parentId !== line.id
      )
    );
  }

  /// One cart row; `indent` marks an add-on sitting under its item.
  function cartRow(line, indent) {
    return (
      <div
        key={line.id}
        style={{
          display: 'flex',
          alignItems: 'flex-start',
          gap: 10,
          padding: indent ? '6px 0' : '10px 0',
          paddingLeft: indent ? 18 : 0,
          borderBottom: '1px solid var(--line-soft)',
        }}
      >
        <div style={{ flex: 1, minWidth: 0, paddingRight: 4 }}>
          <div
            style={{
              fontWeight: indent ? 500 : 600,
              marginBottom: 3,
              lineHeight: 1.3,
              color: indent ? 'var(--muted)' : undefined,
            }}
          >
            {indent ? `- ${line.item.name}` : line.item.name}
          </div>
          <div className="muted small">
            {currency}
            {Number(line.item.price).toFixed(2)} each
          </div>
          {lineNote(line) ? (
            <div className="muted small">{lineNote(line)}</div>
          ) : null}
        </div>
        <div style={{ textAlign: 'right' }}>
          <div className="inline" style={{ gap: 6, alignItems: 'center' }}>
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
                      alignItems: 'center',
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
                // Add-ons sit under the item they were ordered with.
                cart
                  .filter(
                    (line) =>
                      !line.parentId ||
                      !cart.some((other) => other.id === line.parentId)
                  )
                  .map((parent) => (
                    <div key={parent.id}>
                      {cartRow(parent, false)}
                      {cart
                        .filter((child) => child.parentId === parent.id)
                        .map((child) => cartRow(child, true))}
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

      {modal ? (
        <div
          style={{
            position: 'fixed',
            inset: 0,
            zIndex: 60,
            display: 'grid',
            placeItems: 'center',
            padding: 16,
          }}
        >
          <button
            type="button"
            aria-label="Close"
            onClick={closeModal}
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
            className="card"
            style={{
              position: 'relative',
              width: '100%',
              maxWidth: 380,
              maxHeight: '85vh',
              overflow: 'auto',
              margin: 0,
            }}
          >
            <div className="card-body">
              <strong style={{ fontSize: 16 }}>{modal.item.name}</strong>

              {modal.type === 'drink' ? (
                <>
                  {optionHas(modal.item, 'sugar') ? (
                    <div style={{ marginTop: 12 }}>
                      <div className="muted small">Sugar</div>
                      <div
                        className="inline"
                        style={{ flexWrap: 'wrap', gap: 6, marginTop: 4 }}
                      >
                        {SUGAR_LEVELS.map((level) => (
                          <button
                            key={level}
                            type="button"
                            className={`btn btn-sm${modal.sugar === level ? ' btn-primary' : ''}`}
                            onClick={() =>
                              setModal({ ...modal, sugar: level })
                            }
                          >
                            {level}
                          </button>
                        ))}
                      </div>
                    </div>
                  ) : null}
                  {optionHas(modal.item, 'ice') ? (
                    <div style={{ marginTop: 12 }}>
                      <div className="muted small">Ice</div>
                      <div
                        className="inline"
                        style={{ flexWrap: 'wrap', gap: 6, marginTop: 4 }}
                      >
                        {ICE_LEVELS.map((level) => (
                          <button
                            key={level}
                            type="button"
                            className={`btn btn-sm${modal.ice === level ? ' btn-primary' : ''}`}
                            onClick={() => setModal({ ...modal, ice: level })}
                          >
                            {level}
                          </button>
                        ))}
                      </div>
                    </div>
                  ) : null}
                </>
              ) : (
                <>
                  <div
                    className="inline"
                    style={{ alignItems: 'center', gap: 8, margin: '12px 0 4px' }}
                  >
                    <span style={{ flex: 1, fontWeight: 600 }}>Quantity</span>
                    <button
                      type="button"
                      className="btn btn-sm"
                      disabled={modal.parentQty <= 1}
                      onClick={() =>
                        setModal({ ...modal, parentQty: modal.parentQty - 1 })
                      }
                    >
                      −
                    </button>
                    <span style={{ minWidth: 18, textAlign: 'center' }}>
                      {modal.parentQty}
                    </span>
                    <button
                      type="button"
                      className="btn btn-sm"
                      onClick={() =>
                        setModal({ ...modal, parentQty: modal.parentQty + 1 })
                      }
                    >
                      +
                    </button>
                  </div>

                  <div className="muted small" style={{ marginTop: 10 }}>
                    Add on (optional)
                  </div>
                  <div>
                    {modal.options.map((option) => {
                      const qty = modal.qty[option.sku] || 0;
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
                                setModal({
                                  ...modal,
                                  qty: { ...modal.qty, [option.sku]: qty - 1 },
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
                                setModal({
                                  ...modal,
                                  qty: { ...modal.qty, [option.sku]: qty + 1 },
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
                </>
              )}

              <div className="actions" style={{ marginTop: 16 }}>
                <button type="button" className="btn" onClick={closeModal}>
                  Cancel
                </button>
                <button
                  type="button"
                  className="btn btn-primary"
                  onClick={modal.type === 'drink' ? confirmDrink : confirmBundle}
                >
                  {modal.type === 'drink' ? 'Add' : 'Add to order'}
                </button>
              </div>
            </div>
          </div>
        </div>
      ) : null}
    </div>
  );
}
