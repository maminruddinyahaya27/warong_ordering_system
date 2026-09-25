import { DRINK_OPTION } from '@/lib/constants';

export function normalizePrice(value) {
  if (value === '' || value === null || value === undefined) return null;
  const number = Number(value);
  if (!Number.isFinite(number) || number < 0) return null;
  return Math.round(number * 100) / 100;
}

export function validateMenuItem(body, { partial = false } = {}) {
  const errors = [];
  const values = {};

  if (!partial || body.name !== undefined) {
    const name = String(body.name ?? '').trim();
    if (!name) errors.push('name is required');
    else if (name.length > 80) errors.push('name must be 80 characters or fewer');
    else values.name = name;
  }

  if (!partial || body.price !== undefined) {
    const price = normalizePrice(body.price);
    if (price === null) {
      errors.push('price must be a number greater than or equal to 0');
    } else {
      values.price = price;
    }
  }

  if (!partial || body.station !== undefined) {
    const station = String(body.station ?? '').trim();
    if (!station) errors.push('station is required');
    else if (station.length > 40) errors.push('station must be 40 characters or fewer');
    else values.station = station;
  }

  if (body.sku !== undefined) {
    const sku = String(body.sku ?? '').trim();
    if (sku && !/^[A-Za-z0-9_-]{2,32}$/.test(sku)) {
      errors.push('sku may only contain letters, numbers, underscores and dashes');
    } else if (sku) {
      values.sku = sku;
    }
  }

  if (body.group !== undefined) {
    values.group = String(body.group ?? '').trim().slice(0, 80);
  }

  if (body.options !== undefined) {
    const options = String(body.options ?? '').trim();
    if (options && options !== DRINK_OPTION) {
      errors.push(`options only supports "${DRINK_OPTION}" or an empty value`);
    } else {
      values.options = options;
    }
  }

  if (body.description !== undefined) {
    values.description = String(body.description ?? '').trim().slice(0, 400);
  }

  if (body.available !== undefined) {
    values.available = body.available === true || body.available === 'true' || body.available === 'on';
  }

  if (body.sortOrder !== undefined) {
    const sortOrder = Number(body.sortOrder);
    values.sortOrder = Number.isFinite(sortOrder) ? sortOrder : 0;
  }

  return { values, errors };
}

export function validateGroup(body, { partial = false } = {}) {
  const errors = [];
  const values = {};

  if (!partial || body.name !== undefined) {
    const name = String(body.name ?? '').trim();
    if (!name) errors.push('group name is required');
    else if (name.length > 60) errors.push('group name must be 60 characters or fewer');
    else values.name = name;
  }

  if (body.description !== undefined) {
    values.description = String(body.description ?? '').trim().slice(0, 200);
  }

  if (body.color !== undefined) {
    const color = String(body.color ?? '').trim();
    if (!color) {
      values.color = '';
    } else if (!/^#([0-9a-fA-F]{3}|[0-9a-fA-F]{6})$/.test(color)) {
      errors.push('colour must be a hex value like #2E7D32');
    } else {
      values.color = color.toUpperCase();
    }
  }

  if (body.station !== undefined) {
    const station = String(body.station ?? '').trim();
    if (station.length > 40) {
      errors.push('station must be 40 characters or fewer');
    } else {
      values.station = station;
    }
  }

  if (body.sortOrder !== undefined) {
    const sortOrder = Number(body.sortOrder);
    values.sortOrder = Number.isFinite(sortOrder) ? sortOrder : 0;
  }

  return { values, errors };
}

export function validateStation(body, { partial = false } = {}) {
  const errors = [];
  const values = {};

  if (!partial || body.name !== undefined) {
    const name = String(body.name ?? '').trim();
    if (!name) errors.push('station name is required');
    else if (name.length > 40) errors.push('station name must be 40 characters or fewer');
    else values.name = name;
  }

  if (body.printerName !== undefined) {
    values.printerName = String(body.printerName ?? '').trim().slice(0, 60);
  }

  if (body.sortOrder !== undefined) {
    const sortOrder = Number(body.sortOrder);
    values.sortOrder = Number.isFinite(sortOrder) ? sortOrder : 0;
  }

  return { values, errors };
}

export function validateSettings(body) {
  const errors = [];
  const values = {};

  if (body.restaurantName !== undefined) {
    const restaurantName = String(body.restaurantName ?? '').trim();
    if (!restaurantName) errors.push('restaurant name is required');
    else values.restaurantName = restaurantName.slice(0, 80);
  }

  if (body.currency !== undefined) {
    const currency = String(body.currency ?? '').trim();
    if (!currency) errors.push('currency is required');
    else values.currency = currency.slice(0, 8);
  }

  if (body.taxRate !== undefined) {
    const taxRate = Number(body.taxRate);
    if (!Number.isFinite(taxRate) || taxRate < 0 || taxRate > 1) {
      errors.push('tax rate must be between 0 and 1 (e.g. 0.1 for 10%)');
    } else {
      values.taxRate = taxRate;
    }
  }

  if (body.updatedBy !== undefined) {
    values.updatedBy = String(body.updatedBy ?? '').trim().slice(0, 60);
  }

  return { values, errors };
}
