# FIX Appliance CRM

A lightweight CRM for an appliance-repair business. Track customers, the appliances
they own, and repair jobs from intake through completion.

- **Backend** — Node.js + Express REST API with a local SQLite database
  (`better-sqlite3`). No external services required.
- **Frontend** — React + Vite single-page app with a dashboard, customer
  management, and a repair-job pipeline.

## Project layout

```
.
├── server/           # Express API + SQLite (better-sqlite3)
│   └── src/
│       ├── index.js  # API routes
│       ├── db.js     # schema + connection
│       └── seed.js   # demo data
├── client/           # React + Vite SPA
│   └── src/
└── .cursor/          # Cloud Agent environment config
```

## Getting started

Requires Node.js 20+.

```bash
npm install     # install server + client workspaces
npm run seed    # create + seed the local SQLite database (idempotent)
npm run dev     # start API (:4000) and web app (:5173) together
```

Then open http://localhost:5173. The Vite dev server proxies `/api/*` to the
API on port 4000.

### Useful commands

| Command | Description |
| --- | --- |
| `npm run dev` | Run API + web app together (via `concurrently`). |
| `npm run dev:server` | Run only the API (`node --watch`). |
| `npm run dev:client` | Run only the Vite dev server. |
| `npm run seed` | Seed demo data (skips if data exists; `-- --force` to reset). |
| `npm run build` | Build the client for production into `client/dist`. |

## API overview

Base URL: `http://localhost:4000/api`

| Method | Path | Description |
| --- | --- | --- |
| GET | `/health` | Health check. |
| GET | `/stats` | Dashboard counts + revenue. |
| GET | `/meta` | Allowed job statuses/priorities. |
| GET/POST | `/customers` | List / create customers. |
| GET/PUT/DELETE | `/customers/:id` | Read / update / delete a customer. |
| POST | `/customers/:id/appliances` | Add an appliance to a customer. |
| GET/POST | `/jobs` | List / create repair jobs. |
| PATCH/DELETE | `/jobs/:id` | Update / delete a repair job. |

Job status values: `new`, `scheduled`, `in_progress`, `completed`, `cancelled`.
