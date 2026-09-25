'use client';

import Link from 'next/link';
import { useRouter } from 'next/navigation';
import { useState } from 'react';

export default function GroupManager({ groups, stations = [], ungroupedCount = 0 }) {
  const router = useRouter();
  const [drafts, setDrafts] = useState({});
  const [newGroup, setNewGroup] = useState({
    name: '',
    description: '',
    color: '',
    station: '',
  });
  const [reassign, setReassign] = useState({});
  const [busy, setBusy] = useState('');
  const [error, setError] = useState('');
  const [notice, setNotice] = useState('');

  function draftFor(group) {
    return (
      drafts[group.id] || {
        name: group.name,
        description: group.description || '',
        color: group.color || '',
        station: group.station || '',
      }
    );
  }

  function setDraft(group, patch) {
    setDrafts((previous) => ({
      ...previous,
      [group.id]: { ...draftFor(group), ...patch },
    }));
  }

  function isDirty(group) {
    const draft = drafts[group.id];
    if (!draft) return false;
    return (
      draft.name !== group.name ||
      draft.description !== (group.description || '') ||
      draft.color !== (group.color || '') ||
      draft.station !== (group.station || '')
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

  async function createGroup(event) {
    event.preventDefault();
    setBusy('new');
    setError('');
    setNotice('');
    try {
      await request('/api/groups', {
        method: 'POST',
        body: JSON.stringify(newGroup),
      });
      setNewGroup({ name: '', description: '', color: '', station: '' });
      setNotice(`Group "${newGroup.name}" created — add items to it now.`);
      router.refresh();
    } catch (requestError) {
      setError(requestError.message);
    } finally {
      setBusy('');
    }
  }

  async function saveGroup(group) {
    setBusy(group.id);
    setError('');
    setNotice('');
    try {
      const data = await request(`/api/groups/${group.id}`, {
        method: 'PATCH',
        body: JSON.stringify(draftFor(group)),
      });
      setDrafts((previous) => {
        const next = { ...previous };
        delete next[group.id];
        return next;
      });
      setNotice(
        data.renamedItems
          ? `Group renamed — ${data.renamedItems} item(s) updated`
          : 'Group updated'
      );
      router.refresh();
    } catch (requestError) {
      setError(requestError.message);
    } finally {
      setBusy('');
    }
  }

  async function deleteGroup(group) {
    const target = reassign[group.id] || 'none';
    const targetLabel =
      target === 'none'
        ? 'Ungrouped'
        : (groups.find((candidate) => candidate.id === target)?.name ?? target);

    const message =
      group.itemCount > 0
        ? `Delete "${group.name}" and move its ${group.itemCount} item(s) to "${targetLabel}"?`
        : `Delete group "${group.name}"?`;

    if (!window.confirm(message)) return;

    setBusy(group.id);
    setError('');
    setNotice('');
    try {
      const data = await request(
        `/api/groups/${group.id}?reassignTo=${encodeURIComponent(target)}`,
        { method: 'DELETE' }
      );
      setNotice(
        data.movedItems
          ? `${group.name} deleted — ${data.movedItems} item(s) moved to ${targetLabel}`
          : `${group.name} deleted`
      );
      router.refresh();
    } catch (requestError) {
      setError(requestError.message);
    } finally {
      setBusy('');
    }
  }

  return (
    <div className="stack">
      {error ? <div className="notice notice-error">{error}</div> : null}
      {notice ? <div className="notice notice-ok">{notice}</div> : null}

      <section className="card">
        <header>
          <h2>Groups</h2>
          <span className="spacer" />
          <span className="muted small">
            {groups.length} group{groups.length === 1 ? '' : 's'}
            {ungroupedCount ? ` · ${ungroupedCount} ungrouped item(s)` : ''}
          </span>
        </header>
        <div className="card-body tight">
          {groups.length === 0 ? (
            <div className="empty">
              No groups yet. Create one below, then add items to it.
            </div>
          ) : (
            <div className="table-scroll">
              <table className="data">
                <thead>
                  <tr>
                    <th>Group</th>
                    <th>Description</th>
                    <th>Colour</th>
                    <th>Station</th>
                    <th>Items</th>
                    <th>If deleted, move items to</th>
                    <th style={{ textAlign: 'right' }}>Actions</th>
                  </tr>
                </thead>
                <tbody>
                  {groups.map((group) => {
                    const draft = draftFor(group);
                    const dirty = isDirty(group);
                    const rowBusy = busy === group.id;

                    return (
                      <tr key={group.id}>
                        <td>
                          <input
                            type="text"
                            value={draft.name}
                            disabled={rowBusy}
                            onChange={(event) =>
                              setDraft(group, { name: event.target.value })
                            }
                            aria-label={`Name of ${group.name}`}
                          />
                        </td>
                        <td>
                          <input
                            type="text"
                            value={draft.description}
                            placeholder="Optional"
                            disabled={rowBusy}
                            onChange={(event) =>
                              setDraft(group, { description: event.target.value })
                            }
                            aria-label={`Description of ${group.name}`}
                          />
                        </td>
                        <td>
                          <div className="inline" style={{ flexWrap: 'nowrap' }}>
                            <input
                              type="color"
                              value={draft.color || '#2E7D32'}
                              disabled={rowBusy}
                              onChange={(event) =>
                                setDraft(group, {
                                  color: event.target.value.toUpperCase(),
                                })
                              }
                              aria-label={`Colour of ${group.name}`}
                              style={{ width: 40, height: 32, padding: 2 }}
                            />
                            <input
                              type="text"
                              value={draft.color}
                              placeholder="none"
                              maxLength={7}
                              disabled={rowBusy}
                              onChange={(event) =>
                                setDraft(group, { color: event.target.value })
                              }
                              aria-label={`Colour hex of ${group.name}`}
                              style={{ width: 92 }}
                            />
                          </div>
                        </td>
                        <td>
                          <select
                            value={draft.station}
                            disabled={rowBusy}
                            onChange={(event) =>
                              setDraft(group, { station: event.target.value })
                            }
                            aria-label={`Station of ${group.name}`}
                          >
                            <option value="">— item station —</option>
                            {stations.map((station) => (
                              <option key={station} value={station}>
                                {station}
                              </option>
                            ))}
                          </select>
                        </td>
                        <td>
                          <span className="badge">{group.itemCount}</span>
                        </td>
                        <td>
                          <select
                            value={reassign[group.id] || 'none'}
                            disabled={rowBusy || group.itemCount === 0}
                            onChange={(event) =>
                              setReassign((previous) => ({
                                ...previous,
                                [group.id]: event.target.value,
                              }))
                            }
                            aria-label={`Reassign target for ${group.name}`}
                          >
                            <option value="none">Ungrouped</option>
                            {groups
                              .filter((candidate) => candidate.id !== group.id)
                              .map((candidate) => (
                                <option key={candidate.id} value={candidate.id}>
                                  {candidate.name}
                                </option>
                              ))}
                          </select>
                        </td>
                        <td style={{ textAlign: 'right' }}>
                          <div className="inline" style={{ justifyContent: 'flex-end' }}>
                            <Link
                              className="btn btn-sm"
                              href={`/menu/new?group=${group.id}`}
                            >
                              + Add item
                            </Link>
                            {dirty ? (
                              <button
                                className="btn btn-primary btn-sm"
                                type="button"
                                disabled={rowBusy}
                                onClick={() => saveGroup(group)}
                              >
                                {rowBusy ? '…' : 'Save'}
                              </button>
                            ) : null}
                            <button
                              className="btn btn-danger btn-sm"
                              type="button"
                              disabled={rowBusy}
                              onClick={() => deleteGroup(group)}
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
          )}
        </div>
      </section>

      <section className="card">
        <header>
          <h2>Create group</h2>
        </header>
        <div className="card-body">
          <form className="form-grid" onSubmit={createGroup}>
            <label className="field">
              <span>Name</span>
              <input
                type="text"
                required
                maxLength={60}
                value={newGroup.name}
                placeholder="e.g. Rice"
                onChange={(event) =>
                  setNewGroup((previous) => ({
                    ...previous,
                    name: event.target.value,
                  }))
                }
              />
            </label>
            <label className="field">
              <span>Description</span>
              <input
                type="text"
                maxLength={200}
                value={newGroup.description}
                placeholder="Optional"
                onChange={(event) =>
                  setNewGroup((previous) => ({
                    ...previous,
                    description: event.target.value,
                  }))
                }
              />
            </label>
            <label className="field">
              <span>Colour</span>
              <div className="inline" style={{ flexWrap: 'nowrap' }}>
                <input
                  type="color"
                  value={newGroup.color || '#2E7D32'}
                  onChange={(event) =>
                    setNewGroup((previous) => ({
                      ...previous,
                      color: event.target.value.toUpperCase(),
                    }))
                  }
                  aria-label="New group colour"
                  style={{ width: 48, height: 34, padding: 2 }}
                />
                <input
                  type="text"
                  maxLength={7}
                  value={newGroup.color}
                  placeholder="#2E7D32 (blank = none)"
                  onChange={(event) =>
                    setNewGroup((previous) => ({
                      ...previous,
                      color: event.target.value,
                    }))
                  }
                />
              </div>
            </label>
            <label className="field">
              <span>Station</span>
              <select
                value={newGroup.station}
                onChange={(event) =>
                  setNewGroup((previous) => ({
                    ...previous,
                    station: event.target.value,
                  }))
                }
              >
                <option value="">— item station —</option>
                {stations.map((station) => (
                  <option key={station} value={station}>
                    {station}
                  </option>
                ))}
              </select>
            </label>
            <div className="actions" style={{ alignSelf: 'end' }}>
              <button
                className="btn btn-primary"
                type="submit"
                disabled={busy === 'new'}
              >
                {busy === 'new' ? 'Creating…' : 'Create group'}
              </button>
            </div>
          </form>
        </div>
      </section>
    </div>
  );
}
