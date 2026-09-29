// One-command DB setup: creates the database (if missing), runs schema.sql + seed.sql
require('dotenv').config();
const bcrypt = require('bcryptjs');
const fs = require('fs'), path = require('path'), { Client } = require('pg');
const cfg = { user: process.env.DB_USER, password: process.env.DB_PASSWORD, host: process.env.DB_HOST || 'localhost', port: process.env.DB_PORT || 5432 };
const dbName = process.env.DB_NAME || 'food_delivery';
(async () => {
  const admin = new Client({ ...cfg, database: 'postgres' });
  await admin.connect();
  const ex = await admin.query('SELECT 1 FROM pg_database WHERE datname=$1', [dbName]);
  if (!ex.rowCount) { await admin.query(`CREATE DATABASE "${dbName}"`); console.log('Created database', dbName); }
  await admin.end();
  const c = new Client({ ...cfg, database: dbName });
  await c.connect();
  for (const f of ['schema.sql', 'procedures.sql', 'seed.sql']) {
    await c.query(fs.readFileSync(path.join(__dirname, '..', 'database', f), 'utf8'));
    console.log('Ran', f);
  }
  // demo restaurant login (customers sign up on the site; restaurant accounts are only created here / by add-restaurant-user.js)
  const email = process.env.RESTAURANT_EMAIL || 'restaurant@multieats.test', pw = process.env.RESTAURANT_PASSWORD || 'restaurant123';
  await c.query('SELECT sp_create_restaurant_user($1,$2,$3,$4)', ['Restaurant Manager', email, await bcrypt.hash(pw, 10), 1]);
  console.log('Restaurant panel login:', email, '/', pw, '(change it in .env before the demo goes public)');
  const r = await c.query('SELECT (SELECT COUNT(*) FROM Restaurants) r, (SELECT COUNT(*) FROM MenuItems) m, (SELECT COUNT(*) FROM DeliveryPartners) d');
  console.log('Restaurants:', r.rows[0].r, '| Menu items:', r.rows[0].m, '| Partners:', r.rows[0].d);
  await c.end();
})().catch(e => { console.error('Setup failed:', e.message); process.exit(1); });
