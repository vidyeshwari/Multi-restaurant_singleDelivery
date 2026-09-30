-- =====================================================================================
-- Multi-Restaurant Single-Delivery System : STORED PROCEDURES (all business logic)
--
-- Two-tier design:  Tier 1 = browser (UI only)   Tier 2 = PostgreSQL (data + business logic)
-- Every rule lives here: combo validation (3 km / 8 km), delivery fee and route, order placement,
-- payment, delivery-partner assignment, cancellation + partial refund, status flow, access control.
-- backend/server.js is only an HTTP gateway (a browser cannot speak the PostgreSQL protocol):
-- it checks the login token and calls one function per request. It contains no business rules.
--
-- Errors are raised with SQLSTATE 'MX' + HTTP status (MX404, MX409 ...) so the gateway can map them.
-- Run order: schema.sql -> procedures.sql -> seed.sql
-- =====================================================================================

-- ---------- helpers ----------
CREATE OR REPLACE FUNCTION sp_fail(p_status INT, p_msg TEXT) RETURNS VOID LANGUAGE plpgsql AS $$
BEGIN
  RAISE EXCEPTION '%', p_msg USING ERRCODE = 'MX' || p_status::text;
END $$;

CREATE OR REPLACE FUNCTION sp_cfg(p_key TEXT) RETURNS NUMERIC LANGUAGE sql STABLE AS $$
  SELECT value FROM AppConfig WHERE key = p_key
$$;

-- delivery time estimate: kitchen prep + ~3.5 min per km + 5 min handover
CREATE OR REPLACE FUNCTION sp_eta(p_prep INT, p_km DOUBLE PRECISION) RETURNS INT LANGUAGE sql IMMUTABLE AS $$
  SELECT round(COALESCE(NULLIF(p_prep, 0), 20) + p_km::numeric * 3.5 + 5)::int
$$;

-- access control lives in the database: the actor is the user id from the login token
CREATE OR REPLACE FUNCTION sp_require_staff(p_actor INT) RETURNS VOID LANGUAGE plpgsql AS $$
BEGIN
  IF p_actor IS NULL THEN PERFORM sp_fail(401, 'Please log in'); END IF;
  IF NOT EXISTS (SELECT 1 FROM Users WHERE user_id = p_actor AND role = 'restaurant' AND restaurant_id IS NOT NULL) THEN
    PERFORM sp_fail(403, 'Only restaurant staff with an assigned restaurant can do this');
  END IF;
END $$;

CREATE OR REPLACE FUNCTION sp_staff_restaurant(p_actor INT) RETURNS INT LANGUAGE plpgsql STABLE AS $$
DECLARE v_restaurant INT;
BEGIN
  SELECT restaurant_id INTO v_restaurant FROM Users WHERE user_id = p_actor AND role = 'restaurant';
  IF v_restaurant IS NULL THEN PERFORM sp_fail(403, 'Restaurant account is not assigned to a restaurant'); END IF;
  RETURN v_restaurant;
END $$;

-- an order can be seen / acted on by its customer or by restaurant staff
CREATE OR REPLACE FUNCTION sp_assert_order_access(p_order INT, p_actor INT) RETURNS VOID LANGUAGE plpgsql AS $$
BEGIN
  IF p_actor IS NULL THEN PERFORM sp_fail(401, 'Please log in'); END IF;
  IF NOT EXISTS (SELECT 1 FROM Orders o WHERE o.order_id = p_order AND (o.user_id = p_actor
        OR EXISTS (SELECT 1 FROM Users u WHERE u.user_id = p_actor AND u.role = 'restaurant'))) THEN
    PERFORM sp_fail(404, 'Order not found');
  END IF;
END $$;

-- ---------- auth ----------
-- password hashing (bcrypt) stays in the gateway; the role is NEVER taken from the client: signup = customer
CREATE OR REPLACE FUNCTION sp_signup(p_name TEXT, p_email TEXT, p_hash TEXT, p_phone TEXT) RETURNS JSONB LANGUAGE plpgsql AS $$
DECLARE v_u Users%ROWTYPE;
BEGIN
  IF NULLIF(trim(p_name), '') IS NULL OR NULLIF(trim(p_email), '') IS NULL OR p_hash IS NULL THEN
    PERFORM sp_fail(400, 'Name, email and password are required');
  END IF;
  INSERT INTO Users (name, email, password_hash, phone, role)
       VALUES (trim(p_name), lower(trim(p_email)), p_hash, NULLIF(p_phone, ''), 'customer') RETURNING * INTO v_u;
  RETURN jsonb_build_object('user', jsonb_build_object('user_id', v_u.user_id, 'name', v_u.name, 'email', v_u.email));
EXCEPTION WHEN unique_violation THEN
  PERFORM sp_fail(409, 'Email already registered');
END $$;

-- restaurant accounts are created by the platform (setup script), not through the public API
CREATE OR REPLACE FUNCTION sp_create_restaurant_user(p_name TEXT, p_email TEXT, p_hash TEXT, p_restaurant_id INT) RETURNS JSONB LANGUAGE plpgsql AS $$
DECLARE v_u Users%ROWTYPE;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM Restaurants WHERE restaurant_id = p_restaurant_id) THEN
    PERFORM sp_fail(404, 'Restaurant not found');
  END IF;
  INSERT INTO Users (name, email, password_hash, role, restaurant_id)
       VALUES (p_name, lower(trim(p_email)), p_hash, 'restaurant', p_restaurant_id)
  ON CONFLICT (email) DO UPDATE SET password_hash = EXCLUDED.password_hash, role = 'restaurant',
      name = EXCLUDED.name, restaurant_id = EXCLUDED.restaurant_id
  RETURNING * INTO v_u;
  RETURN jsonb_build_object('user_id', v_u.user_id, 'email', v_u.email, 'role', v_u.role, 'restaurant_id', v_u.restaurant_id);
END $$;

CREATE OR REPLACE FUNCTION sp_get_login(p_email TEXT) RETURNS JSONB LANGUAGE sql STABLE AS $$
  SELECT jsonb_build_object('user_id', user_id, 'name', name, 'email', email, 'role', role, 'password_hash', password_hash)
    FROM Users WHERE email = lower(trim(p_email))
