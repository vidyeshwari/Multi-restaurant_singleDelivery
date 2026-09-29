# MultiEats — Multi-Restaurant Single-Delivery System

## Role model (important)

There are two kinds of users:

- Customer: can browse restaurants, view menus, add items to cart, place orders, and see their own orders. Public signup always creates a customer account.
- Restaurant account: created by the platform/setup and linked to one specific restaurant. That account can edit only its own restaurant details, add/edit/delete its own menu items, change item availability, and update its own sub-orders.

A customer cannot open the restaurant panel. The database also rejects restaurant-panel requests from customers.

A restaurant account cannot:
- add another restaurant from the restaurant panel;
- edit another restaurant;
- view or edit another restaurant's menu;
- manage delivery partners or platform-wide settings.

## Demo restaurant login

Email: restaurant@multieats.test
Password: restaurant123

## Run

1. Configure backend/.env from .env.example with PostgreSQL credentials.
2. Make sure PostgreSQL is running.
3. From backend run:

npm install
npm run setup-db
npm start

4. Open frontend/login.html or frontend/index.html.

## Customer flow

Customer login/signup → Restaurants → Restaurant menu → Add to cart → Cart → Order.

## Restaurant flow

Restaurant login → Restaurant Panel → My Restaurant / Menu / Orders.

The panel is automatically scoped to the restaurant linked to the logged-in account.