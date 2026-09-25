export function formatMoney(value, currency = 'RM') {
  const number = Number(value);
  const safe = Number.isFinite(number) ? number : 0;
  return `${currency} ${safe.toFixed(2)}`;
}

export function formatPercent(fraction) {
  const number = Number(fraction);
  const safe = Number.isFinite(number) ? number : 0;
  return `${(safe * 100).toFixed(safe * 100 % 1 === 0 ? 0 : 2)}%`;
}

export function formatDateTime(value) {
  if (!value) return '—';
  const date = new Date(value);
  if (Number.isNaN(date.getTime())) return '—';
  return date.toLocaleString('en-GB', {
    day: '2-digit',
    month: 'short',
    year: 'numeric',
    hour: '2-digit',
    minute: '2-digit',
  });
}

export function formatPriceChange(entry, currency = 'RM') {
  if (entry.action === 'create') {
    return `created at ${formatMoney(entry.newPrice ?? 0, currency)}`;
  }
  if (entry.action === 'delete') {
    return `deleted (was ${formatMoney(entry.oldPrice ?? 0, currency)})`;
  }
  const oldPrice = formatMoney(entry.oldPrice ?? 0, currency);
  const newPrice = formatMoney(entry.newPrice ?? 0, currency);
  if (entry.oldPrice === entry.newPrice) return `updated (${newPrice})`;
  return `${oldPrice} → ${newPrice}`;
}
