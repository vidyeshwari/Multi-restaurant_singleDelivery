// HTTP gateway for the database tier.
// ALL business logic (combo rules, fees, orders, payments, delivery, refunds, access control) lives in PostgreSQL stored
// procedures (database/procedures.sql). This file only: 1) hashes passwords, 2) issues / checks the login token,
// 3) turns each HTTP request into ONE call  SELECT sp_xxx(...)  and 4) maps database errors to HTTP status codes.
require('dotenv').config();
const crypto = require('crypto');
const express = require('express'), cors = require('cors'), bcrypt = require('bcryptjs');
const { Pool } = require('pg');

const pool = new Pool({
  user: process.env.DB_USER, password: process.env.DB_PASSWORD,
  host: process.env.DB_HOST || 'localhost', port: process.env.DB_PORT || 5432,
  database: process.env.DB_NAME || 'food_delivery',
});
const app = express();
app.use(cors()); app.use(express.json());

// ---------- login token (HMAC signed, no extra packages). The role is NOT in the token: the database checks it. ----------
const SECRET = process.env.AUTH_SECRET || crypto.randomBytes(32).toString('hex');
if (!process.env.AUTH_SECRET) console.warn('AUTH_SECRET is not set in .env: using a random one, everyone is logged out when the server restarts.');
const TOKEN_HOURS = 12;
const mac = b64 => crypto.createHmac('sha256', SECRET).update(b64).digest('base64url');
const sign = uid => { const b = Buffer.from(JSON.stringify({ uid, exp: Date.now() + TOKEN_HOURS * 3600e3 })).toString('base64url'); return `${b}.${mac(b)}`; };
function verify(token) {
  const [b, s] = String(token || '').split('.');
  if (!b || !s) return null;
  const good = Buffer.from(mac(b)), given = Buffer.from(s);
  if (good.length !== given.length || !crypto.timingSafeEqual(good, given)) return null;
  try { const p = JSON.parse(Buffer.from(b, 'base64url').toString()); return p.exp > Date.now() ? p.uid : null; } catch { return null; }
}
app.use((req, _res, next) => { req.actor = verify((req.headers.authorization || '').replace(/^Bearer /, '')); next(); });
const needAuth = (req, res, next) => req.actor ? next() : res.status(401).json({ error: 'Please log in' });

// ---------- gateway helpers ----------
// database errors raised by sp_fail() carry SQLSTATE 'MX' + HTTP status, e.g. MX404
const fail = (res, e) => {
  if (/^MX\d{3}$/.test(e.code)) return res.status(+e.code.slice(2)).json({ error: e.message });
  if (e.code && (e.code.startsWith('22') || e.code === '23514')) return res.status(400).json({ error: 'Invalid input' });
  console.error(e); res.status(500).json({ error: 'Something went wrong' });
};
const call = async (fn, args = []) =>
  (await pool.query(`SELECT ${fn}(${args.map((_, i) => '$' + (i + 1)).join(',')}) AS r`, args)).rows[0].r;
// route('get', '/path', 'sp_name', req => [args], needsLogin)
const route = (method, path, fn, args = () => [], auth = false) =>
  app[method](path, ...(auth ? [needAuth] : []), async (req, res) => {
    try { res.json(await call(fn, args(req))); } catch (e) { fail(res, e); }
  });
const json = o => JSON.stringify(o ?? {});
const opt = v => (v === '' ? null : v);   // empty query value = not given

// ---------- Auth ----------
app.post('/auth/signup', async (req, res) => {
  try {
    const { name, email, password, phone } = req.body;
    if (!password) return res.status(400).json({ error: 'Name, email and password are required' });
    res.json(await call('sp_signup', [name, email, await bcrypt.hash(String(password), 10), phone]));
  } catch (e) { fail(res, e); }
});
app.post('/auth/login', async (req, res) => {
  try {
    const u = await call('sp_get_login', [String(req.body.email || '')]);
    if (!u || !(await bcrypt.compare(String(req.body.password || ''), u.password_hash))) return res.status(401).json({ error: 'Invalid email or password' });
    res.json({ user: { user_id: u.user_id, name: u.name, email: u.email, role: u.role }, token: sign(u.user_id) });
  } catch (e) { fail(res, e); }
});