$$;

-- ---------- restaurants ----------
CREATE OR REPLACE FUNCTION sp_list_restaurants() RETURNS JSONB LANGUAGE sql STABLE AS $$
  SELECT COALESCE(jsonb_agg(to_jsonb(r) ORDER BY r.rating DESC, r.restaurant_id), '[]')
    FROM Restaurants r WHERE r.is_active
$$;

CREATE OR REPLACE FUNCTION sp_nearby(p_lat DOUBLE PRECISION, p_lng DOUBLE PRECISION, p_radius DOUBLE PRECISION)
RETURNS JSONB LANGUAGE plpgsql AS $$
DECLARE v_radius DOUBLE PRECISION := COALESCE(NULLIF(p_radius, 0), 5);
BEGIN
  IF p_lat IS NULL OR p_lng IS NULL THEN PERFORM sp_fail(400, 'lat and lng are required'); END IF;
  RETURN COALESCE((
    SELECT jsonb_agg((to_jsonb(t) - 'd') || jsonb_build_object('distance_km', round(t.d::numeric, 2), 'eta_min', sp_eta(t.prep_time_min, t.d))
                     ORDER BY t.d, t.restaurant_id)
      FROM (SELECT r.*, haversine_km(r.lat, r.lng, p_lat, p_lng) AS d FROM Restaurants r WHERE r.is_active) t
     WHERE t.d <= v_radius), '[]');
END $$;

-- Cuisine-aware suggestions: restaurants of a DIFFERENT cuisine that are within the radius of the customer AND within the
-- allowed gap of every restaurant already in the cart. One restaurant per cuisine first; sweet shops first if the cart has none.
CREATE OR REPLACE FUNCTION sp_suggestions(p_lat DOUBLE PRECISION, p_lng DOUBLE PRECISION, p_radius DOUBLE PRECISION, p_exclude INT[])
RETURNS JSONB LANGUAGE plpgsql AS $$
DECLARE
  v_radius  DOUBLE PRECISION := COALESCE(NULLIF(p_radius, 0), 3);
  v_ex      INT[] := COALESCE(p_exclude, '{}');
  v_max_gap NUMERIC := sp_cfg('max_restaurant_gap_km');
  v_sweet   TEXT[] := ARRAY['Desserts', 'Ice Cream', 'Bakery'];
  v_cuisines TEXT[]; v_has_sweet BOOLEAN; v_label TEXT;
BEGIN
  IF p_lat IS NULL OR p_lng IS NULL THEN PERFORM sp_fail(400, 'lat and lng are required'); END IF;
  SELECT COALESCE(array_agg(DISTINCT cuisine_type ORDER BY cuisine_type), '{}') INTO v_cuisines
    FROM Restaurants WHERE restaurant_id = ANY(v_ex) AND cuisine_type IS NOT NULL;
  v_has_sweet := v_cuisines && v_sweet;
  v_label := array_to_string(v_cuisines, ' & ');
  RETURN COALESCE((
    WITH cand AS (
      SELECT r.*, haversine_km(r.lat, r.lng, p_lat, p_lng) AS dist,
             (SELECT COALESCE(MAX(haversine_km(r.lat, r.lng, s.lat, s.lng)), 0) FROM Restaurants s WHERE s.restaurant_id = ANY(v_ex)) AS gap
        FROM Restaurants r WHERE r.is_active AND r.restaurant_id <> ALL(v_ex)),
    ok AS (
      SELECT c.*, row_number() OVER (PARTITION BY c.cuisine_type ORDER BY c.dist, c.restaurant_id) AS rn
        FROM cand c WHERE c.dist <= v_radius AND c.gap <= v_max_gap AND NOT (c.cuisine_type = ANY(v_cuisines))),
    ranked AS (
      SELECT o.*, (o.rn > 1)::int AS g,
             CASE WHEN o.rn = 1 AND NOT v_has_sweet AND o.cuisine_type = ANY(v_sweet) THEN 0 ELSE 1 END AS p
        FROM ok o),
    top AS (SELECT * FROM ranked ORDER BY g, p, dist, restaurant_id LIMIT 10)
    SELECT jsonb_agg((to_jsonb(t) - 'dist' - 'gap' - 'rn' - 'g' - 'p') || jsonb_build_object(
             'distance_km', round(t.dist::numeric, 2), 'gap_km', round(t.gap::numeric, 2),
             'eta_min', sp_eta(t.prep_time_min, t.dist),
             'reason', CASE WHEN t.cuisine_type = ANY(v_sweet) THEN 'Something sweet to finish the meal' ELSE 'Different taste from ' || v_label END,
             'items', COALESCE((SELECT jsonb_agg(jsonb_build_object('item_id', x.item_id, 'name', x.name, 'price', x.price, 'is_veg', x.is_veg)
                                                 ORDER BY x.is_bestseller DESC, x.item_id)
                                  FROM (SELECT * FROM MenuItems m WHERE m.restaurant_id = t.restaurant_id AND m.is_available
                                         ORDER BY m.is_bestseller DESC, m.item_id LIMIT 3) x), '[]'))
             ORDER BY t.g, t.p, t.dist, t.restaurant_id)
      FROM top t), '[]');
END $$;

CREATE OR REPLACE FUNCTION sp_restaurant_detail(p_id INT, p_lat DOUBLE PRECISION, p_lng DOUBLE PRECISION) RETURNS JSONB LANGUAGE plpgsql AS $$
DECLARE v_r JSONB; v_d NUMERIC;
BEGIN
  SELECT to_jsonb(r) INTO v_r FROM Restaurants r WHERE r.restaurant_id = p_id;
  IF v_r IS NULL THEN PERFORM sp_fail(404, 'Restaurant not found'); END IF;
  IF p_lat IS NOT NULL AND p_lng IS NOT NULL THEN
    v_d := round(haversine_km((v_r->>'lat')::double precision, (v_r->>'lng')::double precision, p_lat, p_lng)::numeric, 2);
    v_r := v_r || jsonb_build_object('distance_km', v_d, 'eta_min', sp_eta((v_r->>'prep_time_min')::int, v_d::double precision));
  END IF;
  RETURN jsonb_build_object('restaurant', v_r,
    'menu', COALESCE((SELECT jsonb_agg(to_jsonb(m) ORDER BY m.item_id) FROM MenuItems m WHERE m.restaurant_id = p_id AND m.is_available), '[]'));
