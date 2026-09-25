'use client';

import { useState } from 'react';
import Link from 'next/link';

export default function ResetPasswordForm({ token }) {
  const [password, setPassword] = useState('');
  const [confirm, setConfirm] = useState('');
  const [done, setDone] = useState(false);
  const [error, setError] = useState('');
  const [busy, setBusy] = useState(false);

  async function submit(event) {
    event.preventDefault();
    setError('');
    if (password !== confirm) {
      setError('The two passwords do not match');
      return;
    }
    setBusy(true);
    try {
      const response = await fetch('/api/auth/reset', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ token, password }),
      });
      const data = await response.json().catch(() => ({}));
      if (!response.ok) throw new Error(data.error || 'Could not reset the password');
      setDone(true);
    } catch (resetError) {
      setError(resetError.message);
    } finally {
      setBusy(false);
    }
  }

  return (
    <div className="card login-card">
      <header>
        <h2>Choose a new password</h2>
      </header>
      <div className="card-body">
        {!token ? (
          <>
            <div className="notice notice-error">
              This reset link is missing its token. Request a new email.
            </div>
            <div className="actions">
              <Link className="btn" href="/forgot-password">
                Request a new link
              </Link>
            </div>
          </>
        ) : done ? (
          <>
            <div className="notice">Your password has been changed.</div>
            <div className="actions">
              <Link className="btn btn-primary" href="/login">
                Sign in
              </Link>
            </div>
          </>
        ) : (
          <form onSubmit={submit}>
            <p className="muted small">
              Pick a new password for your account. You will be signed out of
              other devices.
            </p>

            {error ? <div className="notice notice-error">{error}</div> : null}

            <label className="field">
              <span>New password</span>
              <input
                type="password"
                value={password}
                autoComplete="new-password"
                autoFocus
                minLength={8}
                onChange={(event) => setPassword(event.target.value)}
              />
            </label>

            <label className="field">
              <span>Confirm password</span>
              <input
                type="password"
                value={confirm}
                autoComplete="new-password"
                minLength={8}
                onChange={(event) => setConfirm(event.target.value)}
              />
            </label>

            <div className="actions">
              <button
                type="submit"
                className="btn btn-primary"
                disabled={busy || password.length < 8 || !confirm}
              >
                {busy ? 'Saving…' : 'Set new password'}
              </button>
            </div>
          </form>
        )}
      </div>
    </div>
  );
}
