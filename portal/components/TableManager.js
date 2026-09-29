'use client';

import { useState } from 'react';

import BulkBar from '@/components/BulkBar';
import useBulkSelection from '@/components/useBulkSelection';

function expandLabels(input) {
  const out = [];
  for (const raw of String(input).split(',')) {
    const token = raw.trim();
    if (!token) continue;
    const range = token.match(/^(\d+)\s*-\s*(\d+)$/);
    if (range) {
      const start = Number(range[1]);
      const end = Number(range[2]);
      if (end >= start && end - start <= 200) {
        for (let value = start; value <= end; value += 1) out.push(String(value));
        continue;
      }
    }
    out.push(token);
  }
  return [...new Set(out)];
}

function qrSrc(table) {
  return `/api/tables/qr?text=${encodeURIComponent(table.url)}`;
}

function printWindow(title, bodyHtml) {
  const popup = window.open('', '_blank', 'width=420,height=620');
  if (!popup) return;
  popup.document.write(
    `<!doctype html><html><head><title>${title}</title>` +
      '<style>body{font-family:system-ui,sans-serif;text-align:center;padding:16px}' +
      'img{width:280px;height:280px}h2{margin:0 0 8px}small{color:#555}' +
      '.sheet{page-break-after:always;padding:12px 0}</style></head><body>' +
      bodyHtml +
      '</body></html>'
  );
  popup.document.close();
  popup.focus();
  setTimeout(() => popup.print(), 500);
}

