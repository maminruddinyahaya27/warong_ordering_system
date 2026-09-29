/// Shared helpers for the tables/QR API.

/// The public origin used in QR links. Prefers PORTAL_BASE_URL so codes are
/// stable; falls back to the host the request came in on.
export function publicBase(request) {
  const configured = (process.env.PORTAL_BASE_URL || process.env.APP_ORIGIN || '')
    .trim()
    .replace(/\/+$/, '');
  if (configured) return configured;

  const host =
    request.headers.get('x-forwarded-host') || request.headers.get('host') || '';
  if (!host) return '';

  const proto = request.headers.get('x-forwarded-proto') || 'http';
  return `${proto}://${host}`;
}

/// The QR target carries the tenant id (`t`) and the table token (`table`).
export function tableUrl(base, tenantId, token) {
  if (!base || !tenantId) return '';
  return `${base}/order?t=${encodeURIComponent(tenantId)}&table=${encodeURIComponent(token)}`;
}

export function serializeTable(table, tenantId, base) {
  return {
    id: String(table._id),
    label: table.label,
    token: table.token,
    active: table.active !== false,
    sortOrder: table.sortOrder ?? 0,
    url: tableUrl(base, tenantId, table.token),
  };
}
