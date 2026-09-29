// Create (or reset) a restaurant-panel account linked to one restaurant: node add-restaurant-user.js "Restaurant Name" email password
require('dotenv').config();
const bcrypt = require('bcryptjs'), { Client } = require('pg');
const [restaurantName, email, password] = process.argv.slice(2);
const name = restaurantName;
if (!restaurantName || !email || !password) { console.error('Usage: node add-restaurant-user.js "Restaurant Name" email password'); process.exit(1); }
(async () => {
  const c = new Client({ user: process.env.DB_USER, password: process.env.DB_PASSWORD, host: process.env.DB_HOST || 'localhost',
                         port: process.env.DB_PORT || 5432, database: process.env.DB_NAME || 'food_delivery' });
  await c.connect();
  const rest = await c.query('SELECT restaurant_id, name FROM Restaurants WHERE lower(name)=lower($1) LIMIT 1', [restaurantName]);
  if (!rest.rowCount) throw new Error('Restaurant not found: ' + restaurantName);
  const r = await c.query('SELECT sp_create_restaurant_user($1,$2,$3,$4) AS u', [restaurantName + ' Manager', email, await bcrypt.hash(password, 10), rest.rows[0].restaurant_id]);
  console.log('Restaurant account ready:', r.rows[0].u.email);
  await c.end();
})().catch(e => { console.error('Failed:', e.message); process.exit(1); });
