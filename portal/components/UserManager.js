'use client';

import { useState } from 'react';

import BulkBar from '@/components/BulkBar';
import useBulkSelection from '@/components/useBulkSelection';

function roleOptions(canManageAllTenants) {
  return canManageAllTenants
    ? ['superadmin', 'owner', 'staff']
    : ['owner', 'staff'];
}

export default function UserManager({ initial }) {
  const [users, setUsers] = useState(initial?.users || []);
  const [tenants, setTenants] = useState(initial?.tenants || []);
  const [currentUserId, setCurrentUserId] = useState(initial?.currentUserId || '');
  const [canManageAllTenants, setCanManageAllTenants] = useState(
    Boolean(initial?.canManageAllTenants)
  );
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState('');
  const [notice, setNotice] = useState('');

  const [form, setForm] = useState({
    username: '',
    name: '',
    password: '',
    role: 'staff',
    tenant: '',
  });
  const [busy, setBusy] = useState(false);
  const [bulkBusy, setBulkBusy] = useState(false);
  const { selected, count, isSelected, toggle, replace, clear } =
    useBulkSelection();

  const selectableUsers = users.filter((user) => user.id !== currentUserId);

  async function load() {
    setLoading(true);
    try {
      const response = await fetch('/api/users', { cache: 'no-store' });
      const data = await response.json().catch(() => ({}));
      if (!response.ok) throw new Error(data.error || 'Could not load users');
      setUsers(data.users || []);
      setTenants(data.tenants || []);
      setCurrentUserId(data.currentUserId || '');
      setCanManageAllTenants(Boolean(data.canManageAllTenants));
      setError('');
    } catch (loadError) {
      setError(loadError.message);
    } finally {
      setLoading(false);
    }
  }

  function flash(message) {
    setNotice(message);
    setError('');
  }

  async function addUser(event) {
    event.preventDefault();
    setBusy(true);
    setError('');
    setNotice('');
    try {
      const response = await fetch('/api/users', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify(form),
      });
      const data = await response.json().catch(() => ({}));
      if (!response.ok) throw new Error(data.error || 'Could not create user');
      setForm({ username: '', name: '', password: '', role: 'staff', tenant: '' });
      flash(`Created ${data.user.username}`);
      await load();
    } catch (createError) {
      setError(createError.message);
    } finally {
      setBusy(false);
    }
  }

  async function patchUser(id, patch, successMessage) {
    setError('');
    setNotice('');
    try {
      const response = await fetch(`/api/users/${id}`, {
        method: 'PATCH',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify(patch),
      });
      const data = await response.json().catch(() => ({}));
      if (!response.ok) throw new Error(data.error || 'Update failed');
      flash(successMessage || 'Saved');
      await load();
    } catch (updateError) {
      setError(updateError.message);
    }
  }

  async function bulkDeleteUsers() {
    if (!window.confirm(`Delete ${count} account(s)? This cannot be undone.`)) {
      return;
    }
    setBulkBusy(true);
    setError('');
    setNotice('');
    try {
      const response = await fetch('/api/users/bulk', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ ids: selected }),
      });
      const data = await response.json().catch(() => ({}));
      if (!response.ok) throw new Error(data.error || 'Bulk delete failed');
      setNotice(
        data.blocked?.length
          ? `${data.deleted} deleted · skipped: ${data.blocked.join(', ')}`
          : `${data.deleted} account(s) deleted`
      );
      clear();
      await load();
    } catch (deleteError) {
      setError(deleteError.message);
    } finally {
      setBulkBusy(false);
    }
  }

  async function removeUser(user) {
    if (!window.confirm(`Delete ${user.username}? This cannot be undone.`)) return;
    setError('');
    setNotice('');
    try {
      const response = await fetch(`/api/users/${user.id}`, { method: 'DELETE' });
      const data = await response.json().catch(() => ({}));
      if (!response.ok) throw new Error(data.error || 'Delete failed');
      flash(`Deleted ${user.username}`);
      await load();
    } catch (deleteError) {
      setError(deleteError.message);
    }
  }

  async function setPassword(user) {
    const password = window.prompt(`New password for ${user.username} (min 8 characters):`);
    if (!password) return;
    await patchUser(user.id, { password }, `Password updated for ${user.username}`);
  }

  async function emailReset(user) {
    setError('');
    setNotice('');
    try {
      const response = await fetch('/api/auth/forgot', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ username: user.username }),
      });
      const data = await response.json().catch(() => ({}));
      if (!response.ok) throw new Error(data.error || 'Could not send reset email');
      flash(
        data.mailConfigured
          ? `Reset email sent to ${user.username}`
          : `Email is not configured, so no message was sent to ${user.username}. Set the Mailjet keys to enable it.`
      );
    } catch (resetError) {
      setError(resetError.message);
    }
  }

  const roles = roleOptions(canManageAllTenants);

  return (
    <>
      {error ? <div className="notice notice-error">{error}</div> : null}
      {notice ? <div className="notice">{notice}</div> : null}
      <BulkBar
        count={count}
        busy={bulkBusy}
        onClear={clear}
        onDelete={bulkDeleteUsers}
        noun="account"
      />

      <section className="card">
        <header>
          <h2>Add user</h2>
        </header>
        <div className="card-body">
          <form className="form-grid" onSubmit={addUser}>
            <label className="field">
              <span>Email (username)</span>
              <input
                type="email"
                value={form.username}
                required
                onChange={(event) => setForm({ ...form, username: event.target.value })}
              />
            </label>
            <label className="field">
              <span>Name</span>
              <input
                type="text"
                value={form.name}
                onChange={(event) => setForm({ ...form, name: event.target.value })}
              />
            </label>
            <label className="field">
              <span>Temporary password</span>
              <input
                type="text"
                value={form.password}
                required
                minLength={8}
                onChange={(event) => setForm({ ...form, password: event.target.value })}
              />
            </label>
            <label className="field">
              <span>Role</span>
              <select
                value={form.role}
                onChange={(event) => setForm({ ...form, role: event.target.value })}
              >
                {roles.map((role) => (
                  <option key={role} value={role}>
                    {role}
                  </option>
                ))}
              </select>
            </label>
            {canManageAllTenants ? (
              <label className="field">
                <span>Restaurant</span>
                <select
                  value={form.tenant}
                  onChange={(event) => setForm({ ...form, tenant: event.target.value })}
                >
                  <option value="">(my restaurant)</option>
                  {tenants.map((tenant) => (
                    <option key={tenant.id} value={tenant.slug}>
                      {tenant.name}
                    </option>
                  ))}
                </select>
              </label>
            ) : null}
            <div className="actions">
              <button type="submit" className="btn btn-primary" disabled={busy}>
                {busy ? 'Adding…' : '+ Add user'}
              </button>
            </div>
          </form>
        </div>
      </section>

      <section className="card">
        <header>
          <h2>Users</h2>
          <span className="spacer" />
          <span className="muted small">{users.length} account(s)</span>
        </header>
        <div className="card-body tight">
          {loading ? (
            <div className="empty">Loading…</div>
          ) : users.length === 0 ? (
            <div className="empty">No users yet.</div>
          ) : (
            <div className="table-scroll">
              <table className="data">
                <thead>
                  <tr>
                    <th style={{ width: 34 }}>
                      <input
                        type="checkbox"
                        aria-label="Select all users"
                        checked={
                          count > 0 && count === selectableUsers.length
                        }
                        onChange={(event) =>
                          replace(
                            event.target.checked
                              ? selectableUsers.map((user) => user.id)
                              : []
                          )
                        }
                      />
                    </th>
                    <th>User</th>
                    <th>Role</th>
                    <th>Restaurant</th>
                    <th>Status</th>
                    <th>Last login</th>
                    <th style={{ textAlign: 'right' }}>Actions</th>
                  </tr>
                </thead>
                <tbody>
                  {users.map((user) => {
                    const isSelf = user.id === currentUserId;
                    return (
                      <tr key={user.id}>
                        <td>
                          {!isSelf ? (
                            <input
                              type="checkbox"
                              aria-label={`Select ${user.username}`}
                              checked={isSelected(user.id)}
                              onChange={() => toggle(user.id)}
                            />
                          ) : null}
                        </td>
                        <td>
                          <div>
                            {user.name || user.username}
                            {isSelf ? <span className="badge"> you</span> : null}
                          </div>
                          <div className="muted mono small">{user.username}</div>
                        </td>
                        <td>
                          <select
                            value={user.role}
                            disabled={isSelf}
                            onChange={(event) =>
                              patchUser(
                                user.id,
                                { role: event.target.value },
                                `${user.username} is now ${event.target.value}`
                              )
                            }
                          >
                            {(roles.includes(user.role)
                              ? roles
                              : [user.role, ...roles]
                            ).map((role) => (
                              <option key={role} value={role}>
                                {role}
                              </option>
                            ))}
                          </select>
                        </td>
                        <td className="muted small">{user.tenant.name || '—'}</td>
                        <td>
                          <span className={`badge ${user.active ? 'badge-ok' : 'badge-err'}`}>
                            {user.active ? 'active' : 'disabled'}
                          </span>
                        </td>
                        <td className="muted small">
                          {user.lastLoginAt
                            ? new Date(user.lastLoginAt).toLocaleString()
                            : 'never'}
                        </td>
                        <td style={{ textAlign: 'right' }}>
                          <div className="actions" style={{ justifyContent: 'flex-end' }}>
                            <button
                              type="button"
                              className="btn btn-sm"
                              onClick={() => emailReset(user)}
                            >
                              Email reset
                            </button>
                            <button
                              type="button"
                              className="btn btn-sm"
                              onClick={() => setPassword(user)}
                            >
                              Set password
                            </button>
                            {!isSelf ? (
                              <>
                                <button
                                  type="button"
                                  className="btn btn-sm"
                                  onClick={() =>
                                    patchUser(
                                      user.id,
                                      { active: !user.active },
                                      user.active
                                        ? `${user.username} disabled`
                                        : `${user.username} enabled`
                                    )
                                  }
                                >
                                  {user.active ? 'Disable' : 'Enable'}
                                </button>
                                <button
                                  type="button"
                                  className="btn btn-sm btn-danger"
                                  onClick={() => removeUser(user)}
                                >
                                  Delete
                                </button>
                              </>
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
    </>
  );
}
