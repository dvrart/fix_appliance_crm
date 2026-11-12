// Точная математика счетов, запчастей и деления чистой прибыли частного мастера
// (идентична lib/models/technician_payout.dart и functions/technicians.js).

export const OWNER_UID = 'Ew8vDgXvuMMwt9gYQUOi7rujNxO2';

export function num(value, fallback = 0) {
  if (typeof value === 'number' && Number.isFinite(value)) return value;
  const parsed = parseFloat(String(value ?? '').replace(',', '.'));
  return Number.isFinite(parsed) ? parsed : fallback;
}

export function isInvoiceDoc(doc) {
  if (!doc || typeof doc !== 'object') return false;
  if (doc.deletedAt) return false;
  const t = String(doc.type || 'Invoice').trim().toLowerCase();
  return t !== 'estimate';
}

export function isEstimateDoc(doc) {
  if (!doc || typeof doc !== 'object' || doc.deletedAt) return false;
  return String(doc.type || '').trim().toLowerCase() === 'estimate';
}

export function isPartItem(item) {
  if (!item || typeof item !== 'object') return false;
  if (item.labourDiscount === true) return false;
  const t = String(item.type || '').trim().toLowerCase();
  if (t === 'part' || t === 'запчасть') return true;
  if (t === 'service' || t === 'работа') return false;
  if (String(item.warehouseItemId || '').trim()) return true;
  if (item.costPrice !== undefined && item.costPrice !== null && String(item.costPrice).trim() !== '') {
    return true;
  }
  return false;
}

export function partSourceOf(item) {
  const explicit = String(item?.partSource || '').trim().toLowerCase();
  if (explicit === 'tech') return 'tech';
  if (explicit === 'owner') return 'owner';
  if (String(item?.warehouseItemId || '').trim()) return 'owner';
  return 'owner';
}

export function documentSubtotal(doc) {
  const items = Array.isArray(doc?.items) ? doc.items : [];
  let sub = 0;
  for (const item of items) {
    if (!item || typeof item !== 'object') continue;
    const qty = num(item.qty ?? 1, 1);
    const price = num(item.price, 0);
    sub += qty * price;
  }
  return sub;
}

export function documentTax(doc) {
  const sub = documentSubtotal(doc);
  const rate = num(doc?.taxRate, 0);
  if (sub <= 0 || rate <= 0) return 0;
  return Math.round(sub * rate * 100) / 100;
}

export function documentTotal(doc) {
  return documentSubtotal(doc) + documentTax(doc);
}

export function isTipPayment(p) {
  const m = String(p?.method || '').toLowerCase();
  return m.includes('tip') || m.includes('чаевые');
}

export function isRefundPayment(p) {
  const amount = num(p?.amount, 0);
  const m = String(p?.method || '').toLowerCase();
  return amount < -0.009 || m.includes('refund') || m.includes('возврат');
}

export function paymentsOf(doc) {
  const raw = Array.isArray(doc?.payments) ? doc.payments : [];
  let paid = 0;
  let tips = 0;
  for (const p of raw) {
    if (!p || typeof p !== 'object') continue;
    const amount = num(p.amount, 0);
    if (isTipPayment(p) && !isRefundPayment(p)) {
      tips += amount;
    } else {
      paid += amount;
    }
  }
  if (paid === 0 && tips === 0 && doc?.stripe && doc.stripe.status === 'paid') {
    paid = documentTotal(doc);
  }
  return {
    paidExTips: paid < 0 ? 0 : paid,
    tips: tips < 0 ? 0 : tips,
  };
}