END $$;

-- ---------- core rule: restaurants must be close to EACH OTHER and to the DESTINATION ----------
-- Fee comparison: separate deliveries vs ONE combined trip (farthest restaurant first, nearest-neighbour pickups, then customer)
CREATE OR REPLACE FUNCTION sp_quote(p_ids INT[], p_lat DOUBLE PRECISION, p_lng DOUBLE PRECISION) RETURNS JSONB LANGUAGE plpgsql AS $$
DECLARE
  v_base NUMERIC := sp_cfg('base_fee');
  v_per  NUMERIC := sp_cfg('per_km_fee');
  v_n INT; v_sep_km NUMERIC; v_sep_fee NUMERIC; v_km NUMERIC := 0; v_combined NUMERIC;
  v_cur RECORD; v_next RECORD; v_left INT[]; v_last DOUBLE PRECISION;
BEGIN
  SELECT COUNT(*), COALESCE(SUM(haversine_km(lat, lng, p_lat, p_lng)), 0)::numeric INTO v_n, v_sep_km
    FROM Restaurants WHERE restaurant_id = ANY(p_ids);
  IF v_n = 0 THEN RETURN NULL; END IF;
  v_sep_fee := round(v_base * v_n + v_per * v_sep_km, 2);

  SELECT restaurant_id, lat, lng INTO v_cur FROM Restaurants WHERE restaurant_id = ANY(p_ids)
   ORDER BY haversine_km(lat, lng, p_lat, p_lng) DESC, restaurant_id LIMIT 1;
  v_left := array_remove(p_ids, v_cur.restaurant_id);
  WHILE COALESCE(cardinality(v_left), 0) > 0 LOOP
    SELECT restaurant_id, lat, lng, haversine_km(v_cur.lat, v_cur.lng, lat, lng) AS d INTO v_next
      FROM Restaurants WHERE restaurant_id = ANY(v_left) ORDER BY d, restaurant_id LIMIT 1;
    v_km := v_km + v_next.d::numeric;
    v_cur := v_next;
    v_left := array_remove(v_left, v_next.restaurant_id);
  END LOOP;
  v_last := haversine_km(v_cur.lat, v_cur.lng, p_lat, p_lng);
  v_km := v_km + v_last::numeric;
  v_combined := round(v_base + v_per * v_km, 2);

  RETURN jsonb_build_object('separate_fee', v_sep_fee, 'combined_fee', v_combined,
    'saved', GREATEST(0, round(v_sep_fee - v_combined, 2)), 'route_km', round(v_km, 2),
    'separate_km', round(v_sep_km, 2), 'eta_min', round(15 + v_km * 3.5)::int, 'separate_deliveries', v_n);
END $$;

CREATE OR REPLACE FUNCTION sp_validate_combo(p_ids INT[], p_lat DOUBLE PRECISION, p_lng DOUBLE PRECISION) RETURNS JSONB LANGUAGE plpgsql AS $$
DECLARE
  v_max_gap  NUMERIC := sp_cfg('max_restaurant_gap_km');
  v_max_dest NUMERIC := sp_cfg('max_destination_km');
  v_limits JSONB := jsonb_build_object('gap_km', sp_cfg('max_restaurant_gap_km'), 'dest_km', sp_cfg('max_destination_km'));
  v_ids INT[]; v_found INT; v_rests JSONB; v_gap NUMERIC; v_reasons JSONB := '[]'; r RECORD;
BEGIN
  IF p_ids IS NULL OR cardinality(p_ids) = 0 OR p_lat IS NULL OR p_lng IS NULL THEN
    PERFORM sp_fail(400, 'restaurant_ids, lat and lng are required');
  END IF;
  SELECT array_agg(DISTINCT x) INTO v_ids FROM unnest(p_ids) x;
    IF cardinality(v_ids) > COALESCE(sp_cfg('max_restaurants_per_order'), 3) THEN
    v_reasons := v_reasons || to_jsonb(format('You can order from at most %s restaurants at once',
                   COALESCE(sp_cfg('max_restaurants_per_order'), 3)::int));
  END IF;

  SELECT COUNT(*), COALESCE(jsonb_agg(jsonb_build_object('restaurant_id', restaurant_id, 'name', name, 'lat', lat, 'lng', lng,
           'dist_km', round(haversine_km(lat, lng, p_lat, p_lng)::numeric, 2)) ORDER BY restaurant_id), '[]')
    INTO v_found, v_rests FROM Restaurants WHERE restaurant_id = ANY(v_ids) AND is_active;
  IF v_found <> cardinality(v_ids) THEN
    RETURN jsonb_build_object('ok', false, 'reasons', jsonb_build_array('One or more restaurants are unavailable'),
                              'limits', v_limits, 'restaurants', v_rests);
  END IF;

  SELECT round(COALESCE(MAX(haversine_km(a.lat, a.lng, b.lat, b.lng)), 0)::numeric, 2) INTO v_gap
    FROM Restaurants a JOIN Restaurants b ON a.restaurant_id < b.restaurant_id
   WHERE a.restaurant_id = ANY(v_ids) AND b.restaurant_id = ANY(v_ids);
  IF v_gap > v_max_gap THEN
    v_reasons := v_reasons || to_jsonb(format('Restaurants are %s km apart (limit %s km)', v_gap, v_max_gap));
  END IF;
  FOR r IN SELECT name, haversine_km(lat, lng, p_lat, p_lng)::numeric AS d FROM Restaurants WHERE restaurant_id = ANY(v_ids) ORDER BY restaurant_id LOOP
    IF r.d > v_max_dest THEN
      v_reasons := v_reasons || to_jsonb(format('%s is %s km from your location (limit %s km)', r.name, round(r.d, 2), v_max_dest));
    END IF;
  END LOOP;

  RETURN jsonb_build_object('ok', jsonb_array_length(v_reasons) = 0, 'reasons', v_reasons, 'max_gap_km', v_gap,
                            'limits', v_limits, 'restaurants', v_rests, 'quote', sp_quote(v_ids, p_lat, p_lng));
