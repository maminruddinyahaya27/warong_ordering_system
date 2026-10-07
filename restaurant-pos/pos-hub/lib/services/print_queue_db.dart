import 'package:sqflite/sqflite.dart';
import 'package:path/path.dart';

import '../models/print_job.dart';
import '../models/product.dart';
import '../models/order.dart';

class PrintQueueDb {
  static final PrintQueueDb instance = PrintQueueDb._internal();
  PrintQueueDb._internal();

  static const int _version = 16;

  /// Tests set this to `inMemoryDatabasePath` so each test file gets its own
  /// database instead of sharing the on-disk one (which made state-dependent
  /// tests flaky when files run in parallel).
  static String? overridePath;

  Database? _db;

  Future<Database> get database async {
    _db ??= await _init();
    return _db!;
  }

  Future<Database> _init() async {
    final path = overridePath ?? join(await getDatabasesPath(), 'print_queue.db');
    return openDatabase(path, version: _version, onCreate: (db, v) async {
      await _createJobs(db);
      await _createStationPrinters(db);
      await _createProducts(db);
      await _createSettings(db);
      await _createOrders(db);
      await _createOrderItems(db);
      await _createDaySessions(db);
      await _createStations(db);
      await _createOrderPayments(db);
      await _createProcessedRequests(db);
    }, onUpgrade: (db, oldV, newV) async {
      if (oldV < 2) {
        await _createStationPrinters(db);
      }
      if (oldV < 3) {
        await db.execute('ALTER TABLE jobs ADD COLUMN error TEXT');
      }
      if (oldV < 4) {
        await _createProducts(db);
        await _createSettings(db);
        await _createOrders(db);
        await _createOrderItems(db);
        await db.execute(
            "ALTER TABLE jobs ADD COLUMN kind TEXT NOT NULL DEFAULT 'ticket'");
      }
      if (oldV < 5) {
        await db.execute(
            "ALTER TABLE products ADD COLUMN color TEXT NOT NULL DEFAULT ''");
      }
      if (oldV < 6) {
        await db.execute(
            "ALTER TABLE orders ADD COLUMN order_type TEXT NOT NULL DEFAULT 'dine_in'");
      }
      if (oldV < 7) {
        await _createDaySessions(db);
      }
      if (oldV < 8) {
        await _createStations(db);
      }
      if (oldV < 9) {
        await _createOrderPayments(db);
        // Backfill tenders for orders paid before split payments existed, so
        // the day reports keep counting them.
        await db.execute('''
          INSERT INTO order_payments (order_id, method, amount, tendered, change_due, created_at)
          SELECT id, COALESCE(NULLIF(payment_method, ''), 'cash'), total,
                 tendered, change_due, COALESCE(paid_at, created_at)
          FROM orders
          WHERE status = 'PAID'
            AND id NOT IN (SELECT order_id FROM order_payments)
        ''');
      }
      if (oldV < 10) {
        await db.execute(
            "ALTER TABLE orders ADD COLUMN idempotency_key TEXT NOT NULL DEFAULT ''");
        await _createProcessedRequests(db);
      }
      if (oldV < 11) {
        await db.execute(
            'ALTER TABLE products ADD COLUMN sort_order INTEGER NOT NULL DEFAULT 0');
      }
      if (oldV < 12) {
        await db.execute(
            "ALTER TABLE products ADD COLUMN options TEXT NOT NULL DEFAULT ''");
      }
      if (oldV < 13) {
        await db.execute(
            "ALTER TABLE products ADD COLUMN add_on_for TEXT NOT NULL DEFAULT ''");
      }
      if (oldV < 14) {
        await db.execute(
            'ALTER TABLE order_items ADD COLUMN paid INTEGER NOT NULL DEFAULT 0');
      }
      if (oldV < 15) {
        await db.execute(
            'ALTER TABLE products ADD COLUMN require_add_on INTEGER NOT NULL DEFAULT 0');
      }
      if (oldV < 16) {
        // How each line was ordered: its own key, and for an add-on the key of
        // the line it was ordered with (empty when ordered on its own).
        await db.execute(
            "ALTER TABLE order_items ADD COLUMN line_key TEXT NOT NULL DEFAULT ''");
        await db.execute(
            "ALTER TABLE order_items ADD COLUMN parent_key TEXT NOT NULL DEFAULT ''");
      }
    });
  }

