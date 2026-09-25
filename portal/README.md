# Warong Menu & Price Portal

An admin portal to maintain the restaurant **menu, stations and prices** for the
Warong ordering system (`index1.html` / `index2.html` in the repository root),
backed by **MongoDB**.

The static ordering screens ship with a hardcoded `MENU` array. This portal
replaces that with a database-backed, editable source of truth and exposes a
JSON feed the POS screens can consume.

## Features

- **Menu management** — create, edit and delete items (name, SKU, price,
  station, category, description, sort order)
- **Inline price editing** — change a price straight from the list, with an
  immediate save
- **Sold-out control** — toggle items available / unavailable in one click
- **Stations** — manage kitchen routing stations (Griddle, Kitchen, Wok,
  Beverage, …) with printer names; renaming a station updates all its items
- **Price history** — every create, price change and deletion is recorded with
  old/new price, author and timestamp
- **Settings** — restaurant name, currency and tax rate
- **JSON export** — `/api/export` returns the exact `MENU` shape the ordering
  apps expect, in array (`index2.html`) or object (`index1.html`) form
- **Optional Basic auth** — enable by setting `PORTAL_USER` / `PORTAL_PASSWORD`

## Data model

| Collection      | Purpose                                                                 |
| --------------- | ----------------------------------------------------------------------- |
| `menu_items`    | One document per menu item (`sku`, `name`, `price`, `station`, …)        |
| `stations`      | Routing stations and their printer names                                |
| `settings`      | Singleton document: restaurant name, currency, tax rate                 |
| `price_history` | Append-only audit log of creates, price changes and deletions           |

The `sku` mirrors the ordering app's item `id` (`mi_001`, `mi_002`, …), so the
export feeds straight into the existing front-ends.

## Getting started

```bash
cd portal
npm install
```

### 1. Configure the database

`.env.local` is already set up for **local MongoDB** on `127.0.0.1:27017`:

```
MONGODB_URI=mongodb://127.0.0.1:27017/warong_ordering_system
MONGODB_DB=warong_ordering_system
```

A local `mongod` 6.0.14 is installed and already running. To start it yourself:

```bash
~/.local/opt/mongodb-macos-x86_64-6.0.14/bin/mongod \
  --dbpath ~/.local/share/warong-mongo/data \
  --bind_ip 127.0.0.1 --port 27017 \
  --logpath ~/.local/share/warong-mongo/log/mongod.log --logappend
```

Stop it with `Ctrl+C` (or `pkill -f "mongodb-macos-x86_64-6.0.14/bin/mongod"`).
Data lives in `~/.local/share/warong-mongo/data`, so your menu survives restarts.

> **Older macOS note:** this machine runs macOS 12.3.1, where MongoDB 7+/8+
> binaries abort on a missing `libc++` symbol. 6.0.14 is the newest version
> that runs here.

#### Using MongoDB Atlas instead

Comment out `MONGODB_URI` and use the Atlas connection string, replacing
`REPLACE_WITH_DB_PASSWORD` with the real password:

```
MONGODB_URI=mongodb+srv://maminruddinyahaya_db_user:YOUR_PASSWORD@cluster0.smbadnp.mongodb.net/?retryWrites=true&w=majority&appName=Cluster0
```

> The app refuses to connect while the placeholder is still present, so you get
> a clear message instead of a confusing driver error.

### 2. Seed the menu

Loads the 18 items that are currently hardcoded in `index2.html` (plus the four
stations and default settings). Safe to re-run — existing items keep their
current prices:

```bash
npm run seed
```

Use `npm run seed -- --update-prices` to reset existing items back to the seed
prices.

### 3. Run the portal

```bash
npm run dev
```

Open http://localhost:3000.

Production:

```bash
npm run build
npm start
```

## API

| Method | Route                | Description                                         |
| ------ | -------------------- | --------------------------------------------------- |
| GET    | `/api/menu`          | List items (`?search=&station=&available=`)         |
| POST   | `/api/menu`          | Create an item (SKU auto-generated when omitted)    |
| GET    | `/api/menu/:id`      | Fetch one item (accepts an ObjectId **or** SKU)     |
| PATCH  | `/api/menu/:id`      | Update fields; price changes are logged             |
| DELETE | `/api/menu/:id`      | Delete an item (logged)                             |
| GET    | `/api/stations`      | List stations with item counts                      |
| POST   | `/api/stations`      | Create a station                                    |
| PATCH  | `/api/stations/:id`  | Rename / update a station (cascades to items)       |
| DELETE | `/api/stations/:id`  | Delete a station (blocked while items use it)       |
| GET    | `/api/settings`      | Read settings                                       |
| PATCH  | `/api/settings`      | Update settings                                     |
| GET    | `/api/history`       | Price history (`?itemId=&action=&limit=`)           |
| GET    | `/api/stats`         | Dashboard aggregates                                |
| GET    | `/api/export`        | Menu feed (`?format=array\|object&download=1`)      |

## Wiring the ordering screens to the portal

Replace the hardcoded `const MENU = [ ... ]` block with a fetch of the feed.
For `index2.html`:

```html
<script>
  let MENU = [];

  async function loadMenu() {
    const res = await fetch('http://localhost:3000/api/export?format=array');
    const data = await res.json();
    MENU = data.menu; // [{ id, name, price, station, options? }]
  }
</script>
```

`MENU` keeps the same field names (`id`, `name`, `price`, `station`,
`options`), so the rest of the ordering logic works unchanged. `index1.html`
uses an object keyed by name — use `format=object` for that screen.

## Project structure

```
portal/
  app/
    page.js                    # Dashboard (stats, latest changes, export)
    menu/page.js               # Menu list with filters + inline price edit
    menu/new/page.js           # Create item
    menu/[id]/page.js          # Edit item + its price history
    stations/page.js           # Station management
    history/page.js            # Full price history
    settings/page.js           # Restaurant settings
    api/...                    # Route handlers (see API table)
  components/                  # Navbar, MenuTable, MenuItemForm, StationManager, …
  lib/
    mongodb.js                 # Cached Mongoose connection
    models/                    # MenuItem, Station, Setting, PriceHistory
    menu-service.js            # Shared queries, SKU generation, audit logging
    validate.js                # Input validation
    seedData.js                # The 18 items extracted from index2.html
  scripts/seed.mjs             # Seeder
  proxy.js                     # Optional Basic auth
```

## Notes and next steps

- **Auth** — the portal is open by default; set `PORTAL_USER` and
  `PORTAL_PASSWORD` to gate it behind HTTP Basic auth before exposing it
  beyond localhost.
- **Realtime** — the POS screens poll the export feed on load. Add a short
  cache/revalidate window (or a version timestamp) when you wire them up so
  price changes propagate predictably.
- **Images and recipes** — new fields (photo, cost price, allergen info) can be
  added to the `MenuItem` schema and the item form.
