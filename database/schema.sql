-- Multi-Restaurant Single-Delivery System : schema
DROP TABLE IF EXISTS AppConfig, Refunds, DeliveryAssignment, DeliveryPartners, Payments, SubOrderItems, SubOrders, Orders, MenuItems, Restaurants, Users CASCADE;

-- Haversine great-circle distance (km). Used for: nearby search, combo validation,
-- restaurant<->restaurant gap, restaurant<->destination distance, nearest delivery partner.
CREATE OR REPLACE FUNCTION haversine_km(lat1 DOUBLE PRECISION, lng1 DOUBLE PRECISION,
                                        lat2 DOUBLE PRECISION, lng2 DOUBLE PRECISION)
RETURNS DOUBLE PRECISION AS $$
  SELECT 2 * 6371 * asin(LEAST(1.0, sqrt(
      power(sin(radians(lat2 - lat1) / 2), 2) +
      cos(radians(lat1)) * cos(radians(lat2)) * power(sin(radians(lng2 - lng1) / 2), 2))))
$$ LANGUAGE sql IMMUTABLE;

CREATE TABLE Users (
  user_id SERIAL PRIMARY KEY,
  name VARCHAR(100) NOT NULL,
  email VARCHAR(120) UNIQUE NOT NULL,
  password_hash TEXT NOT NULL,
  phone VARCHAR(20),
  -- 'restaurant' accounts (created by the platform, never by public signup) may use the restaurant panel
  role VARCHAR(12) NOT NULL DEFAULT 'customer' CHECK (role IN ('customer','restaurant')),
  created_at TIMESTAMPTZ DEFAULT NOW()
);
CREATE TABLE Restaurants (
  restaurant_id SERIAL PRIMARY KEY,
  name VARCHAR(120) NOT NULL,
  address VARCHAR(200),
  area VARCHAR(60),
  cuisine_type VARCHAR(60),
  photo_url TEXT,
  rating NUMERIC(2,1) DEFAULT 4.0,
  rating_count INT DEFAULT 0,
  cost_for_two INT,
  prep_time_min INT DEFAULT 20,
  lat DOUBLE PRECISION NOT NULL,
  lng DOUBLE PRECISION NOT NULL,
  is_active BOOLEAN DEFAULT TRUE
);
-- Each restaurant-panel account is permanently linked to exactly one restaurant.
ALTER TABLE Users ADD COLUMN restaurant_id INT REFERENCES Restaurants(restaurant_id) ON DELETE SET NULL;

