'use client';

import { useState } from 'react';
import Link from 'next/link';
import { useRouter } from 'next/navigation';

export default function LoginPage() {
  const router = useRouter();
  const [username, setUsername] = useState('');
  const [password, setPassword] = useState('');
  const [error, setError] = useState('');
  const [busy, setBusy] = useState(false);

  async function submit(event) {
    event.preventDefault();
    setBusy(true);
    setError('');
    try {
      const response = await fetch('/api/auth/login', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ username, password }),
      });
      const data = await response.json().catch(() => ({}));
      if (!response.ok) {
        throw new Error(data.error || `Login failed (${response.status})`);
      }
      router.replace('/');
      router.refresh();
    } catch (loginError) {
      setError(loginError.message);
    } finally {
      setBusy(false);
    }
  }

  return (
    <div className="login-wrap">
      <form className="card login-card" onSubmit={submit}>
        <header>
          <h2>Sign in</h2>
        </header>
        <div className="card-body">
          <p className="muted small">
            Restaurant portal — sign in with the account for your restaurant.
          </p>

          {error ? <div className="notice notice-error">{error}</div> : null}

          <label className="field">
            <span>Username</span>
            <input
              type="text"
              value={username}
              autoComplete="username"
              autoFocus
              onChange={(event) => setUsername(event.target.value)}
            />
          </label>

          <label className="field">
            <span>Password</span>
            <input
              type="password"
              value={password}
              autoComplete="current-password"
              onChange={(event) => setPassword(event.target.value)}
            />
          </label>

          <div className="actions">
            <button
              type="submit"
              className="btn btn-primary"
              disabled={busy || !username || !password}
            >
              {busy ? 'Signing in…' : 'Sign in'}
            </button>
          </div>

          <p className="muted small" style={{ marginTop: 14, marginBottom: 0 }}>
            <Link href="/forgot-password">Forgot password?</Link>
          </p>
        </div>
      </form>
    </div>
  );
}
