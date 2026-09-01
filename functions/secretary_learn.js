/**
 * Секретарь на звонках предлагает уроки из разговора.
 * В скрипт они попадают только после подтверждения мастера.
 */
module.exports = function createSecretaryLearn({
  db,
  COMPANY_ID,
  extractJsonObject,
  generateContentWithModelFallback,
  notifyMaster,
  callsRef,
  FieldValue,
}) {
  const lessonsRef = db
    .collection('companies')
    .doc(COMPANY_ID)
    .collection('secretary_lessons');
  const voiceRef = db
    .collection('companies')
    .doc(COMPANY_ID)
    .collection('settings')
    .doc('ai_voice');

  function asList(value) {
    return Array.isArray(value) ? value : [];
  }

  async function loadVoice() {
    const snap = await voiceRef.get();
    return snap.exists ? snap.data() || {} : {};
  }

  async function proposeFromCall(callSid, callData, options = {}) {
    if (!callSid || !callData) return;
    const force = options.force === true;
    if (
      !force &&
      (callData.learningStatus === 'proposed' ||
        callData.learningStatus === 'skipped' ||
        callData.learningStatus === 'empty')
    ) {
      return;
    }
    const voice = await loadVoice();
    if (voice.learningEnabled === false && !force) {
      await callsRef.doc(callSid).set({ learningStatus: 'skipped' }, { merge: true });
      return;
    }
    const answeredByAi =
      callData.answeredBy === 'ai' || Boolean(callData.aiReception);
    if (!answeredByAi) return;

    const history = asList((callData.aiReception || {}).history);
    const transcription = String(
      callData.transcriptionEn || callData.transcription || callData.transcriptionRu || ''
    ).trim();
    const userTurns = history.filter((item) => item && item.role === 'user').length;
    if (userTurns < 1 && transcription.length < 40) {
      await callsRef.doc(callSid).set({ learningStatus: 'skipped' }, { merge: true });
      return;
    }

    const approved = asList(voice.learnedRules)
      .map((item) => (typeof item === 'string' ? item : item.ruleEn || item.titleRu || ''))
      .filter(Boolean);
    const rejectedSnap = await lessonsRef.where('status', '==', 'rejected').limit(40).get();
    const rejected = rejectedSnap.docs
      .map((doc) => String((doc.data() || {}).titleRu || '').trim())
      .filter(Boolean)
      .slice(0, 20);

    const conversation = history.length
      ? history
          .map((item) => `${item.role === 'assistant' ? 'Secretary' : 'Caller'}: ${item.text || ''}`)
          .join('\n')
      : transcription;
    const extracted =
      (callData.aiReception && callData.aiReception.extracted) || callData.extractedData || {};
    const facts = {
      extracted,
      createdJobId: callData.createdJobId || callData.jobId || null,
      createJob: Boolean(callData.aiReception && callData.aiReception.createJob),
      hungUp: Boolean(callData.aiReception && callData.aiReception.done),
      liveFailed: Boolean(callData.aiReception && callData.aiReception.liveFailed),
      liveError: (callData.aiReception && callData.aiReception.liveError) || '',
      fromNumber: callData.fromNumber || '',
    };

    const prompt = `You write an error report for the OWNER of a Canadian appliance-repair shop about the phone secretary on THIS call.

Write in Russian (except ruleEn). Be concrete. Quote the call. Do not invent streets or times that were not said.

Explain:
1) whatHappenedRu — what actually happened, 4–8 sentences, full enough to understand the call.
2) clungToRu — what the secretary latched onto (CRM home address, a rule, live callback, tenant, early goodbye, silence, guessed time, mixed two addresses, etc.).
3) problemRu — what went wrong vs a good receptionist. Empty only if the call was truly fine.
4) okRu — what it did right.
5) suggestedFixRu — how it should act next time in the same situation.
6) ruleEn — ONE English imperative sentence for the live script. Empty if nothing to change.
7) severity — ok | issue | fail.

Also propose 0–2 extra small habits in lessons (do not repeat approved/rejected). Do NOT change prices, service area, or "no exact ETA".

Already approved:
${approved.length ? approved.join('\n') : '(none)'}

Already rejected:
${rejected.length ? rejected.join('\n') : '(none)'}

Call facts JSON:
${JSON.stringify(facts).slice(0, 4000)}

Conversation:
${conversation.slice(0, 20000)}

Return STRICT JSON:
{
  "report": {
    "titleRu": "",
    "whatHappenedRu": "",
    "clungToRu": "",
    "problemRu": "",
    "okRu": "",
    "suggestedFixRu": "",
    "ruleEn": "",
    "severity": "issue",
    "evidence": ""
  },
  "lessons": [
    {
      "titleRu": "",
      "detailRu": "",
      "ruleEn": "",
      "evidence": ""
    }
  ]
}`;

    let parsed = {};
    try {
      const result = await generateContentWithModelFallback([{ text: prompt }]);
      let text = (result.response.text() || '').trim();
      if (text.startsWith('```json')) text = text.slice(7);
      else if (text.startsWith('```')) text = text.slice(3);
      if (text.endsWith('```')) text = text.slice(0, -3);
      parsed = extractJsonObject(text.trim()) || {};
    } catch (error) {
      console.warn('secretaryLearn propose:', error.message);
      await callsRef.doc(callSid).set(
        { learningStatus: 'error', learningError: error.message },
        { merge: true }
      );
      return;
    }

    const report = parsed.report && typeof parsed.report === 'object' ? parsed.report : {};
    const lessons = asList(parsed.lessons)
      .filter((item) => item && String(item.titleRu || '').trim() && String(item.ruleEn || '').trim())
      .slice(0, 2);
    const severity = String(report.severity || '').toLowerCase();
    const hasReport = Boolean(
      String(report.whatHappenedRu || report.problemRu || report.titleRu || '').trim()
    );
    if (!hasReport && !lessons.length) {
      await callsRef.doc(callSid).set({ learningStatus: 'empty' }, { merge: true });
      return;
    }

    const batch = db.batch();
    const titles = [];
    if (hasReport) {
      const ref = lessonsRef.doc();
      const problem = String(report.problemRu || '').trim();
      const isIssue = severity === 'fail' || severity === 'issue' || Boolean(problem);
      batch.set(ref, {
        kind: 'report',
        titleRu: String(report.titleRu || 'Разбор звонка').trim().slice(0, 160),
        detailRu: String(report.suggestedFixRu || report.detailRu || '').trim().slice(0, 800),
        whatHappenedRu: String(report.whatHappenedRu || '').trim().slice(0, 2500),
        clungToRu: String(report.clungToRu || '').trim().slice(0, 1200),
        problemRu: problem.slice(0, 1200),
        okRu: String(report.okRu || '').trim().slice(0, 800),
        suggestedFixRu: String(report.suggestedFixRu || '').trim().slice(0, 1200),
        ruleEn: String(report.ruleEn || '').trim().slice(0, 500),
        evidence: String(report.evidence || '').trim().slice(0, 500),
        severity: isIssue ? (severity === 'fail' ? 'fail' : 'issue') : 'ok',
        extracted: extracted,
        transcriptExcerpt: conversation.slice(0, 4000),
        callSid,
        fromNumber: callData.fromNumber || '',
        source: 'auto',
        status: isIssue ? 'pending' : 'noted',
        createdAt: FieldValue.serverTimestamp(),
      });
      titles.push(String(report.titleRu || 'Разбор звонка').trim());
    }
    for (const item of lessons) {
      const ref = lessonsRef.doc();
      batch.set(ref, {
        kind: 'lesson',
        titleRu: String(item.titleRu || '').trim().slice(0, 120),
        detailRu: String(item.detailRu || '').trim().slice(0, 600),
        ruleEn: String(item.ruleEn || '').trim().slice(0, 400),
        evidence: String(item.evidence || '').trim().slice(0, 300),
        callSid,
        fromNumber: callData.fromNumber || '',
        source: 'auto',
        status: 'pending',
        createdAt: FieldValue.serverTimestamp(),
      });
      titles.push(String(item.titleRu).trim());
    }
    batch.set(
      callsRef.doc(callSid),
      {
        learningStatus: 'proposed',
        learningCount: titles.length,
        learningSeverity: String(report.severity || ''),
      },
      { merge: true }
    );
    await batch.commit();
    const shouldNotify =
      severity === 'fail' || severity === 'issue' || Boolean(String(report.problemRu || '').trim());
    if (!shouldNotify) return;
    const body = titles.filter(Boolean).join(' · ') || 'Разбор звонка секретаря';
    try {
      await notifyMaster('Разбор звонка секретаря', body, {
        type: 'secretary_lesson',
        callSid,
      });
    } catch (error) {
      console.warn('secretaryLearn notify:', error.message);
    }
  }

  async function weeklyDigest() {
    const pending = await lessonsRef.where('status', '==', 'pending').get();
    if (pending.empty) return;
    const count = pending.size;
    const first = String((pending.docs[0].data() || {}).titleRu || '').trim();
    const body =
      count === 1
        ? first || '1 предложение'
        : `${count} предложений. ${first}`;
    await notifyMaster('Секретарь: разборы, которые ждут вас', body, {
      type: 'secretary_lesson',
      weekly: '1',
    });
  }

  return { proposeFromCall, weeklyDigest };
};
