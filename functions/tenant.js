/**
 * Fix Cloud tenant helper.
 * Never fall back to the shop company `fix_appliance_ca`.
 * Do not deploy these functions to project `fix-appliance-crm`.
 *
 * Until Twilio/Gmail are routed per company, set DEFAULT_COMPANY_ID
 * only on the CLOUD Firebase project.
 */
const PLACEHOLDER = 'PENDING_CLOUD_TENANT';

function getCompanyId() {
  const id = String(process.env.DEFAULT_COMPANY_ID || '').trim();
  return id || PLACEHOLDER;
}

function functionsBaseUrl() {
  const explicit = String(process.env.FUNCTIONS_BASE_URL || '').trim().replace(/\/$/, '');
  if (explicit) return explicit;
  const project =
    process.env.GCLOUD_PROJECT ||
    process.env.GCP_PROJECT ||
    'fix-appliance-cloud-pending';
  return `https://us-central1-${project}.cloudfunctions.net`;
}

module.exports = {
  PLACEHOLDER,
  getCompanyId,
  functionsBaseUrl,
};