// ---------- Restaurants (public) ----------
route('get', '/restaurants', 'sp_list_restaurants');
route('get', '/restaurants/nearby', 'sp_nearby', q => [opt(q.query.lat), opt(q.query.lng), opt(q.query.radius)]);
route('get', '/restaurants/suggestions', 'sp_suggestions',
  q => [opt(q.query.lat), opt(q.query.lng), opt(q.query.radius), (q.query.exclude || '').split(',').map(Number).filter(Number.isInteger)]);
route('get', '/restaurants/:id', 'sp_restaurant_detail', q => [q.params.id, opt(q.query.lat), opt(q.query.lng)]);
route('post', '/cart/validate', 'sp_validate_combo',
  q => [Array.isArray(q.body.restaurant_ids) ? q.body.restaurant_ids.map(Number) : null, q.body.lat, q.body.lng]);

// ---------- Orders (logged-in customer; the customer is taken from the token, never from the request body) ----------
route('post', '/orders', 'sp_place_order', q => [q.actor, q.body.delivery_address, q.body.delivery_lat, q.body.delivery_lng,
  json(Array.isArray(q.body.items) ? q.body.items.map(i => ({ item_id: Number(i.item_id), quantity: i.quantity })) : null)], true);
route('get', '/orders/:id', 'sp_order_detail', q => [q.actor, q.params.id], true);
route('post', '/orders/:id/pay', 'sp_pay_order', q => [q.actor, q.params.id], true);
route('post', '/orders/:id/assign-delivery', 'sp_assign_delivery', q => [q.actor, q.params.id], true);
app.get('/users/:id/orders', needAuth, async (req, res) => {
  if (String(req.actor) !== req.params.id) return res.status(403).json({ error: 'You can only see your own orders' });
  try { res.json(await call('sp_user_orders', [req.actor])); } catch (e) { fail(res, e); }
});

// ---------- Restaurant panel (the database refuses everyone whose role is not 'restaurant') ----------
route('patch', '/sub-orders/:id/status', 'sp_update_sub_order_status', q => [q.actor, q.params.id, q.body.status, q.body.reason], true);
route('get', '/admin/dashboard', 'sp_admin_dashboard', q => [q.actor], true);
route('get', '/admin/reports/revenue', 'sp_admin_revenue_report', q => [q.actor], true);
route('get', '/admin/orders', 'sp_admin_orders', q => [q.actor], true);
route('get', '/admin/sub-orders', 'sp_admin_sub_orders', q => [q.actor], true);
route('get', '/admin/refunds', 'sp_admin_refunds', q => [q.actor], true);
route('get', '/admin/restaurants', 'sp_admin_restaurants', q => [q.actor], true);
route('patch', '/admin/restaurants/:id', 'sp_admin_update_restaurant', q => [q.actor, q.params.id, json(q.body)], true);
route('get', '/admin/restaurants/:id/menu', 'sp_admin_restaurant_menu', q => [q.actor, q.params.id], true);
route('post', '/admin/menu-items', 'sp_admin_add_menu_item', q => [q.actor, json(q.body)], true);
route('patch', '/admin/menu-items/:id', 'sp_admin_update_menu_item', q => [q.actor, q.params.id, json(q.body)], true);
route('delete', '/admin/menu-items/:id', 'sp_admin_delete_menu_item', q => [q.actor, q.params.id], true);

// ---------- Health: shows that both tiers are alive (used by the Architecture page) ----------
app.get('/health', async (_q, res) => {
  const t0 = Date.now();
  try {
    const h = await call('sp_health');
    res.json({ server: 'up', port: +(process.env.PORT || 5000), database: 'connected', ...h, db_ms: Date.now() - t0 });
  } catch (e) { res.status(503).json({ server: 'up', database: 'down', error: e.message }); }
});

const PORT = process.env.PORT || 5000;
app.listen(PORT, () => console.log(`Gateway running on http://localhost:${PORT}`));
