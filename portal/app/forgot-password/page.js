'use client';

import { useState } from 'react';
import Link from 'next/link';

export default function ForgotPasswordPage() {
  const [username, setUsername] = useState('');
  const [sent, setSent] = useState(false);
  const [mailConfigured, setMailConfigured] = useState(true);
  const [error, setError] = useState('');
  const [busy, setBusy] = useState(false);

  async function submit(event) {
    event.preventDefault();
    setBusy(true);
    setError('');
    try {
      const response = await fetch('/api/auth/forgot', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ username }),
      });
      const data = await response.json().catch(() => ({}));
      if (!response.ok) throw new Error(data.error || 'Could not send the reset email');
      setMailConfigured(data.mailConfigured !== false);
      setSent(true);
    } catch (forgotError) {
      setError(forgotError.message);
    } finally {
      setBusy(false);
    }
  }

  return (
    <div className="login-wrap">
      <form className="card login-card" onSubmit={submit}>
        <header>
          <h2>Forgot password</h2>
        </header>
        <div className="card-body">
          {sent ? (
            <>
              <div className="notice">
                If <span className="mono">{username}</span> has an account, a
                reset link is on its way.
              </div>
              {!mailConfigured ? (
                <div className="notice notice-error">
                  Email sending is not set up on this server yet, so no message
                  could be sent. Ask an administrator to set the Mailjet keys,
                  or to reset your password from the Users page.
                </div>
              ) : null}
              <div className="actions">
                <Link className="btn" href="/login">
                  Back to sign in
                </Link>
              </div>
            </>
          ) : (
            <>
              <p className="muted small">
                Enter your account email and we will send a link to choose a new
                password.
              </p>

              {error ? <div className="notice notice-error">{error}</div> : null}

              <label className="field">
                <span>Email</span>
                <input
                  type="email"
                  value={username}
                  autoComplete="username"
                  autoFocus
                  onChange={(event) => setUsername(event.target.value)}
                />
              </label>

              <div className="actions">
                <button
                  type="submit"
                  className="btn btn-primary"
                  disabled={busy || !username}
                >
                  {busy ? 'Sending…' : 'Send reset link'}
                </button>
                <Link className="btn" href="/login">
                  Back to sign in
                </Link>
              </div>
            </>
          )}
        </div>
      </form>
    </div>
  );
}
