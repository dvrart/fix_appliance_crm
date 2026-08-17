async function request(path, options = {}) {
  const res = await fetch(`/api${path}`, {
    headers: { "Content-Type": "application/json" },
    ...options,
  });
  if (!res.ok) {
    let message = `Request failed (${res.status})`;
    try {
      const body = await res.json();
      if (body?.error) message = body.error;
    } catch {
      /* ignore */
    }
    throw new Error(message);
  }
  if (res.status === 204) return null;
  return res.json();
}

export const api = {
  stats: () => request("/stats"),
  meta: () => request("/meta"),
  listCustomers: () => request("/customers"),
  getCustomer: (id) => request(`/customers/${id}`),
  createCustomer: (data) => request("/customers", { method: "POST", body: JSON.stringify(data) }),
  deleteCustomer: (id) => request(`/customers/${id}`, { method: "DELETE" }),
  addAppliance: (customerId, data) =>
    request(`/customers/${customerId}/appliances`, { method: "POST", body: JSON.stringify(data) }),
  listJobs: () => request("/jobs"),
  createJob: (data) => request("/jobs", { method: "POST", body: JSON.stringify(data) }),
  updateJob: (id, data) => request(`/jobs/${id}`, { method: "PATCH", body: JSON.stringify(data) }),
  deleteJob: (id) => request(`/jobs/${id}`, { method: "DELETE" }),
};
