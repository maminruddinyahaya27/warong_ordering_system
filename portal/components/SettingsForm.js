'use client';

import { useRouter } from 'next/navigation';
import { useState } from 'react';

export default function SettingsForm({ settings }) {
  const router = useRouter();
  const [form, setForm] = useState({
    restaurantName: settings.restaurantName || '',
    currency: settings.currency || 'RM',
    taxRatePercent: ((settings.taxRate ?? 0.1) * 100).toFixed(2),
  });
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState('');
  const [notice, setNotice] = useState('');

  function update(field, value) {
    setForm((previous) => ({ ...previous, [field]: value }));
  }

  async function submit(event) {
    event.preventDefault();
    setBusy(true);
    setError('');
    setNotice('');

    const taxRate = Number(form.taxRatePercent) / 100;

    try {
      const response = await fetch('/api/settings', {
        method: 'PATCH',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({
          restaurantName: form.restaurantName,
          currency: form.currency,
          taxRate,
        }),
      });
      const data = await response.json().catch(() => ({}));
      if (!response.ok) {
        throw new Error(data.error || `Request failed (${response.status})`);
      }
      setNotice('Settings saved');
      router.refresh();
    } catch (requestError) {
      setError(requestError.message);
    } finally {
      setBusy(false);
    }
  }

  return (
    <form className="stack" onSubmit={submit}>
      {error ? <div className="notice notice-error">{error}</div> : null}
      {notice ? <div className="notice notice-ok">{notice}</div> : null}

      <section className="card">
        <header>
          <h2>Restaurant settings</h2>
        </header>
        <div className="card-body">
          <div className="form-grid">
            <label className="field">
              <span>Restaurant name</span>
              <input
                type="text"
                required
                value={form.restaurantName}
                onChange={(event) => update('restaurantName', event.target.value)}
              />
            </label>

            <label className="field">
              <span>Currency</span>
              <input
                type="text"
                required
                maxLength={8}
                value={form.currency}
                onChange={(event) => update('currency', event.target.value)}
              />
              <span className="hint">Shown next to every price (e.g. RM).</span>
            </label>

            <label className="field">
              <span>Tax rate (%)</span>
              <input
                type="number"
                min="0"
                max="100"
                step="0.1"
                value={form.taxRatePercent}
                onChange={(event) => update('taxRatePercent', event.target.value)}
              />
              <span className="hint">
                The ordering apps apply this on top of the subtotal.
              </span>
            </label>
          </div>
        </div>
      </section>

      <div className="actions">
        <button className="btn btn-primary" type="submit" disabled={busy}>
          {busy ? 'Saving…' : 'Save settings'}
        </button>
      </div>
    </form>
  );
}
