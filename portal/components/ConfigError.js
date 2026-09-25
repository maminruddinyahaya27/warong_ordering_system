export default function ConfigError({ error }) {
  const message = error instanceof Error ? error.message : String(error);

  // Only a connection/credential problem is actually fixed in .env.local.
  const looksLikeConfig =
    /MONGODB_URI|REPLACE_WITH_DB_PASSWORD|AUTH_SECRET|ECONNREFUSED|ENOTFOUND|Server selection|bad auth|Authentication failed|querySrv|timed out/i.test(
      message
    );
  const looksLikeIndexConflict = /E11000|duplicate key/i.test(message);

  return (
    <div className="notice notice-error">
      <strong>{looksLikeConfig ? 'Database not reachable.' : 'Something went wrong.'}</strong>
      <div style={{ marginTop: 6 }}>{message}</div>
      {looksLikeConfig ? (
        <div style={{ marginTop: 10, color: 'var(--muted)' }}>
          Open <span className="mono">portal/.env.local</span>, set{' '}
          <span className="mono">MONGODB_URI</span> with the real database password,
          then reload. Seed the menu with{' '}
          <span className="mono">npm run seed</span>.
        </div>
      ) : null}
      {looksLikeIndexConflict ? (
        <div style={{ marginTop: 10, color: 'var(--muted)' }}>
          A leftover single-restaurant index is blocking this write. Run{' '}
          <span className="mono">npm run repair-indexes</span> once, then reload.
        </div>
      ) : null}
    </div>
  );
}