END $$;

-- ---------- orders ----------
-- ONE order -> N sub-orders (one per restaurant) -> ONE payment -> ONE delivery. A function body is one transaction:
-- if anything fails, everything is rolled back. Prices are read from MenuItems, never from the client.
-- p_items: [{"item_id": 5, "quantity": 2}, ...]
CREATE OR REPLACE FUNCTION sp_place_order(p_actor INT, p_address TEXT, p_lat DOUBLE PRECISION, p_lng DOUBLE PRECISION, p_items JSONB)
RETURNS JSONB LANGUAGE plpgsql AS $$
DECLARE
  v_lines JSONB; v_rest_ids INT[]; v_v JSONB; v_fee NUMERIC; v_subtotal NUMERIC; v_total NUMERIC;
  v_order INT; v_rid INT; v_sub INT; v_bad INT;
BEGIN
  IF p_actor IS NULL OR NOT EXISTS (SELECT 1 FROM Users WHERE user_id = p_actor) THEN PERFORM sp_fail(401, 'Please log in'); END IF;
  IF p_items IS NULL OR jsonb_typeof(p_items) <> 'array' OR jsonb_array_length(p_items) = 0 OR p_lat IS NULL OR p_lng IS NULL THEN
    PERFORM sp_fail(400, 'Delivery location and at least one item are required');
  END IF;

  -- merge duplicate lines, quantity at least 1
  WITH q AS (SELECT x.item_id, SUM(GREATEST(1, COALESCE(x.quantity, 1)))::int AS quantity
               FROM jsonb_to_recordset(p_items) AS x(item_id INT, quantity INT) GROUP BY x.item_id)
  SELECT COUNT(*) FILTER (WHERE m.item_id IS NULL),
         jsonb_agg(jsonb_build_object('item_id', m.item_id, 'restaurant_id', m.restaurant_id, 'price', m.price, 'quantity', q.quantity))
    INTO v_bad, v_lines
    FROM q LEFT JOIN MenuItems m ON m.item_id = q.item_id AND m.is_available;
  IF v_bad > 0 THEN PERFORM sp_fail(400, 'Some items are no longer available'); END IF;

  SELECT array_agg(DISTINCT l.restaurant_id ORDER BY l.restaurant_id) INTO v_rest_ids
    FROM jsonb_to_recordset(v_lines) AS l(item_id INT, restaurant_id INT, price NUMERIC, quantity INT);

  v_v := sp_validate_combo(v_rest_ids, p_lat, p_lng);
  IF NOT (v_v->>'ok')::boolean THEN
    PERFORM sp_fail(422, (SELECT string_agg(r, '; ') FROM jsonb_array_elements_text(v_v->'reasons') r));
  END IF;

  SELECT SUM(l.price * l.quantity) INTO v_subtotal FROM jsonb_to_recordset(v_lines) AS l(item_id INT, restaurant_id INT, price NUMERIC, quantity INT);
  v_fee := (v_v->'quote'->>'combined_fee')::numeric;
  v_total := round(v_subtotal + v_fee, 2);

  INSERT INTO Orders (user_id, subtotal, delivery_fee, separate_fee_estimate, total_amount, delivery_address, delivery_lat, delivery_lng)
       VALUES (p_actor, v_subtotal, v_fee, (v_v->'quote'->>'separate_fee')::numeric, v_total, NULLIF(p_address, ''), p_lat, p_lng)
    RETURNING order_id INTO v_order;

  FOREACH v_rid IN ARRAY v_rest_ids LOOP
    INSERT INTO SubOrders (order_id, restaurant_id, sub_amount)
      SELECT v_order, v_rid, SUM(l.price * l.quantity)
        FROM jsonb_to_recordset(v_lines) AS l(item_id INT, restaurant_id INT, price NUMERIC, quantity INT) WHERE l.restaurant_id = v_rid
      RETURNING sub_order_id INTO v_sub;
    INSERT INTO SubOrderItems (sub_order_id, item_id, quantity, price_at_order)
      SELECT v_sub, l.item_id, l.quantity, l.price
        FROM jsonb_to_recordset(v_lines) AS l(item_id INT, restaurant_id INT, price NUMERIC, quantity INT) WHERE l.restaurant_id = v_rid;
  END LOOP;

  INSERT INTO Payments (order_id, amount) VALUES (v_order, v_total);
  RETURN jsonb_build_object('message', 'Order placed', 'order_id', v_order, 'total', v_total, 'delivery_fee', v_fee,
                            'saved', (v_v->'quote'->>'saved')::numeric);
END $$;

CREATE OR REPLACE FUNCTION sp_order_detail(p_actor INT, p_order INT) RETURNS JSONB LANGUAGE plpgsql AS $$
BEGIN
  PERFORM sp_assert_order_access(p_order, p_actor);
  RETURN jsonb_build_object(
    'order', (SELECT to_jsonb(o) FROM Orders o WHERE o.order_id = p_order),
    'sub_orders', COALESCE((
       SELECT jsonb_agg(to_jsonb(so) || jsonb_build_object('restaurant_name', r.name, 'items', COALESCE((
                SELECT jsonb_agg(to_jsonb(soi) || jsonb_build_object('name', m.name) ORDER BY soi.id)
                  FROM SubOrderItems soi JOIN MenuItems m ON m.item_id = soi.item_id WHERE soi.sub_order_id = so.sub_order_id), '[]'))
              ORDER BY so.sub_order_id)
         FROM SubOrders so JOIN Restaurants r ON r.restaurant_id = so.restaurant_id WHERE so.order_id = p_order), '[]'),
    'payment', (SELECT to_jsonb(p) FROM Payments p WHERE p.order_id = p_order),
    'delivery', (SELECT to_jsonb(da) || jsonb_build_object('name', dp.name, 'phone', dp.phone)
                   FROM DeliveryAssignment da JOIN DeliveryPartners dp ON dp.partner_id = da.partner_id WHERE da.order_id = p_order));
