'use client';

import Link from 'next/link';
import { useRouter } from 'next/navigation';
import { useState } from 'react';

function initialForm(item, defaultGroupId) {
  return {
    name: item?.name || '',
    sku: item?.sku || '',
    price: item ? Number(item.price).toFixed(2) : '',
    station: item?.station || '',
    group: item?.groupId || defaultGroupId || '',
    isDrink: (item?.options || '').split(',').includes('drink'),
    askSugar: (item?.options || '').split(',').includes('sugar'),
    askIce: (item?.options || '').split(',').includes('ice'),
    addOnFor: Array.isArray(item?.addOnFor) ? item.addOnFor : [],
    requireAddOn: item?.requireAddOn === true,
    description: item?.description || '',
    available: item?.available !== false,
    sortOrder: item?.sortOrder ?? 0,
  };
}

export default function MenuItemForm({
  item = null,
  stations = [],
  groups = [],
  defaultGroupId = '',
  currency = 'RM',
  /// Where to go after saving/cancelling — the list URL with its filters, so an
  /// edit does not drop the search/group/station you were working in.
  returnTo = '/menu',
}) {
  const router = useRouter();
  const mode = item ? 'edit' : 'create';
  const [form, setForm] = useState(() => initialForm(item, defaultGroupId));
  const [saving, setSaving] = useState(false);
  const [deleting, setDeleting] = useState(false);
  const [error, setError] = useState('');

  function update(field, value) {
    setForm((previous) => ({ ...previous, [field]: value }));
  }

  function addAddOnFor(name) {
    if (!name || form.addOnFor.includes(name)) return;
    update('addOnFor', [...form.addOnFor, name]);
  }

  function removeAddOnFor(name) {
    update(
      'addOnFor',
      form.addOnFor.filter((entry) => entry !== name)
    );
  }

  async function submit(event) {
    event.preventDefault();
    setSaving(true);
    setError('');

    const payload = {
      name: form.name,
      price: form.price,
      station: form.station,
      group: form.group,
      options: form.isDrink
        ? ['drink', form.askSugar && 'sugar', form.askIce && 'ice']
            .filter(Boolean)
            .join(',')
        : '',
      addOnFor: form.addOnFor || [],
      requireAddOn: form.requireAddOn === true,
      description: form.description,
      available: form.available,
      sortOrder: Number(form.sortOrder) || 0,
    };
    if (form.sku.trim()) payload.sku = form.sku.trim();

    try {
      const response = await fetch(
        mode === 'edit' ? `/api/menu/${item.id}` : '/api/menu',
        {
          method: mode === 'edit' ? 'PATCH' : 'POST',
          headers: { 'Content-Type': 'application/json' },
          body: JSON.stringify(payload),
        }
      );
      const data = await response.json().catch(() => ({}));
      if (!response.ok) {
        throw new Error(data.error || `Request failed (${response.status})`);
      }
      router.push(returnTo || '/menu');
      router.refresh();
    } catch (requestError) {
      setError(requestError.message);
      setSaving(false);
    }
  }

  async function remove() {
    if (!item) return;
    if (!window.confirm(`Delete ${item.name} (${item.sku})? This cannot be undone.`)) {
      return;
    }
    setDeleting(true);
    setError('');
    try {
      const response = await fetch(`/api/menu/${item.id}`, { method: 'DELETE' });
      const data = await response.json().catch(() => ({}));
      if (!response.ok) {
        throw new Error(data.error || `Request failed (${response.status})`);
      }
      router.push(returnTo || '/menu');
      router.refresh();
    } catch (requestError) {
      setError(requestError.message);
      setDeleting(false);
    }
  }

  return (
    <form className="stack" onSubmit={submit}>
      {error ? <div className="notice notice-error">{error}</div> : null}

      <section className="card">
        <header>
          <h2>{mode === 'edit' ? 'Edit item' : 'New item'}</h2>
        </header>
        <div className="card-body">
          <div className="form-grid">
            <label className="field" style={{ gridColumn: 'span 2' }}>
              <span>Name</span>
              <input
                type="text"
                required
                maxLength={80}
                value={form.name}
                placeholder="e.g. Nasi Lemak Ayam"
                onChange={(event) => update('name', event.target.value)}
              />
            </label>

            <label className="field">
              <span>SKU</span>
              <input
                type="text"
                value={form.sku}
                placeholder={mode === 'create' ? 'auto (mi_019)' : ''}
                onChange={(event) => update('sku', event.target.value)}
              />
              <span className="hint">
                {mode === 'create'
                  ? 'Leave blank to auto-generate.'
                  : 'Used by the ordering apps to identify the item.'}
              </span>
            </label>

            <label className="field">
              <span>Price ({currency})</span>
              <input
                type="number"
                required
                min="0"
                step="0.05"
                value={form.price}
                placeholder="0.00"
                onChange={(event) => update('price', event.target.value)}
              />
            </label>

            <label className="field">
              <span>Station</span>
              <input
                type="text"
                required
                list="station-options"
                value={form.station}
                placeholder="Kitchen"
                onChange={(event) => update('station', event.target.value)}
              />
              <datalist id="station-options">
                {stations.map((station) => (
                  <option key={station} value={station} />
                ))}
              </datalist>
              <span className="hint">
                Fallback routing target. If the item&apos;s group has a station
                set, the group&apos;s station wins.
              </span>
            </label>

            <label className="field">
              <span>Group</span>
              <select
                value={form.group}
                onChange={(event) => update('group', event.target.value)}
              >
                <option value="">Ungrouped</option>
                {groups.map((group) => (
                  <option key={group.id} value={group.id}>
                    {group.name}
                  </option>
                ))}
              </select>
              <span className="hint">
                Groups are the sections shown on the ordering screen.{' '}
                <a href="/groups">Manage groups</a>
              </span>
            </label>

            <div className="field">
              <span>Add-on for groups</span>
              <div
                className="inline"
                style={{ flexWrap: 'wrap', gap: 6, marginBottom: 6 }}
              >
                {form.addOnFor.length === 0 ? (
                  <span className="muted small">None</span>
                ) : (
                  form.addOnFor.map((name) => (
                    <span key={name} className="badge">
                      {name}
                      <button
                        type="button"
                        aria-label={`Remove ${name}`}
                        onClick={() => removeAddOnFor(name)}
                        style={{
                          marginLeft: 6,
                          border: 0,
                          background: 'transparent',
                          cursor: 'pointer',
                          color: 'inherit',
                        }}
                      >
                        ×
                      </button>
                    </span>
                  ))
                )}
              </div>
              <select
                value=""
                onChange={(event) => {
                  addAddOnFor(event.target.value);
                  event.target.value = '';
                }}
              >
                <option value="">+ add a parent group…</option>
                {groups
                  .filter((group) => !form.addOnFor.includes(group.name))
                  .map((group) => (
                    <option key={group.id} value={group.name}>
                      {group.name}
                    </option>
                  ))}
              </select>
              <span className="hint">
                When a chosen group is on the same order, this item prints on
                that group&apos;s station (e.g. Kari Kambing + Roti Canai →
                Griddle). Leave empty to always use its own station.
              </span>
            </div>

            <label className="field">
              <span>Requires an add-on</span>
              <span className="field-row">
                <input
                  type="checkbox"
                  checked={form.requireAddOn}
                  onChange={(event) =>
                    update('requireAddOn', event.target.checked)
                  }
                />
                <span className="small">
                  Must pick an add-on before this item can be ordered
                </span>
              </span>
              <span className="hint">
                For dishes sold with a choice, e.g. Nasi Lemak + Lauk. The
                ordering apps will not add this item until an add-on is picked.
              </span>
            </label>

            <label className="field">
              <span>Sort order</span>
              <input
                type="number"
                step="1"
                value={form.sortOrder}
                onChange={(event) => update('sortOrder', event.target.value)}
              />
              <span className="hint">Lower numbers appear first.</span>
            </label>
          </div>

          <div className="form-grid" style={{ marginTop: 14 }}>
            <label className="field">
              <span>Options</span>
              <span className="field-row">
                <input
                  type="checkbox"
                  checked={form.isDrink}
                  onChange={(event) => update('isDrink', event.target.checked)}
                />
                <span className="small">Drink</span>
              </span>
              {form.isDrink ? (
                <span className="field-row" style={{ marginTop: 6 }}>
                  <input
                    type="checkbox"
                    checked={form.askSugar}
                    onChange={(event) =>
                      update('askSugar', event.target.checked)
                    }
                  />
                  <span className="small">Ask sugar level</span>
                  <input
                    type="checkbox"
                    checked={form.askIce}
                    onChange={(event) => update('askIce', event.target.checked)}
                    style={{ marginLeft: 12 }}
                  />
                  <span className="small">
                    Ask ice level (leave off for hot drinks)
                  </span>
                </span>
              ) : null}
            </label>

            <label className="field">
              <span>Availability</span>
              <span className="field-row">
                <input
                  type="checkbox"
                  checked={form.available}
                  onChange={(event) => update('available', event.target.checked)}
                />
                <span className="small">Available to order</span>
              </span>
            </label>
          </div>

          <label className="field" style={{ marginTop: 14 }}>
            <span>Description</span>
            <textarea
              rows={3}
              maxLength={400}
              value={form.description}
              placeholder="Optional notes shown to staff."
              onChange={(event) => update('description', event.target.value)}
            />
          </label>
        </div>
      </section>

      <div className="actions">
        <button className="btn btn-primary" type="submit" disabled={saving || deleting}>
          {saving ? 'Saving…' : mode === 'edit' ? 'Save changes' : 'Create item'}
        </button>
        <Link className="btn" href={returnTo || '/menu'}>
          Cancel
        </Link>
        {mode === 'edit' ? (
          <button
            className="btn btn-danger"
            type="button"
            disabled={saving || deleting}
            onClick={remove}
            style={{ marginLeft: 'auto' }}
          >
            {deleting ? 'Deleting…' : 'Delete item'}
          </button>
        ) : null}
      </div>
    </form>
  );
}