export function calcJobPayout(job, profitSharePercent = 50) {
  const clampedTechPct = Math.max(0, Math.min(100, num(profitSharePercent, 50)));
  const techFraction = clampedTechPct / 100;

  let invoicedSubtotal = 0;
  let invoicedTax = 0;
  let invoicedTotal = 0;
  let paidExTips = 0;
  let tips = 0;
  let revenueExTax = 0;
  let ownerPartsCost = 0;
  let techVerifiedPartsCost = 0;
  let techUnverifiedPartsCost = 0;
  const parts = [];

  const docs = Array.isArray(job?.documents) ? job.documents : [];
  for (const doc of docs) {
    if (!isInvoiceDoc(doc)) continue;
    const subtotal = documentSubtotal(doc);
    const tax = documentTax(doc);
    const total = subtotal + tax;
    const pay = paymentsOf(doc);

    invoicedSubtotal += subtotal;
    invoicedTax += tax;
    invoicedTotal += total;
    paidExTips += pay.paidExTips;
    tips += pay.tips;

    let ratio = 0;
    if (pay.paidExTips <= 0.009) {
      ratio = 0;
    } else if (total <= 0.009) {
      ratio = 1;
    } else {
      ratio = Math.max(0, Math.min(1, pay.paidExTips / total));
    }

    revenueExTax += subtotal * ratio;

    const invNumber = String(doc.number || '').trim();
    const items = Array.isArray(doc.items) ? doc.items : [];
    for (const rawItem of items) {
      if (!isPartItem(rawItem)) continue;
      const qty = num(rawItem.qty ?? 1, 1);
      if (qty <= 0) continue;
      const unitPrice = num(rawItem.price, 0);
      const unitCost = num(rawItem.costPrice, 0);
      const source = partSourceOf(rawItem);
      const receiptUrl = String(rawItem.receiptUrl || '').trim();
      const lineCost = qty * unitCost * ratio;

      if (source === 'tech') {
        if (receiptUrl) {
          techVerifiedPartsCost += lineCost;
        } else {
          techUnverifiedPartsCost += lineCost;
        }
      } else {
        ownerPartsCost += lineCost;
      }

      parts.push({
        name: String(rawItem.name || '').trim(),
        qty,
        clientUnitPrice: unitPrice,
        unitCost,
        source,
        receiptUrl,
        invoiceNumber: invNumber,
      });
    }
  }

  const recognizedPartsCost = ownerPartsCost + techVerifiedPartsCost;
  const netProfit = revenueExTax - recognizedPartsCost;
  const techProfit = netProfit * techFraction;
  const ownerProfit = netProfit - techProfit;
  const dueToOwner = ownerPartsCost + ownerProfit;

  return {
    job,
    invoicedSubtotal,
    invoicedTax,
    invoicedTotal,
    paidExTips,
    tips,
    revenueExTax,
    ownerPartsCost,
    techVerifiedPartsCost,
    techUnverifiedPartsCost,
    techSharePercent: clampedTechPct,
    netProfit,
    techProfit,
    ownerProfit,
    dueToOwner,
    unpaidClientBalance: Math.max(0, invoicedTotal - paidExTips),
    hasPaidActivity: paidExTips > 0.009,
    hasUnverifiedTechParts: techUnverifiedPartsCost > 0.009,
    parts,
  };
}

export function calcBalanceSummary(technician, jobs, settlements) {
  const share = num(technician?.profitSharePercent, 50);
  const activeJobs = (jobs || []).filter((j) => j && !j.deletedAt);
  const jobPayouts = activeJobs.map((j) => calcJobPayout(j, share));

  let totalRevenueExTax = 0;
  let totalOwnerPartsCost = 0;
  let totalTechVerifiedPartsCost = 0;
  let totalTechUnverifiedPartsCost = 0;
  let totalNetProfit = 0;
  let totalTechProfit = 0;
  let totalOwnerProfit = 0;
  let totalGrossDueToOwner = 0;

  for (const jp of jobPayouts) {
    totalRevenueExTax += jp.revenueExTax;
    totalOwnerPartsCost += jp.ownerPartsCost;
    totalTechVerifiedPartsCost += jp.techVerifiedPartsCost;
    totalTechUnverifiedPartsCost += jp.techUnverifiedPartsCost;
    totalNetProfit += jp.netProfit;
    totalTechProfit += jp.techProfit;
    totalOwnerProfit += jp.ownerProfit;
    totalGrossDueToOwner += jp.dueToOwner;
  }

  let totalSettled = 0;
  for (const s of settlements || []) {
    totalSettled += num(s?.amount, 0);
  }

  return {
    technician,
    jobs: jobPayouts,
    settlements: settlements || [],
    totalRevenueExTax,
    totalOwnerPartsCost,
    totalTechVerifiedPartsCost,
    totalTechUnverifiedPartsCost,
    totalNetProfit,
    totalTechProfit,
    totalOwnerProfit,
    totalGrossDueToOwner,
    totalSettled,
    balanceDueToOwner: totalGrossDueToOwner - totalSettled,
  };
}