END $$;

CREATE OR REPLACE FUNCTION sp_user_orders(p_actor INT) RETURNS JSONB LANGUAGE plpgsql AS $$
BEGIN
  IF p_actor IS NULL THEN PERFORM sp_fail(401, 'Please log in'); END IF;
  RETURN COALESCE((
    SELECT jsonb_agg(to_jsonb(o) || jsonb_build_object('sub_orders', s.subs) ORDER BY o.created_at DESC, o.order_id DESC)
      FROM Orders o
      JOIN LATERAL (SELECT jsonb_agg(jsonb_build_object('sub_order_id', so.sub_order_id, 'restaurant', r.name,
                                                        'status', so.sub_status, 'amount', so.sub_amount) ORDER BY so.sub_order_id) AS subs
                      FROM SubOrders so JOIN Restaurants r ON r.restaurant_id = so.restaurant_id WHERE so.order_id = o.order_id) s ON s.subs IS NOT NULL
     WHERE o.user_id = p_actor), '[]');
END $$;

CREATE OR REPLACE FUNCTION sp_pay_order(p_actor INT, p_order INT) RETURNS JSONB LANGUAGE plpgsql AS $$
DECLARE v_p Payments%ROWTYPE;
BEGIN
  PERFORM sp_assert_order_access(p_order, p_actor);
  UPDATE Payments SET status = 'paid', paid_at = NOW() WHERE order_id = p_order AND status = 'unpaid' RETURNING * INTO v_p;
  IF NOT FOUND THEN PERFORM sp_fail(409, 'Already paid'); END IF;
  RETURN to_jsonb(v_p);
END $$;

-- ONE delivery partner for the whole order: the nearest free partner to the first pickup (Haversine)
CREATE OR REPLACE FUNCTION sp_assign_delivery(p_actor INT, p_order INT) RETURNS JSONB LANGUAGE plpgsql AS $$
DECLARE v_first RECORD; v_p RECORD;
BEGIN
  PERFORM sp_assert_order_access(p_order, p_actor);
  IF EXISTS (SELECT 1 FROM DeliveryAssignment WHERE order_id = p_order) THEN
    PERFORM sp_fail(409, 'A delivery partner is already assigned to this order');
  END IF;
  SELECT r.lat, r.lng INTO v_first FROM SubOrders so JOIN Restaurants r ON r.restaurant_id = so.restaurant_id
   WHERE so.order_id = p_order AND so.sub_status <> 'cancelled' ORDER BY so.sub_order_id LIMIT 1;
  IF NOT FOUND THEN PERFORM sp_fail(404, 'No active sub-orders for this order'); END IF;

  SELECT partner_id, name, haversine_km(lat, lng, v_first.lat, v_first.lng) AS d INTO v_p
    FROM DeliveryPartners WHERE is_available ORDER BY d LIMIT 1 FOR UPDATE SKIP LOCKED;
  IF NOT FOUND THEN PERFORM sp_fail(409, 'No delivery partner available right now'); END IF;

  INSERT INTO DeliveryAssignment (order_id, partner_id, distance_km) VALUES (p_order, v_p.partner_id, round(v_p.d::numeric, 2));
  UPDATE DeliveryPartners SET is_available = FALSE WHERE partner_id = v_p.partner_id;
  RETURN jsonb_build_object('message', 'Delivery partner assigned', 'partner', v_p.name);
EXCEPTION WHEN unique_violation THEN
  PERFORM sp_fail(409, 'A delivery partner is already assigned to this order');
END $$;

-- Sub-order status change. Cancelling refunds ONLY this restaurant's share (partial refund); other sub-orders continue.
CREATE OR REPLACE FUNCTION sp_update_sub_order_status(p_actor INT, p_id INT, p_status TEXT, p_reason TEXT) RETURNS JSONB LANGUAGE plpgsql AS $$
DECLARE v_s SubOrders%ROWTYPE; v_ref Refunds%ROWTYPE;
BEGIN
  PERFORM sp_require_staff(p_actor);
  IF p_status IS NULL OR p_status NOT IN ('pending', 'preparing', 'ready', 'delivered', 'cancelled') THEN PERFORM sp_fail(400, 'Invalid status'); END IF;
  SELECT * INTO v_s FROM SubOrders WHERE sub_order_id = p_id AND restaurant_id = sp_staff_restaurant(p_actor) FOR UPDATE;
  IF NOT FOUND THEN PERFORM sp_fail(404, 'Sub-order not found or not owned by your restaurant'); END IF;
  IF v_s.sub_status = 'cancelled' THEN PERFORM sp_fail(409, 'Sub-order already cancelled'); END IF;

  UPDATE SubOrders SET sub_status = p_status WHERE sub_order_id = p_id;
  IF p_status = 'cancelled' THEN
    INSERT INTO Refunds (sub_order_id, amount, reason)
         VALUES (p_id, v_s.sub_amount, COALESCE(NULLIF(p_reason, ''), 'Cancelled by restaurant')) RETURNING * INTO v_ref;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM SubOrders WHERE order_id = v_s.order_id AND sub_status NOT IN ('delivered', 'cancelled')) THEN
    UPDATE Orders SET overall_status = 'completed' WHERE order_id = v_s.order_id;
  END IF;
  RETURN jsonb_build_object('message', 'Status updated', 'refund', CASE WHEN p_status = 'cancelled' THEN to_jsonb(v_ref) END);
END $$;