  Future<void> _createJobs(Database db) async {
    await db.execute('''
      CREATE TABLE jobs (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        station TEXT,
        printer_mac TEXT,
        payload TEXT,
        status TEXT,
        error TEXT,
        created_at INTEGER,
        kind TEXT NOT NULL DEFAULT 'ticket'
      )
    ''');
  }

  Future<void> _createStationPrinters(Database db) async {
    await db.execute('''
      CREATE TABLE station_printers (
        station TEXT PRIMARY KEY,
        printer_mac TEXT,
        printer_name TEXT
      )
    ''');
  }

  Future<void> _createProducts(Database db) async {
    await db.execute('''
      CREATE TABLE products (
        sku TEXT PRIMARY KEY,
        name TEXT,
        price REAL,
        station TEXT,
        category TEXT,
        available INTEGER,
        color TEXT,
        options TEXT,
        add_on_for TEXT,
        require_add_on INTEGER NOT NULL DEFAULT 0,
        sort_order INTEGER,
        updated_at INTEGER
      )
    ''');
  }

  Future<void> _createSettings(Database db) async {
    await db.execute('''
      CREATE TABLE settings (
        key TEXT PRIMARY KEY,
        value TEXT
      )
    ''');
  }

  Future<void> _createOrders(Database db) async {
    await db.execute('''
      CREATE TABLE orders (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        order_no TEXT,
        table_no TEXT,
        server_name TEXT,
        note TEXT,
        channel TEXT,
        status TEXT,
        order_type TEXT,
        subtotal REAL,
        tax REAL,
        discount REAL,
        total REAL,
        payment_method TEXT,
        tendered REAL,
        change_due REAL,
        created_at INTEGER,
        paid_at INTEGER,
        idempotency_key TEXT
      )
    ''');
  }

  Future<void> _createOrderItems(Database db) async {
    await db.execute('''
      CREATE TABLE order_items (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        order_id INTEGER,
        sku TEXT,
        name TEXT,
        qty INTEGER,
        unit_price REAL,
        line_total REAL,
        station TEXT,
        note TEXT,
        paid INTEGER NOT NULL DEFAULT 0,
        line_key TEXT NOT NULL DEFAULT '',
        parent_key TEXT NOT NULL DEFAULT ''
      )
    ''');
  }

  /// A trading day: opened at the start of service, closed at the end so the
  /// day's takings can be reported.
  Future<void> _createDaySessions(Database db) async {
    await db.execute('''
      CREATE TABLE day_sessions (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        started_at INTEGER,
        ended_at INTEGER,
        opened_by TEXT,
        closed_by TEXT
      )
    ''');
  }

  /// Stations as managed in the portal, so the hub maps exactly those.
  Future<void> _createStations(Database db) async {
    await db.execute('''
      CREATE TABLE stations (
        name TEXT PRIMARY KEY,
        updated_at INTEGER
      )
    ''');
  }

  /// Every tender taken against an order — one bill can be split across
  /// several payments (cash + card, two people paying, …).
  Future<void> _createOrderPayments(Database db) async {
    await db.execute('''
      CREATE TABLE order_payments (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        order_id INTEGER,
        method TEXT,
        amount REAL,
        tendered REAL,
        change_due REAL,
        created_at INTEGER
      )
    ''');
  }

  /// Client retry keys already handled, mapped to the order they produced.
  /// Covers both order creation and appends to a table's running bill, so a
  /// retried send can never duplicate an order or its items.
  Future<void> _createProcessedRequests(Database db) async {
    await db.execute('''
      CREATE TABLE processed_requests (
        key TEXT PRIMARY KEY,
        order_id INTEGER,
        created_at INTEGER
      )
    ''');
  }

  // ---------------------------------------------------------------- printers

