import { useEffect, useState, useCallback } from "react";
import { api } from "./api.js";

const STATUS_LABELS = {
  new: "New",
  scheduled: "Scheduled",
  in_progress: "In progress",
  completed: "Completed",
  cancelled: "Cancelled",
};

const money = (n) => `$${Number(n || 0).toFixed(2)}`;

export default function App() {
  const [view, setView] = useState("dashboard");
  const [toast, setToast] = useState(null);

  const notify = useCallback((message, kind = "success") => {
    setToast({ message, kind });
    setTimeout(() => setToast(null), 3000);
  }, []);

  return (
    <div className="app">
      <aside className="sidebar">
        <div className="brand">
          <span className="brand-mark">FIX</span>
          <span className="brand-text">Appliance CRM</span>
        </div>
        <nav>
          {[
            ["dashboard", "Dashboard"],
            ["customers", "Customers"],
            ["jobs", "Repair Jobs"],
          ].map(([key, label]) => (
            <button
              key={key}
              className={view === key ? "nav-item active" : "nav-item"}
              onClick={() => setView(key)}
            >
              {label}
            </button>
          ))}
        </nav>
        <div className="sidebar-footer">Signed in as FIX</div>
      </aside>

      <main className="content">
        {view === "dashboard" && <Dashboard />}
        {view === "customers" && <Customers notify={notify} />}
        {view === "jobs" && <Jobs notify={notify} />}
      </main>

      {toast && <div className={`toast ${toast.kind}`}>{toast.message}</div>}
    </div>
  );
}

function Dashboard() {
  const [stats, setStats] = useState(null);
  const [error, setError] = useState(null);

  useEffect(() => {
    api.stats().then(setStats).catch((e) => setError(e.message));
  }, []);

  if (error) return <Panel title="Dashboard"><p className="error">{error}</p></Panel>;
  if (!stats) return <Panel title="Dashboard"><p>Loading…</p></Panel>;

  return (
    <div>
      <header className="page-header">
        <h1>Dashboard</h1>
        <p className="subtitle">Overview of your repair business</p>
      </header>
      <div className="stat-grid">
        <StatCard label="Customers" value={stats.customers} accent="blue" />
        <StatCard label="Appliances tracked" value={stats.appliances} accent="teal" />
        <StatCard label="Open jobs" value={stats.openJobs} accent="amber" />
        <StatCard label="Completed revenue" value={money(stats.revenue)} accent="green" />
      </div>

      <Panel title="Jobs by status">
        <div className="status-bars">
          {Object.keys(STATUS_LABELS).map((s) => {
            const found = stats.byStatus.find((x) => x.status === s);
            const n = found ? found.n : 0;
            const total = stats.byStatus.reduce((acc, x) => acc + x.n, 0) || 1;
            return (
              <div key={s} className="status-bar-row">
                <span className="status-bar-label">{STATUS_LABELS[s]}</span>
                <div className="status-bar-track">
                  <div className={`status-bar-fill status-${s}`} style={{ width: `${(n / total) * 100}%` }} />
                </div>
                <span className="status-bar-count">{n}</span>
              </div>
            );
          })}
        </div>
      </Panel>
    </div>
  );
}

function StatCard({ label, value, accent }) {
  return (
    <div className={`stat-card accent-${accent}`}>
      <div className="stat-value">{value}</div>
      <div className="stat-label">{label}</div>
    </div>
  );
}

function Customers({ notify }) {
  const [customers, setCustomers] = useState([]);
  const [form, setForm] = useState({ name: "", email: "", phone: "", address: "" });
  const [busy, setBusy] = useState(false);

  const load = useCallback(() => {
    api.listCustomers().then(setCustomers).catch((e) => notify(e.message, "error"));
  }, [notify]);

  useEffect(load, [load]);

  async function submit(e) {
    e.preventDefault();
    if (!form.name.trim()) return notify("Name is required", "error");
    setBusy(true);
    try {
      await api.createCustomer(form);
      setForm({ name: "", email: "", phone: "", address: "" });
      notify("Customer added");
      load();
    } catch (err) {
      notify(err.message, "error");
    } finally {
      setBusy(false);
    }
  }

  async function remove(id) {
    try {
      await api.deleteCustomer(id);
      notify("Customer removed");
      load();
    } catch (err) {
      notify(err.message, "error");
    }
  }

  return (
    <div>
      <header className="page-header">
        <h1>Customers</h1>
        <p className="subtitle">{customers.length} total</p>
      </header>

      <Panel title="Add a customer">
        <form className="form-grid" onSubmit={submit}>
          <input placeholder="Name *" value={form.name} onChange={(e) => setForm({ ...form, name: e.target.value })} />
          <input placeholder="Email" value={form.email} onChange={(e) => setForm({ ...form, email: e.target.value })} />
          <input placeholder="Phone" value={form.phone} onChange={(e) => setForm({ ...form, phone: e.target.value })} />
          <input placeholder="Address" value={form.address} onChange={(e) => setForm({ ...form, address: e.target.value })} />
          <button className="btn primary" disabled={busy} type="submit">
            {busy ? "Saving…" : "Add customer"}
          </button>
        </form>
      </Panel>

      <Panel title="All customers">
        <table className="table">
          <thead>
            <tr><th>Name</th><th>Contact</th><th>Appliances</th><th>Jobs</th><th></th></tr>
          </thead>
          <tbody>
            {customers.map((c) => (
              <tr key={c.id}>
                <td>
                  <div className="cell-primary">{c.name}</div>
                  <div className="cell-secondary">{c.address || "—"}</div>
                </td>
                <td>
                  <div>{c.email || "—"}</div>
                  <div className="cell-secondary">{c.phone || "—"}</div>
                </td>
                <td>{c.appliance_count}</td>
                <td>{c.job_count}</td>
                <td><button className="btn danger ghost" onClick={() => remove(c.id)}>Delete</button></td>
              </tr>
            ))}
            {customers.length === 0 && (
              <tr><td colSpan="5" className="empty">No customers yet.</td></tr>
            )}
          </tbody>
        </table>
      </Panel>
    </div>
  );
}