-- assigned -> picked_up -> delivered ; on delivered the partner is free again and the order is completed
CREATE OR REPLACE FUNCTION sp_update_delivery_status(p_actor INT, p_order INT, p_status TEXT) RETURNS JSONB LANGUAGE plpgsql AS $$
DECLARE v_d DeliveryAssignment%ROWTYPE;
BEGIN
  PERFORM sp_require_staff(p_actor);
  SELECT * INTO v_d FROM DeliveryAssignment WHERE order_id = p_order FOR UPDATE;
  IF NOT FOUND THEN PERFORM sp_fail(404, 'No delivery assigned for this order'); END IF;
  IF NOT ((v_d.status = 'assigned' AND p_status = 'picked_up') OR (v_d.status = 'picked_up' AND p_status = 'delivered')) THEN
    PERFORM sp_fail(409, format('Cannot move from %s to %s', v_d.status, p_status));
  END IF;
  IF p_status = 'picked_up' THEN
    UPDATE DeliveryAssignment SET status = 'picked_up', picked_up_at = NOW() WHERE order_id = p_order;
    UPDATE SubOrders SET sub_status = 'ready' WHERE order_id = p_order AND sub_status IN ('pending', 'preparing');
  ELSE
    UPDATE DeliveryAssignment SET status = 'delivered', delivered_at = NOW() WHERE order_id = p_order;
    UPDATE DeliveryPartners SET is_available = TRUE, total_deliveries = total_deliveries + 1 WHERE partner_id = v_d.partner_id;
    UPDATE SubOrders SET sub_status = 'delivered' WHERE order_id = p_order AND sub_status <> 'cancelled';
    UPDATE Orders SET overall_status = 'completed' WHERE order_id = p_order;
  END IF;
  RETURN jsonb_build_object('message', 'Delivery ' || replace(p_status, '_', ' '));
END $$;

-- ---------- restaurant panel (staff only: every function starts with sp_require_staff) ----------
CREATE OR REPLACE FUNCTION sp_admin_dashboard(p_actor INT) RETURNS JSONB LANGUAGE plpgsql AS $$
DECLARE v_rid INT;
BEGIN
  PERFORM sp_require_staff(p_actor); v_rid := sp_staff_restaurant(p_actor);
  RETURN (SELECT to_jsonb(c) FROM (SELECT
      1::int AS restaurants,
      (SELECT COUNT(*) FROM MenuItems WHERE restaurant_id = v_rid)::int AS menu_items,
      (SELECT COUNT(*) FROM Users WHERE role = 'customer')::int AS customers,
      (SELECT COUNT(*) FROM SubOrders WHERE restaurant_id = v_rid AND sub_status NOT IN ('delivered','cancelled'))::int AS active_orders,
      (SELECT COUNT(*) FROM SubOrders WHERE restaurant_id = v_rid)::int AS total_sub_orders,
      (SELECT COALESCE(SUM(amount), 0) FROM Refunds f JOIN SubOrders so ON so.sub_order_id=f.sub_order_id WHERE so.restaurant_id=v_rid) AS refunded) c);
END $$;

-- Revenue report: JOIN + GROUP BY + SUM/COUNT aggregation
CREATE OR REPLACE FUNCTION sp_admin_revenue_report(p_actor INT) RETURNS JSONB LANGUAGE plpgsql AS $$
DECLARE v_rid INT;
BEGIN
  PERFORM sp_require_staff(p_actor); v_rid := sp_staff_restaurant(p_actor);
  RETURN jsonb_build_object(
    'by_restaurant', COALESCE((SELECT jsonb_agg(to_jsonb(t)) FROM (
      SELECT r.name, COUNT(*)::int AS sub_orders, COALESCE(SUM(so.sub_amount),0) AS revenue
      FROM SubOrders so JOIN Restaurants r ON r.restaurant_id = so.restaurant_id
      WHERE so.restaurant_id = v_rid AND so.sub_status <> 'cancelled' GROUP BY r.name) t), '[]'),
    'summary', (SELECT to_jsonb(s) FROM (SELECT COUNT(DISTINCT so.order_id)::int AS orders,
      COALESCE(SUM(so.sub_amount) FILTER (WHERE so.sub_status <> 'cancelled'),0) AS gross,
      0::numeric AS delivery_saved, 1::numeric AS avg_restaurants FROM SubOrders so WHERE so.restaurant_id = v_rid) s));
END $$;

CREATE OR REPLACE FUNCTION sp_admin_orders(p_actor INT) RETURNS JSONB LANGUAGE plpgsql AS $$
DECLARE v_rid INT;
BEGIN
  PERFORM sp_require_staff(p_actor); v_rid := sp_staff_restaurant(p_actor);
  RETURN COALESCE((SELECT jsonb_agg(to_jsonb(t) ORDER BY t.order_id DESC) FROM (
    SELECT o.order_id, o.created_at, so.sub_amount, so.sub_status, o.overall_status,so.sub_order_id,
           o.delivery_address, u.name AS customer, u.phone, p.status AS payment_status,
           da.status AS delivery_status, dp.name AS partner, r.name AS restaurant
      FROM SubOrders so JOIN Orders o ON o.order_id = so.order_id JOIN Users u ON u.user_id = o.user_id
      JOIN Restaurants r ON r.restaurant_id = so.restaurant_id
      LEFT JOIN Payments p ON p.order_id = o.order_id LEFT JOIN DeliveryAssignment da ON da.order_id = o.order_id
      LEFT JOIN DeliveryPartners dp ON dp.partner_id = da.partner_id
     WHERE so.restaurant_id = v_rid ORDER BY o.order_id DESC LIMIT 100) t), '[]');
END $$;

CREATE OR REPLACE FUNCTION sp_admin_sub_orders(p_actor INT) RETURNS JSONB LANGUAGE plpgsql AS $$
DECLARE v_rid INT;
BEGIN
  PERFORM sp_require_staff(p_actor); v_rid := sp_staff_restaurant(p_actor);
  RETURN COALESCE((SELECT jsonb_agg(to_jsonb(t) ORDER BY t.sub_order_id DESC) FROM (
    SELECT so.sub_order_id, so.order_id, so.sub_status, so.sub_amount, r.name AS restaurant, u.name AS customer
      FROM SubOrders so JOIN Orders o ON o.order_id = so.order_id JOIN Users u ON u.user_id = o.user_id
      JOIN Restaurants r ON r.restaurant_id = so.restaurant_id WHERE so.restaurant_id = v_rid
      ORDER BY so.sub_order_id DESC LIMIT 100) t), '[]');