  Future<void> assignPrinter(
      String station, String printerMac, String printerName) async {
    final db = await database;
    await db.insert('station_printers', {
      'station': station,
      'printer_mac': printerMac,
      'printer_name': printerName,
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<Map<String, String>> getStationPrinters() async {
    final db = await database;
    final rows = await db.query('station_printers');
    final map = <String, String>{};
    for (final r in rows) {
      map[r['station'] as String] = r['printer_mac'] as String;
    }
    return map;
  }

  Future<Map<String, String>> getStationPrinterNames() async {
    final db = await database;
    final rows = await db.query('station_printers');
    final map = <String, String>{};
    for (final r in rows) {
      map[r['station'] as String] = r['printer_name'] as String? ?? '';
    }
    return map;
  }

  Future<void> clearStationPrinter(String station) async {
    final db = await database;
    // Station names can differ in case between the portal and older
    // assignments, so clear case-insensitively.
    await db.delete('station_printers',
        where: 'LOWER(station) = LOWER(?)', whereArgs: [station]);
  }

  // -------------------------------------------------------------------- jobs

  Future<int> enqueue(String station, String printerMac, String payload,
      {String kind = 'ticket'}) async {
    final db = await database;
    return db.insert('jobs', {
      'station': station,
      'printer_mac': printerMac,
      'payload': payload,
      'status': 'PENDING',
      'error': '',
      'created_at': DateTime.now().millisecondsSinceEpoch,
      'kind': kind,
    });
  }

  Future<List<PrintJob>> getPendingJobs() async {
    final db = await database;
    final rows = await db.query('jobs',
        where: 'status = ?',
        whereArgs: ['PENDING'],
        orderBy: 'created_at ASC');
    return rows.map(PrintJob.fromMap).toList();
  }

  Future<List<PrintJob>> getAllJobs() async {
    final db = await database;
    final rows = await db.query('jobs', orderBy: 'id DESC');
    return rows.map(PrintJob.fromMap).toList();
  }

  Future<void> updateStatus(int id, String status, {String? error}) async {
    final db = await database;
    final values = <String, dynamic>{'status': status};
    if (error != null) {
      values['error'] = error;
    } else {
      values['error'] = '';
    }
    await db.update('jobs', values, where: 'id = ?', whereArgs: [id]);
  }

  Future<void> fail(int id, String reason) async {
    await updateStatus(id, 'FAILED', error: reason);
  }

  /// Drops a job from the queue — used once it has printed successfully.
  Future<void> deleteJob(int id) async {
    final db = await database;
    await db.delete('jobs', where: 'id = ?', whereArgs: [id]);
  }

  Future<void> retry(int id) async {
    await updateStatus(id, 'PENDING');
  }

  Future<void> resetStaleJobs() async {
    final db = await database;
    await db.update('jobs', {'status': 'PENDING'},
        where: 'status = ?', whereArgs: ['PRINTING']);
  }

  Future<void> clear() async {
    final db = await database;
    await db.delete('jobs');
  }

  Future<int> countJobs({String? status}) async {
    final db = await database;
    final result = await db.rawQuery(
      status == null
          ? 'SELECT COUNT(*) AS c FROM jobs'
          : 'SELECT COUNT(*) AS c FROM jobs WHERE status = ?',
      status == null ? null : [status],
    );
    return Sqflite.firstIntValue(result) ?? 0;
  }

  // ---------------------------------------------------------------- products

  Future<void> replaceProducts(List<Product> products) async {
    final db = await database;
    final now = DateTime.now().millisecondsSinceEpoch;
    await db.transaction((txn) async {
      await txn.delete('products');
      final batch = txn.batch();
      for (final p in products) {
        batch.insert('products', {
          'sku': p.sku,
          'name': p.name,
          'price': p.price,
          'station': p.station,
          'category': p.category,
          'available': p.available ? 1 : 0,
          'color': p.color,
          'options': p.options,
          'add_on_for': p.addOnFor,
          'require_add_on': p.requireAddOn ? 1 : 0,
          'sort_order': p.sortOrder,
          'updated_at': now,
        }, conflictAlgorithm: ConflictAlgorithm.replace);
      }
      await batch.commit(noResult: true);
    });
  }

  Future<List<Product>> getProducts({bool availableOnly = false}) async {
    final db = await database;
    final rows = await db.query(
      'products',
      where: availableOnly ? 'available = 1' : null,
      // The portal's feed order, so groups and items appear exactly as arranged
      // in the portal (category/name as a fallback for pre-v11 rows).
      orderBy: 'sort_order ASC, category ASC, name ASC',
    );
    return rows.map(Product.fromMap).toList();
  }

  Future<int> countProducts() async {
    final db = await database;
    final result =
        await db.rawQuery('SELECT COUNT(*) AS c FROM products');
    return Sqflite.firstIntValue(result) ?? 0;
  }

  /// Stations the hub can route to: the portal's configured list plus anything
  /// the synced menu actually uses. The union matters because a ticket must
  /// always be assignable to a printer — e.g. the portal may list "Woks" while
  /// items route to "Wok", or receipts use the CASHIER station.
  Future<List<String>> getStations() async {
    final db = await database;

    final configured =
        await db.query('stations', orderBy: 'name COLLATE NOCASE');
    final names = <String>[];
    final seen = <String>{};
    for (final row in configured) {
      final name = ((row['name'] as String?) ?? '').trim();
      if (name.isEmpty || !seen.add(name.toLowerCase())) continue;
      names.add(name);
    }

    final rows = await db.rawQuery(
      "SELECT DISTINCT station FROM products "
      "WHERE station IS NOT NULL AND station != '' "
      "ORDER BY station COLLATE NOCASE",
    );
    for (final row in rows) {
      final name = ((row['station'] as String?) ?? '').trim();
      if (name.isEmpty || !seen.add(name.toLowerCase())) continue;
      names.add(name);
    }

    // Receipts are queued to this station, so it must be assignable too.
    if (seen.add('cashier')) names.add('Cashier');
    return names;
  }

  /// Replaces the synced station list.
  Future<void> replaceStations(List<String> names) async {
    final db = await database;
    final now = DateTime.now().millisecondsSinceEpoch;
    await db.transaction((txn) async {
      await txn.delete('stations');
      final batch = txn.batch();
      for (final name in names) {
        final trimmed = name.trim();
        if (trimmed.isEmpty) continue;
        batch.insert('stations', {'name': trimmed, 'updated_at': now},
            conflictAlgorithm: ConflictAlgorithm.replace);
      }
      await batch.commit(noResult: true);
    });
  }

  // ---------------------------------------------------------------- settings

  Future<Map<String, String>> getAllSettings() async {
    final db = await database;
    final rows = await db.query('settings');
    final map = <String, String>{};
    for (final r in rows) {
      map[r['key'] as String] = (r['value'] as String?) ?? '';
    }
    return map;
  }

  Future<void> setSettings(Map<String, String> values) async {
    final db = await database;
    await db.transaction((txn) async {
      final batch = txn.batch();
      values.forEach((key, value) {
        batch.insert('settings', {'key': key, 'value': value},
            conflictAlgorithm: ConflictAlgorithm.replace);
      });
      await batch.commit(noResult: true);
    });
  }

  Future<void> setSetting(String key, String value) async {
    await setSettings({key: value});
  }

  // ------------------------------------------------------------------ orders

  Future<int> insertOrder(Order order) async {
    final db = await database;
    return db.insert('orders', order.toMap()..remove('id'));
  }

  Future<void> setOrderNo(int id, String orderNo) async {
    final db = await database;
    await db
        .update('orders', {'order_no': orderNo}, where: 'id = ?', whereArgs: [id]);
  }

  /// Inserts the lines and returns their new row ids, in the given order.
  Future<List<int>> insertOrderItems(int orderId, List<OrderItem> items) async {
    final db = await database;
    final ids = <int>[];
    await db.transaction((txn) async {
      for (final item in items) {
        ids.add(await txn.insert('order_items', {
          'order_id': orderId,
          'sku': item.sku,
          'name': item.name,
          'qty': item.qty,
          'unit_price': item.unitPrice,
          'line_total': item.lineTotal,
          'station': item.station,
          'note': item.note,
          'paid': item.paid ? 1 : 0,
          'line_key': item.lineKey,
          'parent_key': item.parentKey,
        }));
      }
    });
    return ids;
  }

  Future<void> updateOrderPayment(
    int id, {
    required String method,
    required double tendered,
    required double change,
    required double total,
  }) async {
    final db = await database;
    await db.update(
      'orders',
      {
        'status': 'PAID',
        'payment_method': method,
        'tendered': tendered,
        'change_due': change,
        'total': total,
        'paid_at': DateTime.now().millisecondsSinceEpoch,
      },
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  Future<void> updateOrderStatus(int id, String status) async {
    final db = await database;
    await db.update('orders', {'status': status},
        where: 'id = ?', whereArgs: [id]);
  }

  Future<int> insertOrderItem(int orderId, OrderItem item) async {
    final db = await database;
    return db.insert('order_items', {
      'order_id': orderId,
      'sku': item.sku,
      'name': item.name,
      'qty': item.qty,
      'unit_price': item.unitPrice,
      'line_total': item.lineTotal,
      'station': item.station,
      'note': item.note,
      'paid': item.paid ? 1 : 0,
    });
  }

  /// Deletes every transaction — orders, their lines, the payments taken and
  /// the queued print jobs. Products and settings are kept.
  Future<void> clearTransactions() async {
    final db = await database;
    await db.transaction((txn) async {
      await txn.delete('jobs');
      await txn.delete('order_payments');
      await txn.delete('order_items');
      await txn.delete('orders');
    });
  }

  Future<void> updateOrderItemQty(
      int itemId, int qty, double lineTotal) async {
    final db = await database;
    await db.update(
      'order_items',
      {'qty': qty, 'line_total': lineTotal},
      where: 'id = ?',
      whereArgs: [itemId],
    );
  }

  /// Marks the given order lines as covered by a part payment, so the cashier
  /// sees them struck through the next time the item picker opens.
  Future<void> markOrderItemsPaid(int orderId, List<int> itemIds) async {
    if (itemIds.isEmpty) return;
    final db = await database;
    final placeholders = List.filled(itemIds.length, '?').join(',');
    await db.update(
      'order_items',
      {'paid': 1},
      where: 'order_id = ? AND id IN ($placeholders)',
      whereArgs: [orderId, ...itemIds],
    );
  }

  /// Marks every line of an order paid (used when the bill is settled in full).
  Future<void> markAllOrderItemsPaid(int orderId) async {
    final db = await database;
    await db.update(
      'order_items',
      {'paid': 1},
      where: 'order_id = ?',
      whereArgs: [orderId],
    );
  }

  Future<void> deleteOrderItem(int itemId) async {
    final db = await database;
    await db.delete('order_items', where: 'id = ?', whereArgs: [itemId]);
  }

  Future<void> updateOrderTotals(
    int id, {
    required double subtotal,
    required double tax,
    required double discount,
    required double total,
  }) async {
    final db = await database;
    await db.update(
      'orders',
      {
        'subtotal': subtotal,
        'tax': tax,
        'discount': discount,
        'total': total,
      },
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  Future<List<OrderItem>> getOrderItems(int orderId) async {
    final db = await database;
    final rows = await db.query('order_items',
        where: 'order_id = ?', whereArgs: [orderId], orderBy: 'id ASC');
    return rows.map(OrderItem.fromMap).toList();
  }

  Future<Order?> getOrder(int id) async {
    final db = await database;
    final rows = await db.query('orders', where: 'id = ?', whereArgs: [id]);
    if (rows.isEmpty) return null;
    final items = await getOrderItems(id);
    return Order.fromMap(rows.first, items: items, paid: await paidTotal(id));
  }

  /// The order a previously handled retry key produced, if any.
  Future<int?> orderIdForRequest(String key) async {
    if (key.isEmpty) return null;
    final db = await database;
    final rows = await db.query('processed_requests',
        where: 'key = ?', whereArgs: [key], limit: 1);
    if (rows.isEmpty) return null;
    return rows.first['order_id'] as int?;
  }

  /// Remembers the retry key so a repeat of the same send is a no-op.
  Future<void> recordRequest(String key, int orderId) async {
    if (key.isEmpty) return;
    final db = await database;
    await db.insert(
      'processed_requests',
      {
        'key': key,
        'order_id': orderId,
        'created_at': DateTime.now().millisecondsSinceEpoch,
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  /// Looks up an order previously created with the same client retry key, so a
  /// retried send returns the original order instead of duplicating it.
  Future<Order?> findOrderByIdempotencyKey(String key) async {
    if (key.isEmpty) return null;
    final db = await database;
    final rows = await db.query(
      'orders',
      where: 'idempotency_key = ?',
      whereArgs: [key],
      orderBy: 'id DESC',
      limit: 1,
    );
    if (rows.isEmpty) return null;
    final id = rows.first['id'] as int;
    return Order.fromMap(rows.first,
        items: await getOrderItems(id), paid: await paidTotal(id));
  }

  /// The running dine-in bill for a table, if one is still open.
  Future<Order?> findOpenOrderForTable(String tableNo) async {    final db = await database;
    final rows = await db.query(
      'orders',
      where: "status = 'OPEN' AND order_type = 'dine_in' "
          'AND table_no = ? COLLATE NOCASE',
      whereArgs: [tableNo],
      orderBy: 'id ASC',
      limit: 1,
    );
    if (rows.isEmpty) return null;
    final id = rows.first['id'] as int;
    return Order.fromMap(rows.first, items: await getOrderItems(id));
  }

  Future<List<Order>> getOrders({String? status, int limit = 100}) async {
    final db = await database;
    final rows = await db.query(
      'orders',
      where: status == null ? null : 'status = ?',
      whereArgs: status == null ? null : [status],
      orderBy: 'created_at DESC',
      limit: limit,
    );
    final orders = <Order>[];
    final paid = await paidTotals();
    for (final row in rows) {
      final id = row['id'] as int;
      final items = await getOrderItems(id);
      orders.add(Order.fromMap(row, items: items, paid: paid[id] ?? 0));
    }
    return orders;
  }

  Future<int> countOrders({String? status}) async {
    final db = await database;
    final result = await db.rawQuery(
      status == null
          ? 'SELECT COUNT(*) AS c FROM orders'
          : 'SELECT COUNT(*) AS c FROM orders WHERE status = ?',
      status == null ? null : [status],
    );
    return Sqflite.firstIntValue(result) ?? 0;
  }

  /// How many orders already exist for a given numbering prefix (YYMMDD).
  Future<int> countOrdersWithPrefix(String prefix) async {
    final db = await database;
    final result = await db.rawQuery(
      'SELECT COUNT(*) AS c FROM orders WHERE order_no LIKE ?',
      ['$prefix-%'],
    );
    return Sqflite.firstIntValue(result) ?? 0;
  }

  /// Takings for PAID orders settled inside [startMs, endMs] inclusive.
  ///
  /// Summed from the tenders, not the order totals, so a bill split across
  /// cash + card is counted correctly per method.
  Future<Map<String, double>> salesBetween(int startMs, int endMs) async {
    final db = await database;
    final rows = await db.rawQuery(
      'SELECT COUNT(DISTINCT o.id) AS orders, '
      'COALESCE(SUM(p.amount), 0) AS sales, '
      "COALESCE(SUM(CASE WHEN p.method = 'cash' THEN p.amount ELSE 0 END), 0) AS cash, "
      "COALESCE(SUM(CASE WHEN p.method = 'card' THEN p.amount ELSE 0 END), 0) AS card, "
      "COALESCE(SUM(CASE WHEN p.method = 'ewallet' THEN p.amount ELSE 0 END), 0) AS ewallet "
      'FROM order_payments p JOIN orders o ON o.id = p.order_id '
      "WHERE o.status = 'PAID' AND o.paid_at >= ? AND o.paid_at <= ?",
      [startMs, endMs],
    );
    final takeaway = await db.rawQuery(
      "SELECT COUNT(*) AS c FROM orders WHERE status = 'PAID' "
      "AND order_type = 'take_away' AND paid_at >= ? AND paid_at <= ?",
      [startMs, endMs],
    );

    double value(dynamic raw) => ((raw as num?) ?? 0).toDouble();
    final row = rows.first;
    return {
      'orders': value(row['orders']),
      'sales': value(row['sales']),
      'cash': value(row['cash']),
      'card': value(row['card']),
      'ewallet': value(row['ewallet']),
      'takeaway': (Sqflite.firstIntValue(takeaway) ?? 0).toDouble(),
    };
  }

  // ---------------------------------------------------------------- payments

  Future<int> insertOrderPayment(
    int orderId, {
    required String method,
    required double amount,
    required double tendered,
    required double change,
  }) async {
    final db = await database;
    return db.insert('order_payments', {
      'order_id': orderId,
      'method': method,
      'amount': amount,
      'tendered': tendered,
      'change_due': change,
      'created_at': DateTime.now().millisecondsSinceEpoch,
    });
  }

  Future<List<Map<String, dynamic>>> getOrderPayments(int orderId) async {
    final db = await database;
    return db.query('order_payments',
        where: 'order_id = ?', whereArgs: [orderId], orderBy: 'id ASC');
  }

  /// Total tendered against an order so far.
  Future<double> paidTotal(int orderId) async {
    final db = await database;
    final result = await db.rawQuery(
      'SELECT COALESCE(SUM(amount), 0) AS paid FROM order_payments WHERE order_id = ?',
      [orderId],
    );
    return ((result.first['paid'] as num?) ?? 0).toDouble();
  }

  /// Paid totals for many orders at once (used by the order lists).
  Future<Map<int, double>> paidTotals() async {
    final db = await database;
    final rows = await db
        .rawQuery('SELECT order_id, SUM(amount) AS paid FROM order_payments GROUP BY order_id');
    final map = <int, double>{};
    for (final row in rows) {
      map[(row['order_id'] as int)] = ((row['paid'] as num?) ?? 0).toDouble();
    }
    return map;
  }

  Future<int> countOrderPayments(int orderId) async {
    final db = await database;
    final result = await db.rawQuery(
      'SELECT COUNT(*) AS c FROM order_payments WHERE order_id = ?',
      [orderId],
    );
    return Sqflite.firstIntValue(result) ?? 0;
  }

  /// Marks an order fully settled. `method` is the summary ('split' when more
  /// than one tender was used).
  Future<void> settleOrder(
    int id, {
    required String method,
    required double tendered,
    required double changeDue,
  }) async {
    final db = await database;
    await db.update(
      'orders',
      {
        'status': 'PAID',
        'payment_method': method,
        'tendered': tendered,
        'change_due': changeDue,
        'paid_at': DateTime.now().millisecondsSinceEpoch,
      },
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  // ----------------------------------------------------------- day sessions

  Future<int> openDay(String openedBy) async {
    final db = await database;
    return db.insert('day_sessions', {
      'started_at': DateTime.now().millisecondsSinceEpoch,
      'ended_at': null,
      'opened_by': openedBy,
    });
  }

  Future<Map<String, dynamic>?> getActiveDay() async {
    final db = await database;
    final rows = await db.query('day_sessions',
        where: 'ended_at IS NULL', orderBy: 'id DESC', limit: 1);
    return rows.isEmpty ? null : rows.first;
  }

  Future<void> closeDay(int id, String closedBy) async {
    final db = await database;
    await db.update(
      'day_sessions',
      {
        'ended_at': DateTime.now().millisecondsSinceEpoch,
        'closed_by': closedBy,
      },
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  Future<List<Map<String, dynamic>>> getDaySessions({int limit = 30}) async {
    final db = await database;
    return db.query('day_sessions', orderBy: 'id DESC', limit: limit);
  }
}