function Jobs({ notify }) {
  const [jobs, setJobs] = useState([]);
  const [customers, setCustomers] = useState([]);
  const [meta, setMeta] = useState({ statuses: [], priorities: [] });
  const [form, setForm] = useState({ customer_id: "", title: "", priority: "normal", technician: "", cost: "" });
  const [busy, setBusy] = useState(false);

  const load = useCallback(() => {
    Promise.all([api.listJobs(), api.listCustomers(), api.meta()])
      .then(([j, c, m]) => {
        setJobs(j);
        setCustomers(c);
        setMeta(m);
      })
      .catch((e) => notify(e.message, "error"));
  }, [notify]);

  useEffect(load, [load]);

  async function submit(e) {
    e.preventDefault();
    if (!form.customer_id) return notify("Select a customer", "error");
    if (!form.title.trim()) return notify("Title is required", "error");
    setBusy(true);
    try {
      await api.createJob({ ...form, customer_id: Number(form.customer_id), cost: Number(form.cost) || 0 });
      setForm({ customer_id: "", title: "", priority: "normal", technician: "", cost: "" });
      notify("Repair job created");
      load();
    } catch (err) {
      notify(err.message, "error");
    } finally {
      setBusy(false);
    }
  }

  async function changeStatus(job, status) {
    try {
      await api.updateJob(job.id, { status });
      notify(`Job #${job.id} → ${STATUS_LABELS[status]}`);
      load();
    } catch (err) {
      notify(err.message, "error");
    }
  }

  async function remove(id) {
    try {
      await api.deleteJob(id);
      notify("Job deleted");
      load();
    } catch (err) {
      notify(err.message, "error");
    }
  }

  return (
    <div>
      <header className="page-header">
        <h1>Repair Jobs</h1>
        <p className="subtitle">{jobs.length} total</p>
      </header>

      <Panel title="Create a repair job">
        <form className="form-grid" onSubmit={submit}>
          <select value={form.customer_id} onChange={(e) => setForm({ ...form, customer_id: e.target.value })}>
            <option value="">Select customer *</option>
            {customers.map((c) => (
              <option key={c.id} value={c.id}>{c.name}</option>
            ))}
          </select>
          <input placeholder="Title *" value={form.title} onChange={(e) => setForm({ ...form, title: e.target.value })} />
          <select value={form.priority} onChange={(e) => setForm({ ...form, priority: e.target.value })}>
            {meta.priorities.map((p) => (
              <option key={p} value={p}>{p}</option>
            ))}
          </select>
          <input placeholder="Technician" value={form.technician} onChange={(e) => setForm({ ...form, technician: e.target.value })} />
          <input placeholder="Cost" type="number" min="0" step="0.01" value={form.cost} onChange={(e) => setForm({ ...form, cost: e.target.value })} />
          <button className="btn primary" disabled={busy} type="submit">
            {busy ? "Saving…" : "Create job"}
          </button>
        </form>
      </Panel>

      <Panel title="All jobs">
        <table className="table">
          <thead>
            <tr><th>#</th><th>Job</th><th>Customer</th><th>Priority</th><th>Status</th><th>Cost</th><th></th></tr>
          </thead>
          <tbody>
            {jobs.map((j) => (
              <tr key={j.id}>
                <td>{j.id}</td>
                <td>
                  <div className="cell-primary">{j.title}</div>
                  <div className="cell-secondary">
                    {j.appliance_type ? `${j.appliance_brand || ""} ${j.appliance_type}`.trim() : "No appliance"}
                    {j.technician ? ` · ${j.technician}` : ""}
                  </div>
                </td>
                <td>{j.customer_name}</td>
                <td><span className={`pill priority-${j.priority}`}>{j.priority}</span></td>
                <td>
                  <select
                    className={`status-select status-${j.status}`}
                    value={j.status}
                    onChange={(e) => changeStatus(j, e.target.value)}
                  >
                    {meta.statuses.map((s) => (
                      <option key={s} value={s}>{STATUS_LABELS[s]}</option>
                    ))}
                  </select>
                </td>
                <td>{money(j.cost)}</td>
                <td><button className="btn danger ghost" onClick={() => remove(j.id)}>Delete</button></td>
              </tr>
            ))}
            {jobs.length === 0 && (
              <tr><td colSpan="7" className="empty">No jobs yet.</td></tr>
            )}
          </tbody>
        </table>
      </Panel>
    </div>
  );
}

function Panel({ title, children }) {
  return (
    <section className="panel">
      {title && <h2 className="panel-title">{title}</h2>}
      {children}
    </section>
  );
}