END $$;

CREATE OR REPLACE FUNCTION sp_admin_refunds(p_actor INT) RETURNS JSONB LANGUAGE plpgsql AS $$
DECLARE v_rid INT;
BEGIN
  PERFORM sp_require_staff(p_actor); v_rid := sp_staff_restaurant(p_actor);
  RETURN COALESCE((SELECT jsonb_agg(to_jsonb(t) ORDER BY t.refund_id DESC) FROM (
    SELECT f.*, so.order_id, r.name AS restaurant FROM Refunds f JOIN SubOrders so ON so.sub_order_id = f.sub_order_id
      JOIN Restaurants r ON r.restaurant_id = so.restaurant_id WHERE so.restaurant_id = v_rid) t), '[]');
END $$;

CREATE OR REPLACE FUNCTION sp_admin_restaurants(p_actor INT) RETURNS JSONB LANGUAGE plpgsql AS $$
DECLARE v_rid INT;
BEGIN
  PERFORM sp_require_staff(p_actor); v_rid := sp_staff_restaurant(p_actor);
  RETURN COALESCE((SELECT jsonb_agg(to_jsonb(t)) FROM (
    SELECT r.*, (SELECT COUNT(*) FROM MenuItems m WHERE m.restaurant_id = r.restaurant_id)::int AS item_count,
                (SELECT COUNT(*) FROM SubOrders so WHERE so.restaurant_id = r.restaurant_id)::int AS order_count
      FROM Restaurants r WHERE r.restaurant_id = v_rid) t), '[]');
END $$;

CREATE OR REPLACE FUNCTION sp_admin_restaurant_menu(p_actor INT, p_id INT) RETURNS JSONB LANGUAGE plpgsql AS $$
DECLARE v_rid INT;
BEGIN
  PERFORM sp_require_staff(p_actor); v_rid := sp_staff_restaurant(p_actor);
  IF p_id <> v_rid THEN PERFORM sp_fail(403, 'You can only manage your own restaurant'); END IF;
  RETURN COALESCE((SELECT jsonb_agg(to_jsonb(m) ORDER BY m.category, m.item_id) FROM MenuItems m WHERE m.restaurant_id = v_rid), '[]');
END $$;

-- Restaurant creation is a platform/setup operation, not a customer or restaurant-panel operation.
CREATE OR REPLACE FUNCTION sp_admin_add_restaurant(p_actor INT, p JSONB) RETURNS JSONB LANGUAGE plpgsql AS $$
BEGIN
  PERFORM sp_fail(403, 'Restaurants are created by the platform, not from a restaurant account');
END $$;

CREATE OR REPLACE FUNCTION sp_admin_update_restaurant(p_actor INT, p_id INT, p JSONB) RETURNS JSONB LANGUAGE plpgsql AS $$
DECLARE v_r Restaurants%ROWTYPE; v_rid INT;
BEGIN
  PERFORM sp_require_staff(p_actor); v_rid := sp_staff_restaurant(p_actor);
  IF p_id <> v_rid THEN PERFORM sp_fail(403, 'You can only manage your own restaurant'); END IF;
  IF NOT (p ?| ARRAY['name', 'address', 'area', 'cuisine_type', 'photo_url', 'cost_for_two', 'prep_time_min', 'is_active']) THEN
    PERFORM sp_fail(400, 'Nothing to update');
  END IF;
  IF p ? 'name' AND NULLIF(trim(p->>'name'), '') IS NULL THEN PERFORM sp_fail(400, 'Name cannot be empty'); END IF;
  UPDATE Restaurants SET
    name = CASE WHEN p ? 'name' THEN trim(p->>'name') ELSE name END,
    address = CASE WHEN p ? 'address' THEN NULLIF(p->>'address', '') ELSE address END,
    area = CASE WHEN p ? 'area' THEN NULLIF(p->>'area', '') ELSE area END,
    cuisine_type = CASE WHEN p ? 'cuisine_type' THEN NULLIF(p->>'cuisine_type', '') ELSE cuisine_type END,
    photo_url = CASE WHEN p ? 'photo_url' THEN NULLIF(p->>'photo_url', '') ELSE photo_url END,
    cost_for_two = CASE WHEN p ? 'cost_for_two' THEN NULLIF(p->>'cost_for_two', '')::int ELSE cost_for_two END,
    prep_time_min = CASE WHEN p ? 'prep_time_min' THEN NULLIF(p->>'prep_time_min', '')::int ELSE prep_time_min END,
    is_active = CASE WHEN p ? 'is_active' THEN COALESCE((p->>'is_active')::boolean, is_active) ELSE is_active END
  WHERE restaurant_id = v_rid RETURNING * INTO v_r;
  RETURN to_jsonb(v_r);
END $$;

CREATE OR REPLACE FUNCTION sp_admin_add_menu_item(p_actor INT, p JSONB) RETURNS JSONB LANGUAGE plpgsql AS $$
DECLARE v_m MenuItems%ROWTYPE; v_rid INT;
BEGIN
  PERFORM sp_require_staff(p_actor); v_rid := sp_staff_restaurant(p_actor);
  IF NULLIF(trim(p->>'name'), '') IS NULL OR NULLIF(p->>'price', '') IS NULL THEN
    PERFORM sp_fail(400, 'Item name and price are required');
  END IF;
  INSERT INTO MenuItems (restaurant_id, category, name, description, price, is_veg, is_bestseller)
  VALUES (v_rid, COALESCE(NULLIF(p->>'category', ''), 'Main course'), trim(p->>'name'), p->>'description',
          (p->>'price')::numeric, COALESCE((p->>'is_veg')::boolean, FALSE), COALESCE((p->>'is_bestseller')::boolean, FALSE))
  RETURNING * INTO v_m;
  RETURN to_jsonb(v_m);
END $$;

