'use client';

import { usePathname, useRouter, useSearchParams } from 'next/navigation';
import { useState } from 'react';

export default function MenuFilters({ stations, groups = [], initial, resultCount }) {
  const router = useRouter();
  const pathname = usePathname();
  const searchParams = useSearchParams();
  const [search, setSearch] = useState(initial.search || '');

  function apply(next) {
    const params = new URLSearchParams(searchParams.toString());
    for (const [key, value] of Object.entries(next)) {
      if (value) params.set(key, value);
      else params.delete(key);
    }
    const query = params.toString();
    router.push(query ? `${pathname}?${query}` : pathname);
  }

  const hasFilters = Boolean(
    initial.search || initial.station || initial.available || initial.group
  );

  return (
    <form
      className="filters"
      onSubmit={(event) => {
        event.preventDefault();
        apply({ search });
      }}
    >
      <label className="field" style={{ minWidth: 210 }}>
        <span>Search</span>
        <input
          type="search"
          value={search}
          placeholder="Name or SKU…"
          onChange={(event) => setSearch(event.target.value)}
        />
      </label>

      <label className="field">
        <span>Station</span>
        <select
          value={initial.station || ''}
          onChange={(event) => apply({ station: event.target.value })}
        >
          <option value="">All stations</option>
          {stations.map((station) => (
            <option key={station} value={station}>
              {station}
            </option>
          ))}
        </select>
      </label>

      <label className="field">
        <span>Group</span>
        <select
          value={initial.group || ''}
          onChange={(event) => apply({ group: event.target.value })}
        >
          <option value="">All groups</option>
          {groups.map((group) => (
            <option key={group.id} value={group.id}>
              {group.name}
            </option>
          ))}
          <option value="none">Ungrouped</option>
        </select>
      </label>

      <label className="field">
        <span>Availability</span>
        <select
          value={initial.available || ''}
          onChange={(event) => apply({ available: event.target.value })}
        >
          <option value="">All</option>
          <option value="available">Available</option>
          <option value="unavailable">Sold out / hidden</option>
        </select>
      </label>

      <div className="actions">
        <button className="btn btn-primary" type="submit">
          Search
        </button>
        {hasFilters ? (
          <button
            className="btn"
            type="button"
            onClick={() => {
              setSearch('');
              router.push(pathname);
            }}
          >
            Reset
          </button>
        ) : null}
        <span className="muted small">
          {resultCount} result{resultCount === 1 ? '' : 's'}
        </span>
      </div>
    </form>
  );
}
