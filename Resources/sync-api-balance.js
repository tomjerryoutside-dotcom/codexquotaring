// Invoked only by the user's “同步 API 余额” action. No API keys or cookies are read.
const context = __QUOTARING_CONTEXT__;
const emit = (kind, data) => console.log(`QUOTARING_API_${kind} ${JSON.stringify(data)}`);
let task;
try {
  task = context.spaceId
    ? (context.handoff ? await takeOverTaskSpace(context.spaceId) : await taskSpace(context.spaceId))
    : await taskSpace(`额度环 API 余额 ${Date.now()}`);
  emit('TASK', { spaceId: task.spaceId, handoff: false });
  const page = task.page('p1');
  await page.goto('https://platform.openai.com/settings/organization/billing/overview', { timeout: 30000 });
  await page.waitForFunction(() => {
    const text = document.body?.innerText ?? '';
    return /^API credit balance[ \t]*\n[ \t]*-?(?:US\$|\$)(?:\d{1,3}(?:,\d{3})+|\d+)(?:\.\d+)?[ \t]*(?:\n|$)/m.test(text)
      || (location.hostname === 'auth.openai.com' && !!document.querySelector('input[type=email],input[type=password]'));
  }, undefined, { timeout: 20000 });
  const balance = await page.evaluate(() => {
    if (location.hostname !== 'platform.openai.com' || !location.pathname.startsWith('/settings/organization/billing')) return null;
    const matches = [...document.body.innerText.matchAll(/^API credit balance[ \t]*\n[ \t]*(-?)(?:US\$|\$)((?:\d{1,3}(?:,\d{3})+|\d+)(?:\.\d+)?)[ \t]*(?:\n|$)/gm)];
    if (matches.length !== 1) return null;
    return { amount: matches[0][1]+matches[0][2].replaceAll(',', ''), currency: 'USD', verifiedAt: Date.now()/1000 };
  });
  if (!balance) {
    await task.handOff();
    emit('TASK', { spaceId: task.spaceId, handoff: true });
    emit('RESULT', { status: 'needs_login' });
  } else {
    await task.finish({ keep: [] });
    emit('RESULT', { status: 'ok', ...balance });
  }
} catch (error) {
  // Leave an existing space available for the next explicit manual retry.
  // Never create another space to route around an error or a user-control stop.
  if (task) {
    let handoff = false;
    try { await task.handOff(); handoff = true; } catch (_) { /* Control may already belong to the user. */ }
    emit('TASK', { spaceId: task.spaceId, handoff });
  }
  emit('RESULT', { status: 'failed' });
}
