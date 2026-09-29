'use client';

import { useRouter } from 'next/navigation';
import { useState } from 'react';

import BulkBar from '@/components/BulkBar';
import useBulkSelection from '@/components/useBulkSelection';

export default function StationManager({ stations }) {
  const router = useRouter();
  const [drafts, setDrafts] = useState({});
  const [newStation, setNewStation] = useState({ name: '', printerName: '' });
  const [busy, setBusy] = useState('');
  const [error, setError] = useState('');
  const [notice, setNotice] = useState('');
  const [bulkBusy, setBulkBusy] = useState(false);
  const { selected, count, isSelected, toggle, replace, clear } =
    useBulkSelection();

  const deletable = stations.filter((station) => !station.orphan);

  function draftFor(station) {
    return (
      drafts[station.id] || {
        name: station.name,
        printerName: station.printerName || '',
      }
    );
  }

  function setDraft(station, patch) {
    setDrafts((previous) => ({
      ...previous,
      [station.id]: { ...draftFor(station), ...patch },
    }));
  }

  function isDirty(station) {
    const draft = drafts[station.id];
    if (!draft) return false;
    return (
      draft.name !== station.name ||
      draft.printerName !== (station.printerName || '')
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

  async function createStation(event) {
    event.preventDefault();
    setBusy('new');
    setError('');
    setNotice('');
    try {
      await request('/api/stations', {
        method: 'POST',
        body: JSON.stringify(newStation),
      });
      setNewStation({ name: '', printerName: '' });
      setNotice('Station added');
      router.refresh();
    } catch (requestError) {
      setError(requestError.message);
    } finally {
      setBusy('');
    }
  }

  async function saveStation(station) {
    const draft = draftFor(station);
    setBusy(station.id);
    setError('');
    setNotice('');
    try {
      const data = await request(`/api/stations/${station.id}`, {
        method: 'PATCH',
        body: JSON.stringify(draft),
      });
      setDrafts((previous) => {
        const next = { ...previous };
        delete next[station.id];
        return next;
      });
      setNotice(
        data.renamedItems
          ? `Station renamed · ${data.renamedItems} menu item(s) updated`
          : 'Station updated'
      );
      router.refresh();
    } catch (requestError) {
      setError(requestError.message);
    } finally {
      setBusy('');
    }
  }

  async function deleteStation(station) {
    if (
      !window.confirm(
        `Delete station ${station.name}? Only possible when no menu items use it.`
      )
    ) {
      return;
    }
    setBusy(station.id);
    setError('');
    setNotice('');
    try {
      await request(`/api/stations/${station.id}`, { method: 'DELETE' });
      setNotice(`${station.name} deleted`);
      router.refresh();
    } catch (requestError) {
      setError(requestError.message);
    } finally {
      setBusy('');
    }
  }

  async function bulkDeleteStations() {
    if (
      !window.confirm(
        `Delete ${count} station(s)? Stations still used by menu items are skipped.`
      )
    ) {
      return;
    }
    setBulkBusy(true);
    setError('');
    setNotice('');
    try {
      const data = await request('/api/stations/bulk', {
        method: 'POST',
        body: JSON.stringify({ ids: selected }),
      });
      setNotice(
        data.blocked?.length
          ? `${data.deleted} deleted · skipped: ${data.blocked.join(', ')}`
          : `${data.deleted} station(s) deleted`
      );
      clear();
      router.refresh();
    } catch (requestError) {
      setError(requestError.message);
    } finally {
      setBulkBusy(false);
    }
  }

  return (
    <div className="stack">
      {error ? <div className="notice notice-error">{error}</div> : null}
      {notice ? <div className="notice notice-ok">{notice}</div> : null}
      <BulkBar
        count={count}
        busy={bulkBusy}
        onClear={clear}
        onDelete={bulkDeleteStations}
        noun="station"
      />

      <section className="card">
        <header>
          <h2>Stations</h2>
          <span className="spacer" />
          <span className="muted small">{stations.length} total</span>
        </header>
        <div className="card-body tight">
          {stations.length === 0 ? (
            <div className="empty">No stations yet.</div>
          ) : (
            <div className="table-scroll">
              <table className="data">
                <thead>
                  <tr>
                    <th style={{ width: 34 }}>
                      <input
                        type="checkbox"
                        aria-label="Select all stations"
                        checked={count > 0 && count === deletable.length}
                        onChange={(event) =>
                          replace(
                            event.target.checked
                              ? deletable.map((station) => station.id)
                              : []
                          )
                        }
                      />
                    </th>
                    <th>Name</th>
                    <th>Printer</th>
                    <th>Items</th>
                    <th style={{ textAlign: 'right' }}>Actions</th>
                  </tr>
                </thead>
                <tbody>
                  {stations.map((station) => {
                    const draft = draftFor(station);
                    const dirty = isDirty(station);
                    const rowBusy = busy === station.id;
                    const isOrphan = Boolean(station.orphan);

                    return (
                      <tr key={station.id}>
                        <td>
                          {!isOrphan ? (
                            <input
                              type="checkbox"
                              aria-label={`Select ${station.name}`}
                              checked={isSelected(station.id)}
                              onChange={() => toggle(station.id)}
                            />
                          ) : null}
                        </td>
                        <td>
                          <input
                            type="text"
                            value={draft.name}
                            disabled={rowBusy || isOrphan}
                            onChange={(event) =>
                              setDraft(station, { name: event.target.value })
                            }
                          />
                          {isOrphan ? (
                            <span className="hint">
                              Used by menu items but missing from the station list.
                              Add it to manage it.
                            </span>
                          ) : null}
                        </td>
                        <td>
                          <input
                            type="text"
                            value={draft.printerName}
                            placeholder="Bluetooth printer name"
                            disabled={rowBusy || isOrphan}
                            onChange={(event) =>
                              setDraft(station, { printerName: event.target.value })
                            }
                          />
                        </td>
                        <td className="num">{station.itemCount}</td>
                        <td style={{ textAlign: 'right' }}>
                          <div className="inline" style={{ justifyContent: 'flex-end' }}>
                            {dirty ? (
                              <button
                                className="btn btn-primary btn-sm"
                                type="button"
                                disabled={rowBusy}
                                onClick={() => saveStation(station)}
                              >
                                {rowBusy ? '…' : 'Save'}
                              </button>
                            ) : null}
                            {!isOrphan ? (
                              <button
                                className="btn btn-danger btn-sm"
                                type="button"
                                disabled={rowBusy || station.itemCount > 0}
                                title={
                                  station.itemCount > 0
                                    ? 'Reassign or delete its menu items first'
                                    : 'Delete station'
                                }
                                onClick={() => deleteStation(station)}
                              >
                                Delete
                              </button>
                            ) : null}
                          </div>
                        </td>
                      </tr>
                    );
                  })}
                </tbody>
              </table>
            </div>
          )}
        </div>
      </section>

      <section className="card">
        <header>
          <h2>Add station</h2>
        </header>
        <div className="card-body">
          <form className="form-grid" onSubmit={createStation}>
            <label className="field">
              <span>Name</span>
              <input
                type="text"
                required
                value={newStation.name}
                placeholder="e.g. Grill"
                onChange={(event) =>
                  setNewStation((previous) => ({
                    ...previous,
                    name: event.target.value,
                  }))
                }
              />
            </label>
            <label className="field">
              <span>Printer</span>
              <input
                type="text"
                value={newStation.printerName}
                placeholder="Optional"
                onChange={(event) =>
                  setNewStation((previous) => ({
                    ...previous,
                    printerName: event.target.value,
                  }))
                }
              />
            </label>
            <div className="actions" style={{ alignSelf: 'end' }}>
              <button className="btn btn-primary" type="submit" disabled={busy === 'new'}>
                {busy === 'new' ? 'Adding…' : 'Add station'}
              </button>
            </div>
          </form>
        </div>
      </section>
    </div>
  );
}
