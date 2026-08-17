import express from "express";
import cors from "cors";
import { existsSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { db, initSchema, JOB_STATUSES, JOB_PRIORITIES } from "./db.js";

const __dirname = dirname(fileURLToPath(import.meta.url));

initSchema();

const app = express();
app.use(cors());
app.use(express.json());

const api = express.Router();

api.get("/health", (_req, res) => {
  res.json({ status: "ok", time: new Date().toISOString() });
});

// ---- Dashboard stats ----
api.get("/stats", (_req, res) => {
  const customers = db.prepare("SELECT COUNT(*) AS n FROM customers").get().n;
  const appliances = db.prepare("SELECT COUNT(*) AS n FROM appliances").get().n;
  const openJobs = db
    .prepare("SELECT COUNT(*) AS n FROM jobs WHERE status NOT IN ('completed','cancelled')")
    .get().n;
  const revenue = db
    .prepare("SELECT COALESCE(SUM(cost),0) AS total FROM jobs WHERE status = 'completed'")
    .get().total;
  const byStatus = db
    .prepare("SELECT status, COUNT(*) AS n FROM jobs GROUP BY status")
    .all();
  res.json({ customers, appliances, openJobs, revenue, byStatus });
});

// ---- Customers ----
api.get("/customers", (_req, res) => {
  const rows = db
    .prepare(
      `SELECT c.*,
        (SELECT COUNT(*) FROM appliances a WHERE a.customer_id = c.id) AS appliance_count,
        (SELECT COUNT(*) FROM jobs j WHERE j.customer_id = c.id) AS job_count
       FROM customers c ORDER BY c.created_at DESC, c.id DESC`
    )
    .all();
  res.json(rows);
});

api.get("/customers/:id", (req, res) => {
  const customer = db.prepare("SELECT * FROM customers WHERE id = ?").get(req.params.id);
  if (!customer) return res.status(404).json({ error: "Customer not found" });
  customer.appliances = db
    .prepare("SELECT * FROM appliances WHERE customer_id = ? ORDER BY id")
    .all(customer.id);
  customer.jobs = db
    .prepare("SELECT * FROM jobs WHERE customer_id = ? ORDER BY created_at DESC, id DESC")
    .all(customer.id);
  res.json(customer);
});

api.post("/customers", (req, res) => {
  const { name, email, phone, address } = req.body ?? {};
  if (!name || !String(name).trim()) {
    return res.status(400).json({ error: "name is required" });
  }
  const info = db
    .prepare("INSERT INTO customers (name, email, phone, address) VALUES (?, ?, ?, ?)")
    .run(String(name).trim(), email ?? null, phone ?? null, address ?? null);
  res.status(201).json(db.prepare("SELECT * FROM customers WHERE id = ?").get(info.lastInsertRowid));
});

api.put("/customers/:id", (req, res) => {
  const existing = db.prepare("SELECT * FROM customers WHERE id = ?").get(req.params.id);
  if (!existing) return res.status(404).json({ error: "Customer not found" });
  const { name, email, phone, address } = { ...existing, ...req.body };
  db.prepare("UPDATE customers SET name = ?, email = ?, phone = ?, address = ? WHERE id = ?").run(
    name,
    email ?? null,
    phone ?? null,
    address ?? null,
    req.params.id
  );
  res.json(db.prepare("SELECT * FROM customers WHERE id = ?").get(req.params.id));
});

api.delete("/customers/:id", (req, res) => {
  const info = db.prepare("DELETE FROM customers WHERE id = ?").run(req.params.id);
  if (info.changes === 0) return res.status(404).json({ error: "Customer not found" });
  res.status(204).end();
});

// ---- Appliances ----
api.post("/customers/:id/appliances", (req, res) => {
  const customer = db.prepare("SELECT id FROM customers WHERE id = ?").get(req.params.id);
  if (!customer) return res.status(404).json({ error: "Customer not found" });
  const { type, brand, model, serial } = req.body ?? {};
  if (!type || !String(type).trim()) {
    return res.status(400).json({ error: "type is required" });
  }
  const info = db
    .prepare(
      "INSERT INTO appliances (customer_id, type, brand, model, serial) VALUES (?, ?, ?, ?, ?)"
    )
    .run(req.params.id, String(type).trim(), brand ?? null, model ?? null, serial ?? null);
  res.status(201).json(db.prepare("SELECT * FROM appliances WHERE id = ?").get(info.lastInsertRowid));
});

api.delete("/appliances/:id", (req, res) => {
  const info = db.prepare("DELETE FROM appliances WHERE id = ?").run(req.params.id);
  if (info.changes === 0) return res.status(404).json({ error: "Appliance not found" });
  res.status(204).end();
});

// ---- Jobs ----
api.get("/jobs", (req, res) => {
  const { status } = req.query;
  const base = `SELECT j.*, c.name AS customer_name,
      a.type AS appliance_type, a.brand AS appliance_brand
    FROM jobs j
    JOIN customers c ON c.id = j.customer_id
    LEFT JOIN appliances a ON a.id = j.appliance_id`;
  const rows = status
    ? db.prepare(`${base} WHERE j.status = ? ORDER BY j.created_at DESC, j.id DESC`).all(status)
    : db.prepare(`${base} ORDER BY j.created_at DESC, j.id DESC`).all();
  res.json(rows);
});

api.post("/jobs", (req, res) => {
  const { customer_id, appliance_id, title, description, priority, technician, cost, status } =
    req.body ?? {};
  if (!customer_id) return res.status(400).json({ error: "customer_id is required" });
  if (!title || !String(title).trim()) return res.status(400).json({ error: "title is required" });
  const customer = db.prepare("SELECT id FROM customers WHERE id = ?").get(customer_id);
  if (!customer) return res.status(400).json({ error: "customer_id does not exist" });
  if (priority && !JOB_PRIORITIES.includes(priority)) {
    return res.status(400).json({ error: `priority must be one of ${JOB_PRIORITIES.join(", ")}` });
  }
  if (status && !JOB_STATUSES.includes(status)) {
    return res.status(400).json({ error: `status must be one of ${JOB_STATUSES.join(", ")}` });
  }
  const info = db
    .prepare(
      `INSERT INTO jobs (customer_id, appliance_id, title, description, status, priority, technician, cost)
       VALUES (?, ?, ?, ?, ?, ?, ?, ?)`
    )
    .run(
      customer_id,
      appliance_id ?? null,
      String(title).trim(),
      description ?? null,
      status ?? "new",
      priority ?? "normal",
      technician ?? null,
      Number(cost) || 0
    );
  res.status(201).json(getJobWithJoins(info.lastInsertRowid));
});

api.patch("/jobs/:id", (req, res) => {
  const existing = db.prepare("SELECT * FROM jobs WHERE id = ?").get(req.params.id);
  if (!existing) return res.status(404).json({ error: "Job not found" });
  const next = { ...existing, ...req.body };
  if (!JOB_STATUSES.includes(next.status)) {
    return res.status(400).json({ error: `status must be one of ${JOB_STATUSES.join(", ")}` });
  }
  if (!JOB_PRIORITIES.includes(next.priority)) {
    return res.status(400).json({ error: `priority must be one of ${JOB_PRIORITIES.join(", ")}` });
  }
  db.prepare(
    `UPDATE jobs SET title = ?, description = ?, status = ?, priority = ?, technician = ?, cost = ?,
       appliance_id = ?, updated_at = datetime('now') WHERE id = ?`
  ).run(
    next.title,
    next.description ?? null,
    next.status,
    next.priority,
    next.technician ?? null,
    Number(next.cost) || 0,
    next.appliance_id ?? null,
    req.params.id
  );
  res.json(getJobWithJoins(req.params.id));
});

api.delete("/jobs/:id", (req, res) => {
  const info = db.prepare("DELETE FROM jobs WHERE id = ?").run(req.params.id);
  if (info.changes === 0) return res.status(404).json({ error: "Job not found" });
  res.status(204).end();
});

api.get("/meta", (_req, res) => {
  res.json({ statuses: JOB_STATUSES, priorities: JOB_PRIORITIES });
});

function getJobWithJoins(id) {
  return db
    .prepare(
      `SELECT j.*, c.name AS customer_name, a.type AS appliance_type, a.brand AS appliance_brand
       FROM jobs j JOIN customers c ON c.id = j.customer_id
       LEFT JOIN appliances a ON a.id = j.appliance_id WHERE j.id = ?`
    )
    .get(id);
}

app.use("/api", api);

// Serve built client in production, if present.
const clientDist = join(__dirname, "..", "..", "client", "dist");
if (existsSync(clientDist)) {
  app.use(express.static(clientDist));
  app.get("*", (_req, res) => res.sendFile(join(clientDist, "index.html")));
}

const PORT = process.env.PORT || 4000;
app.listen(PORT, () => {
  console.log(`FIX Appliance CRM API listening on http://localhost:${PORT}`);
});
