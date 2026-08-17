import { db, initSchema } from "./db.js";

initSchema();

const count = db.prepare("SELECT COUNT(*) AS n FROM customers").get().n;
if (count > 0 && !process.argv.includes("--force")) {
  console.log(`Database already has ${count} customers; skipping seed. Use --force to reseed.`);
  process.exit(0);
}

if (process.argv.includes("--force")) {
  db.exec("DELETE FROM jobs; DELETE FROM appliances; DELETE FROM customers;");
  db.exec("DELETE FROM sqlite_sequence WHERE name IN ('jobs','appliances','customers');");
}

const insertCustomer = db.prepare(
  "INSERT INTO customers (name, email, phone, address) VALUES (?, ?, ?, ?)"
);
const insertAppliance = db.prepare(
  "INSERT INTO appliances (customer_id, type, brand, model, serial) VALUES (?, ?, ?, ?, ?)"
);
const insertJob = db.prepare(
  "INSERT INTO jobs (customer_id, appliance_id, title, description, status, priority, technician, cost) VALUES (?, ?, ?, ?, ?, ?, ?, ?)"
);

const seed = db.transaction(() => {
  const alice = insertCustomer.run("Alice Nguyen", "alice@example.com", "555-0101", "12 Maple St, Springfield").lastInsertRowid;
  const bob = insertCustomer.run("Bob Martinez", "bob@example.com", "555-0142", "88 Oak Ave, Springfield").lastInsertRowid;
  const carol = insertCustomer.run("Carol Smith", "carol@example.com", "555-0199", "5 Birch Rd, Shelbyville").lastInsertRowid;

  const fridge = insertAppliance.run(alice, "Refrigerator", "Whirlpool", "WRF560SEHZ", "SN-AL-001").lastInsertRowid;
  const washer = insertAppliance.run(bob, "Washing Machine", "LG", "WM4000HWA", "SN-BO-021").lastInsertRowid;
  const oven = insertAppliance.run(carol, "Oven", "GE", "JB645RKSS", "SN-CA-114").lastInsertRowid;

  insertJob.run(alice, fridge, "Fridge not cooling", "Compressor runs but temperature stays warm.", "in_progress", "high", "Dana Lee", 180);
  insertJob.run(bob, washer, "Washer leaking water", "Water pools under machine during spin cycle.", "scheduled", "normal", "Sam Patel", 0);
  insertJob.run(carol, oven, "Oven won't heat", "No heat on bake, broil element glows briefly.", "new", "urgent", null, 0);
  insertJob.run(alice, fridge, "Replace door seal", "Door gasket worn, cold air escaping.", "completed", "low", "Dana Lee", 95);
});

seed();

const jobs = db.prepare("SELECT COUNT(*) AS n FROM jobs").get().n;
console.log(`Seeded database: ${db.prepare("SELECT COUNT(*) AS n FROM customers").get().n} customers, ${jobs} jobs.`);
