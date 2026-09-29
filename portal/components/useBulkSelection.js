'use client';

import { useState } from 'react';

/// Row selection shared by the portal tables that support bulk delete.
export default function useBulkSelection() {
  const [selected, setSelected] = useState([]);

  const isSelected = (id) => selected.includes(id);

  const toggle = (id) =>
    setSelected((previous) =>
      previous.includes(id)
        ? previous.filter((value) => value !== id)
        : [...previous, id]
    );

  const replace = (ids) => setSelected(ids);
  const clear = () => setSelected([]);

  return {
    selected,
    count: selected.length,
    isSelected,
    toggle,
    replace,
    clear,
  };
}
