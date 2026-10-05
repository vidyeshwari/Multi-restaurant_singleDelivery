// Demo data generator: creates sample customers and places N orders (default 50) THROUGH the stored procedures,
// so every order obeys the real business rules (3 km restaurant gap, 8 km destination limit, fee, payment, delivery).
// Usage (from the backend folder, after "npm run setup-db"):   node seed-orders.js        -> 50 orders
//                                                              node seed-orders.js 80     -> 80 orders
require('dotenv').config();
const bcrypt = require('bcryptjs');
const { Pool } = require('pg');

const N = Math.max(1, parseInt(process.argv[2], 10) || 50);
const pool = new Pool(process.env.DATABASE_URL
  ? { connectionString: process.env.DATABASE_URL, ssl: { rejectUnauthorized: false } }
  : {
      user: process.env.DB_USER, password: process.env.DB_PASSWORD,
      host: process.env.DB_HOST || 'localhost', port: process.env.DB_PORT || 5432,
      database: process.env.DB_NAME || 'food_delivery',
    });
const call = async (fn, args = []) =>
  (await pool.query(`SELECT ${fn}(${args.map((_, i) => '$' + (i + 1)).join(',')}) AS r`, args)).rows[0].r;

const rand = n => Math.floor(Math.random() * n);
const pick = arr => arr[rand(arr.length)];
const shuffle = arr => arr.map(v => [Math.random(), v]).sort((a, b) => a[0] - b[0]).map(x => x[1]);
const km = (a, b) => {
  const R = 6371, d = Math.PI / 180, dLat = (b.lat - a.lat) * d, dLng = (b.lng - a.lng) * d;
  const h = Math.sin(dLat / 2) ** 2 + Math.cos(a.lat * d) * Math.cos(b.lat * d) * Math.sin(dLng / 2) ** 2;
  return 2 * R * Math.asin(Math.min(1, Math.sqrt(h)));
};

const CUSTOMERS = [
  ['Priya Kulkarni', 'priya.k'], ['Rahul Deshmukh', 'rahul.d'], ['Sneha Patil', 'sneha.p'], ['Amit Joshi', 'amit.j'],
  ['Neha Shah', 'neha.s'], ['Rohan Gaikwad', 'rohan.g'], ['Isha Bhosale', 'isha.b'], ['Kunal Pawar', 'kunal.p'],
];

(async () => {
  const cfg = Object.fromEntries((await pool.query('SELECT key, value::float AS v FROM AppConfig')).rows.map(r => [r.key, r.v]));
  const GAP = cfg.max_restaurant_gap_km, DEST = cfg.max_destination_km;
  const rests = (await pool.query('SELECT restaurant_id, name, area, lat, lng FROM Restaurants WHERE is_active')).rows;
  const menu = (await pool.query('SELECT item_id, restaurant_id FROM MenuItems WHERE is_available')).rows;
  if (!rests.length || !menu.length) throw new Error('No restaurants/menu found. Run "npm run setup-db" first.');
  const menuBy = {};
  menu.forEach(m => (menuBy[m.restaurant_id] ||= []).push(m.item_id));

  // 1) customers (signup goes through sp_signup; re-running the script reuses the same accounts)
  const hash = await bcrypt.hash('test123', 10);
  const users = [];
  for (const [name, handle] of CUSTOMERS) {
    const email = `${handle}@example.com`;
    let u = await call('sp_get_login', [email]);
    if (!u) { await call('sp_signup', [name, email, hash, '9' + String(rand(1e9)).padStart(9, '0')]); u = await call('sp_get_login', [email]); }
    users.push(u.user_id);
  }
  // staff account only needed to move deliveries to "delivered"
  const staff = await call('sp_get_login', [process.env.RESTAURANT_EMAIL || 'restaurant@multieats.test']);

  // 2) place orders
  const stats = { placed: 0, multi: 0, skipped: 0, delivered: 0 };
  let guard = 0;
  while (stats.placed < N && guard++ < N * 30) {
    // delivery point: near a random restaurant area (small jitter, roughly within 1.5 km)
    const anchor = pick(rests);
    const loc = { lat: anchor.lat + (Math.random() - 0.5) * 0.02, lng: anchor.lng + (Math.random() - 0.5) * 0.02 };
    // combo: 1 restaurant (~40%), 2 (~40%) or 3 (~20%), all within the gap limit of each other and the destination limit
    const want = [1, 1, 2, 2, 2, 3][rand(6)];
    const near = shuffle(rests.filter(r => km(r, loc) <= DEST));
    const combo = [];
    for (const r of near) {
      if (combo.length === want) break;
      if (combo.every(c => km(c, r) <= GAP)) combo.push(r);
    }
    if (!combo.length) { stats.skipped++; continue; }

    const items = combo.flatMap(r => shuffle(menuBy[r.restaurant_id] || []).slice(0, 1 + rand(3))
      .map(item_id => ({ item_id, quantity: 1 + rand(3) })));
    if (!items.length) { stats.skipped++; continue; }

    try {
      const user = pick(users);
      const res = await call('sp_place_order', [user, `${anchor.area}, Pune`, loc.lat, loc.lng, JSON.stringify(items)]);
      await call('sp_pay_order', [user, res.order_id]);
      stats.placed++;
      if (combo.length > 1) stats.multi++;

      // ~70% of orders are fully delivered, ~8% are on the way, the rest stay unassigned so the dashboard looks alive
      const roll = Math.random();
      if (roll < 0.7) {
        await call('sp_assign_delivery', [user, res.order_id]);
        await call('sp_update_delivery_status', [staff.user_id, res.order_id, 'picked_up']);
        await call('sp_update_delivery_status', [staff.user_id, res.order_id, 'delivered']);
        stats.delivered++;
      } else if (roll < 0.78) {
        await call('sp_assign_delivery', [user, res.order_id]);   // on the way
      }
      // spread the orders over the last 30 days (demo data only)
      await pool.query(`UPDATE Orders SET created_at = NOW() - random() * INTERVAL '30 days' WHERE order_id = $1`, [res.order_id]);
    } catch (e) {
      stats.skipped++;
      if (!/^MX/.test(e.code || '')) console.warn('Order failed:', e.message);
    }
  }
  const c = (await pool.query(`SELECT (SELECT COUNT(*) FROM Orders) o, (SELECT COUNT(*) FROM SubOrders) s,
      (SELECT COUNT(*) FROM Users WHERE role='customer') u, (SELECT COUNT(*) FROM Orders o WHERE (SELECT COUNT(*) FROM SubOrders x WHERE x.order_id=o.order_id) > 1) m`)).rows[0];
  console.log(`Placed ${stats.placed} orders (${stats.multi} multi-restaurant, ${stats.delivered} delivered, ${stats.skipped} retried/skipped).`);
  console.log(`DB now has: ${c.o} orders | ${c.s} sub-orders | ${c.m} multi-restaurant orders | ${c.u} customers`);
  console.log('Customer logins: <handle>@example.com / test123  (e.g. priya.k@example.com)');
  await pool.end();
})().catch(e => { console.error('seed-orders failed:', e.message); process.exit(1); });