CREATE OR REPLACE FUNCTION sp_admin_update_menu_item(p_actor INT, p_id INT, p JSONB) RETURNS JSONB LANGUAGE plpgsql AS $$
DECLARE v_m MenuItems%ROWTYPE; v_rid INT;
BEGIN
  PERFORM sp_require_staff(p_actor); v_rid := sp_staff_restaurant(p_actor);
  IF NOT (p ?| ARRAY['name', 'description', 'price', 'category', 'is_veg', 'is_bestseller', 'is_available']) THEN PERFORM sp_fail(400, 'Nothing to update'); END IF;
  IF p ? 'name' AND NULLIF(trim(p->>'name'), '') IS NULL THEN PERFORM sp_fail(400, 'Name cannot be empty'); END IF;
  UPDATE MenuItems SET
    name = CASE WHEN p ? 'name' THEN trim(p->>'name') ELSE name END,
    description = CASE WHEN p ? 'description' THEN NULLIF(p->>'description', '') ELSE description END,
    price = CASE WHEN p ? 'price' THEN (p->>'price')::numeric ELSE price END,
    category = CASE WHEN p ? 'category' THEN NULLIF(p->>'category', '') ELSE category END,
    is_veg = CASE WHEN p ? 'is_veg' THEN COALESCE((p->>'is_veg')::boolean, is_veg) ELSE is_veg END,
    is_bestseller = CASE WHEN p ? 'is_bestseller' THEN COALESCE((p->>'is_bestseller')::boolean, is_bestseller) ELSE is_bestseller END,
    is_available = CASE WHEN p ? 'is_available' THEN COALESCE((p->>'is_available')::boolean, is_available) ELSE is_available END
  WHERE item_id = p_id AND restaurant_id = v_rid RETURNING * INTO v_m;
  IF NOT FOUND THEN PERFORM sp_fail(403, 'You can only manage items from your own restaurant'); END IF;
  RETURN to_jsonb(v_m);
END $$;

CREATE OR REPLACE FUNCTION sp_admin_delete_menu_item(p_actor INT, p_id INT) RETURNS JSONB LANGUAGE plpgsql AS $$
DECLARE v_rid INT;
BEGIN
  PERFORM sp_require_staff(p_actor); v_rid := sp_staff_restaurant(p_actor);
  DELETE FROM MenuItems WHERE item_id = p_id AND restaurant_id = v_rid;
  IF NOT FOUND THEN PERFORM sp_fail(403, 'You can only delete items from your own restaurant'); END IF;
  RETURN jsonb_build_object('message', 'Deleted');
EXCEPTION WHEN foreign_key_violation THEN
  PERFORM sp_fail(409, 'This item is part of past orders, so mark it unavailable instead.');
END $$;

CREATE OR REPLACE FUNCTION sp_admin_add_partner(p_actor INT, p JSONB) RETURNS JSONB LANGUAGE plpgsql AS $$
DECLARE v_p DeliveryPartners%ROWTYPE;
BEGIN
  PERFORM sp_require_staff(p_actor);
  IF NULLIF(trim(p->>'name'), '') IS NULL OR NULLIF(p->>'lat', '') IS NULL OR NULLIF(p->>'lng', '') IS NULL THEN
    PERFORM sp_fail(400, 'Name, latitude and longitude are required');
  END IF;
  INSERT INTO DeliveryPartners (name, phone, lat, lng, zone, vehicle_type, vehicle_no)
  VALUES (trim(p->>'name'), NULLIF(p->>'phone', ''), (p->>'lat')::double precision, (p->>'lng')::double precision,
          NULLIF(p->>'zone', ''), COALESCE(NULLIF(p->>'vehicle_type', ''), 'Bike'), NULLIF(p->>'vehicle_no', ''))
  RETURNING * INTO v_p;
  RETURN to_jsonb(v_p);
END $$;

CREATE OR REPLACE FUNCTION sp_admin_update_partner(p_actor INT, p_id INT, p JSONB) RETURNS JSONB LANGUAGE plpgsql AS $$
DECLARE v_p DeliveryPartners%ROWTYPE;
BEGIN
  PERFORM sp_require_staff(p_actor);
  IF NOT (p ?| ARRAY['name', 'phone', 'zone', 'vehicle_type', 'vehicle_no', 'is_available']) THEN PERFORM sp_fail(400, 'Nothing to update'); END IF;
  IF p ? 'name' AND NULLIF(trim(p->>'name'), '') IS NULL THEN PERFORM sp_fail(400, 'Name cannot be empty'); END IF;
  UPDATE DeliveryPartners SET
    name         = CASE WHEN p ? 'name'         THEN trim(p->>'name') ELSE name END,
    phone        = CASE WHEN p ? 'phone'        THEN NULLIF(p->>'phone', '') ELSE phone END,
    zone         = CASE WHEN p ? 'zone'         THEN NULLIF(p->>'zone', '') ELSE zone END,
    vehicle_type = CASE WHEN p ? 'vehicle_type' THEN COALESCE(NULLIF(p->>'vehicle_type', ''), vehicle_type) ELSE vehicle_type END,
    vehicle_no   = CASE WHEN p ? 'vehicle_no'   THEN NULLIF(p->>'vehicle_no', '') ELSE vehicle_no END,
    is_available = CASE WHEN p ? 'is_available' THEN COALESCE((p->>'is_available')::boolean, is_available) ELSE is_available END
  WHERE partner_id = p_id RETURNING * INTO v_p;
  IF NOT FOUND THEN PERFORM sp_fail(404, 'Partner not found'); END IF;
  RETURN to_jsonb(v_p);
END $$;

-- ---------- health (used by the Architecture page) ----------
CREATE OR REPLACE FUNCTION sp_health() RETURNS JSONB LANGUAGE sql STABLE AS $$
  SELECT jsonb_build_object('db_name', current_database(), 'db_version', split_part(version(), ',', 1),
    'procedures', (SELECT COUNT(*) FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
                    WHERE n.nspname = current_schema() AND p.proname LIKE 'sp\_%')::int,
    'counts', jsonb_build_object('restaurants', (SELECT COUNT(*) FROM Restaurants)::int,
                                 'menu_items', (SELECT COUNT(*) FROM MenuItems)::int,
                                 'orders', (SELECT COUNT(*) FROM Orders)::int))
$$;