export default function TableManager({ initial }) {
  const [tables, setTables] = useState(initial?.tables || []);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState('');
  const [notice, setNotice] = useState('');
  const [labels, setLabels] = useState('1-20');
  const [bulkBusy, setBulkBusy] = useState(false);
  const { selected, count, isSelected, toggle, replace, clear } =
    useBulkSelection();

  async function load() {
    try {
      const response = await fetch('/api/tables', { cache: 'no-store' });
      const data = await response.json().catch(() => ({}));
      if (!response.ok) throw new Error(data.error || 'Could not load tables');
      setTables(data.tables || []);
    } catch (loadError) {
      setError(loadError.message);
    }
  }

  async function createTables(event) {
    event.preventDefault();
    const list = expandLabels(labels);
    if (list.length === 0) {
      setError('Enter table labels, e.g. 1-20 or A1, A2');
      return;
    }
    setBusy(true);
    setError('');
    setNotice('');
    try {
      const response = await fetch('/api/tables', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ labels: list }),
      });
      const data = await response.json().catch(() => ({}));
      if (!response.ok) throw new Error(data.error || 'Could not create tables');
      setNotice(
        `Created ${data.created} table(s)${data.skipped ? `, ${data.skipped} already existed` : ''}`
      );
      await load();
    } catch (createError) {
      setError(createError.message);
    } finally {
      setBusy(false);
    }
  }

  async function patch(table, body, message) {
    setError('');
    setNotice('');
    try {
      const response = await fetch(`/api/tables/${table.id}`, {
        method: 'PATCH',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify(body),
      });
      const data = await response.json().catch(() => ({}));
      if (!response.ok) throw new Error(data.error || 'Update failed');
      setNotice(message);
      await load();
    } catch (patchError) {
      setError(patchError.message);
    }
  }

  async function remove(table) {
    if (!window.confirm(`Delete table ${table.label}? Its QR code stops working.`)) {
      return;
    }
    setError('');
    setNotice('');
    try {
      const response = await fetch(`/api/tables/${table.id}`, { method: 'DELETE' });
      const data = await response.json().catch(() => ({}));
      if (!response.ok) throw new Error(data.error || 'Delete failed');
      setNotice(`Deleted table ${table.label}`);
      await load();
    } catch (deleteError) {
      setError(deleteError.message);
    }
  }

  async function bulkDeleteTables() {
    if (
      !window.confirm(`Delete ${count} table(s)? Their QR codes stop working.`)
    ) {
      return;
    }
    setBulkBusy(true);
    setError('');
    setNotice('');
    try {
      const response = await fetch('/api/tables/bulk', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ ids: selected }),
      });
      const data = await response.json().catch(() => ({}));
      if (!response.ok) throw new Error(data.error || 'Bulk delete failed');
      setNotice(`${data.deleted} table(s) deleted`);
      clear();
      await load();
    } catch (deleteError) {
      setError(deleteError.message);
    } finally {
      setBulkBusy(false);
    }
  }

  function printOne(table) {
    printWindow(
      `Table ${table.label}`,
      `<div class="sheet"><h2>${table.label}</h2>` +
        `<img src="${qrSrc(table)}" alt="QR" />` +
        `<p><small>Scan to order · ${table.url}</small></p></div>`
    );
  }

  function printAll() {
    if (tables.length === 0) return;
    const body = tables
      .filter((table) => table.active)
      .map(
        (table) =>
          `<div class="sheet"><h2>${table.label}</h2>` +
          `<img src="${qrSrc(table)}" alt="QR" />` +
          `<p><small>Scan to order</small></p></div>`
      )
      .join('');
    printWindow('Table QR codes', body);
  }

  return (
    <>
      {error ? <div className="notice notice-error">{error}</div> : null}
      {notice ? <div className="notice">{notice}</div> : null}
      <BulkBar
        count={count}
        busy={bulkBusy}
        onClear={clear}
        onDelete={bulkDeleteTables}
        noun="table"
      />

      <section className="card">
        <header>
          <h2>Add tables</h2>
        </header>
        <div className="card-body">
          <form className="form-grid" onSubmit={createTables}>
            <label className="field">
              <span>Table labels (use a range for many)</span>
              <input
                type="text"
                value={labels}
                placeholder="1-20 or A1, A2, B1"
                onChange={(event) => setLabels(event.target.value)}
              />
            </label>
            <div className="actions">
              <button type="submit" className="btn btn-primary" disabled={busy}>
                {busy ? 'Creating…' : '+ Create tables'}
              </button>
              <button type="button" className="btn" onClick={printAll}>
                Print all QR codes
              </button>
            </div>
          </form>
          <p className="muted small">
            Each table gets its own QR code that includes the restaurant code, so
            a code only works for this restaurant.
          </p>
        </div>
      </section>

      <section className="card">
        <header>
          <h2>Tables &amp; QR codes</h2>
          <span className="spacer" />
          <span className="muted small">{tables.length} table(s)</span>
        </header>
        <div className="card-body tight">
          {tables.length === 0 ? (
            <div className="empty">No tables yet. Create some above.</div>
          ) : (
            <div className="table-scroll">
              <table className="data">
                <thead>
                  <tr>
                    <th style={{ width: 34 }}>
                      <input
                        type="checkbox"
                        aria-label="Select all tables"
                        checked={count > 0 && count === tables.length}
                        onChange={(event) =>
                          replace(
                            event.target.checked
                              ? tables.map((table) => table.id)
                              : []
                          )
                        }
                      />
                    </th>
                    <th>QR</th>
                    <th>Table</th>
                    <th>Status</th>
                    <th>Order link</th>
                    <th style={{ textAlign: 'right' }}>Actions</th>
                  </tr>
                </thead>
                <tbody>
                  {tables.map((table) => (
                    <tr key={table.id}>
                      <td>
                        <input
                          type="checkbox"
                          aria-label={`Select table ${table.label}`}
                          checked={isSelected(table.id)}
                          onChange={() => toggle(table.id)}
                        />
                      </td>
                      <td>
                        {/* eslint-disable-next-line @next/next/no-img-element */}
                        <img
                          src={qrSrc(table)}
                          alt={`QR for table ${table.label}`}
                          width={64}
                          height={64}
                          style={{ background: '#fff', borderRadius: 6 }}
                        />
                      </td>
                      <td style={{ fontWeight: 600 }}>{table.label}</td>
                      <td>
                        <span
                          className={`badge ${table.active ? 'badge-ok' : 'badge-err'}`}
                        >
                          {table.active ? 'active' : 'disabled'}
                        </span>
                      </td>
                      <td className="muted small" style={{ maxWidth: 240 }}>
                        <span className="mono" style={{ wordBreak: 'break-all' }}>
                          {table.url}
                        </span>
                      </td>
                      <td style={{ textAlign: 'right' }}>
                        <div
                          className="actions"
                          style={{ justifyContent: 'flex-end' }}
                        >
                          <button
                            type="button"
                            className="btn btn-sm"
                            onClick={() => printOne(table)}
                          >
                            Print QR
                          </button>
                          <button
                            type="button"
                            className="btn btn-sm"
                            onClick={() =>
                              patch(
                                table,
                                { active: !table.active },
                                table.active
                                  ? `Table ${table.label} disabled`
                                  : `Table ${table.label} enabled`
                              )
                            }
                          >
                            {table.active ? 'Disable' : 'Enable'}
                          </button>
                          <button
                            type="button"
                            className="btn btn-sm btn-danger"
                            onClick={() => remove(table)}
                          >
                            Delete
                          </button>
                        </div>
                      </td>
                    </tr>
                  ))}
                </tbody>
              </table>
            </div>
          )}
        </div>
      </section>
    </>
  );
}