CREATE TABLE MenuItems (
  item_id SERIAL PRIMARY KEY,
  restaurant_id INT NOT NULL REFERENCES Restaurants(restaurant_id) ON DELETE CASCADE,
  category VARCHAR(40) DEFAULT 'Main course',
  name VARCHAR(120) NOT NULL,
  description VARCHAR(200),
  price NUMERIC(8,2) NOT NULL CHECK (price >= 0),
  is_veg BOOLEAN DEFAULT TRUE,
  is_bestseller BOOLEAN DEFAULT FALSE,
  is_available BOOLEAN DEFAULT TRUE
);
-- ONE order = ONE payment = ONE delivery, even when it spans many restaurants
CREATE TABLE Orders (
  order_id SERIAL PRIMARY KEY,
  user_id INT NOT NULL REFERENCES Users(user_id),
  subtotal NUMERIC(10,2) NOT NULL,
  delivery_fee NUMERIC(8,2) NOT NULL,
  separate_fee_estimate NUMERIC(8,2) NOT NULL,
  total_amount NUMERIC(10,2) NOT NULL,
  delivery_address VARCHAR(250),
  delivery_lat DOUBLE PRECISION NOT NULL,
  delivery_lng DOUBLE PRECISION NOT NULL,
  overall_status VARCHAR(20) DEFAULT 'confirmed',
  created_at TIMESTAMPTZ DEFAULT NOW()
);
-- One row per restaurant inside an order (this enables multi-restaurant orders)
CREATE TABLE SubOrders (
  sub_order_id SERIAL PRIMARY KEY,
  order_id INT NOT NULL REFERENCES Orders(order_id) ON DELETE CASCADE,
  restaurant_id INT NOT NULL REFERENCES Restaurants(restaurant_id),
  sub_status VARCHAR(20) DEFAULT 'pending'
    CHECK (sub_status IN ('pending','preparing','ready','delivered','cancelled')),
  sub_amount NUMERIC(10,2) NOT NULL
);
CREATE TABLE SubOrderItems (
  id SERIAL PRIMARY KEY,
  sub_order_id INT NOT NULL REFERENCES SubOrders(sub_order_id) ON DELETE CASCADE,
  item_id INT NOT NULL REFERENCES MenuItems(item_id),
  quantity INT NOT NULL CHECK (quantity > 0),
  price_at_order NUMERIC(8,2) NOT NULL
);
CREATE TABLE Payments (
  payment_id SERIAL PRIMARY KEY,
  order_id INT UNIQUE NOT NULL REFERENCES Orders(order_id) ON DELETE CASCADE,
  amount NUMERIC(10,2) NOT NULL,
  status VARCHAR(15) DEFAULT 'unpaid' CHECK (status IN ('unpaid','paid','refunded')),
  paid_at TIMESTAMPTZ
);
CREATE TABLE DeliveryPartners (
  partner_id SERIAL PRIMARY KEY,
  name VARCHAR(100) NOT NULL,
  phone VARCHAR(20),
  lat DOUBLE PRECISION NOT NULL,
  lng DOUBLE PRECISION NOT NULL,
  zone VARCHAR(60),
  vehicle_type VARCHAR(20) DEFAULT 'Bike',
  vehicle_no VARCHAR(20),
  rating NUMERIC(2,1) DEFAULT 4.5,
  total_deliveries INT DEFAULT 0,
  is_available BOOLEAN DEFAULT TRUE
);
-- order_id UNIQUE => 1:1 with Orders => single delivery for all restaurants
CREATE TABLE DeliveryAssignment (
  assignment_id SERIAL PRIMARY KEY,
  order_id INT UNIQUE NOT NULL REFERENCES Orders(order_id) ON DELETE CASCADE,
  partner_id INT NOT NULL REFERENCES DeliveryPartners(partner_id),
  distance_km NUMERIC(6,2),
  status VARCHAR(15) DEFAULT 'assigned' CHECK (status IN ('assigned','picked_up','delivered')),
  assigned_at TIMESTAMPTZ DEFAULT NOW(),
  picked_up_at TIMESTAMPTZ,
  delivered_at TIMESTAMPTZ
);
-- Linked to sub_order_id (not order_id) => PARTIAL refunds
CREATE TABLE Refunds (
  refund_id SERIAL PRIMARY KEY,
  sub_order_id INT NOT NULL REFERENCES SubOrders(sub_order_id),
  amount NUMERIC(10,2) NOT NULL,
  reason VARCHAR(200),
  status VARCHAR(15) DEFAULT 'processed',
  created_at TIMESTAMPTZ DEFAULT NOW()
);
-- Business-rule settings live in the database (they used to be in backend/.env), read by the stored procedures
CREATE TABLE AppConfig (
  key VARCHAR(40) PRIMARY KEY,
  value NUMERIC NOT NULL,
  note VARCHAR(200)
);
INSERT INTO AppConfig (key, value, note) VALUES
  ('max_restaurant_gap_km', 3,  'Max distance between any two restaurants in one order'),
  ('max_destination_km',    8,  'Max distance of each restaurant from the customer'),
  ('base_fee',              25, 'Delivery base fee (Rs)'),
  ('per_km_fee',            6,  'Delivery fee per km of route (Rs)');

CREATE INDEX idx_rest_geo ON Restaurants(lat, lng);
CREATE INDEX idx_menu_rest ON MenuItems(restaurant_id);
CREATE INDEX idx_sub_order ON SubOrders(order_id);
CREATE INDEX idx_orders_user ON Orders(user_id);
