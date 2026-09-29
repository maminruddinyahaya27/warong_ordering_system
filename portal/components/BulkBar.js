'use client';

/// The bar shown above a table while rows are selected for bulk delete.
export default function BulkBar({ count, busy, onClear, onDelete, noun = 'item' }) {
  if (count === 0) return null;

  return (
    <div
      className="notice"
      style={{ display: 'flex', alignItems: 'center', gap: 12, flexWrap: 'wrap' }}
    >
      <span style={{ flex: 1 }}>
        {count} {noun}
        {count === 1 ? '' : 's'} selected
      </span>
      <button
        type="button"
        className="btn btn-sm"
        onClick={onClear}
        disabled={busy}
      >
        Clear
      </button>
      <button
        type="button"
        className="btn btn-sm btn-danger"
        onClick={onDelete}
        disabled={busy}
      >
        {busy ? 'Deleting…' : 'Delete selected'}
      </button>
    </div>
  );
}
