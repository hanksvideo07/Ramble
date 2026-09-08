import type { FastifyInstance } from 'fastify';

/**
 * The privacy policy and terms, served from the API so they have a stable
 * public URL for App Store review and for the in-app links.
 *
 * Written against what the code actually does, not what would be convenient to
 * claim. Three details are the publisher's to fill in and are marked as such;
 * everything else is a statement of fact about this implementation, and if the
 * implementation changes these have to change with it.
 */

/** The publisher's own details. Fill these before submitting anywhere. */
const PUBLISHER = '[PUBLISHER — your name or company]';
const CONTACT = '[CONTACT EMAIL]';
const JURISDICTION = '[JURISDICTION — e.g. the State of New York, United States]';

const LAST_UPDATED = '8 September 2026';

function page(title: string, body: string): string {
  return `<!doctype html>
<html lang="en"><head>
<meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>${title} · Ramble</title>
<style>
  :root {
    --paper:#FCFDF8; --ink:#2D4436; --muted:#6F806E; --rule:#DDE6D5; --accent:#477B53;
    color-scheme: light;
  }
  @media (prefers-color-scheme: dark) {
    :root { --paper:#1D2C22; --ink:#E5EFDC; --muted:#ACBDA3; --rule:#3B503B; --accent:#B8DCA4;
            color-scheme: dark; }
  }
  * { box-sizing: border-box; }
  body {
    margin:0; padding:56px 24px 96px; background:var(--paper); color:var(--ink);
    font:17px/1.75 ui-serif, Georgia, "Times New Roman", serif;
    -webkit-font-smoothing: antialiased;
  }
  main { max-width: 68ch; margin: 0 auto; }
  .brand {
    font-family: ui-sans-serif, system-ui, sans-serif; font-size:13px; font-weight:600;
    letter-spacing:.02em; color:var(--muted); text-transform:lowercase; margin:0 0 28px;
  }
  h1 { font-size:clamp(28px,5vw,38px); line-height:1.15; letter-spacing:-.02em; margin:0 0 8px; }
  .updated {
    font-family: ui-sans-serif, system-ui, sans-serif; font-size:13px; color:var(--muted);
    margin:0 0 40px; padding-bottom:24px; border-bottom:1px solid var(--rule);
  }
  h2 {
    font-size:21px; letter-spacing:-.01em; margin:44px 0 12px; padding-top:24px;
    border-top:1px solid var(--rule);
  }
  h2:first-of-type { border-top:0; padding-top:0; }
  h3 { font-size:17px; margin:26px 0 6px; }
  p, li { margin:0 0 14px; }
  ul { padding-left:22px; }
  strong { font-weight:600; }
  .fill {
    font-family: ui-monospace, monospace; font-size:.85em; background:color-mix(in srgb, var(--accent) 12%, transparent);
    border:1px solid color-mix(in srgb, var(--accent) 35%, transparent); border-radius:4px; padding:1px 5px;
  }
  .note {
    font-family: ui-sans-serif, system-ui, sans-serif; font-size:14px; line-height:1.6;
    color:var(--muted); background:color-mix(in srgb, var(--accent) 7%, transparent);
    border-left:2px solid var(--accent); padding:14px 16px; margin:0 0 32px;
  }
  a { color:var(--accent); text-underline-offset:3px; }
  footer {
    margin-top:56px; padding-top:24px; border-top:1px solid var(--rule);
    font-family: ui-sans-serif, system-ui, sans-serif; font-size:14px; color:var(--muted);
  }
</style></head><body><main>
<p class="brand">ramble</p>
${body}
<footer>Ramble · <a href="/privacy">Privacy</a> · <a href="/terms">Terms</a></footer>
</main></body></html>`;
}

const PRIVACY = page(
  'Privacy Policy',
  `<h1>Privacy Policy</h1>
<p class="updated">Last updated ${LAST_UPDATED}</p>

<div class="note">Ramble records what you say and sends the text of it to an AI provider to be organised.
That is the whole product, and this page exists to say exactly what that means in practice
— what leaves your phone, what does not, who else sees it, and how to get rid of it.</div>

<h2>Who is responsible</h2>
<p>Ramble is operated by <span class="fill">${PUBLISHER}</span>. For anything on this page,
including a request to see or delete your data, write to <span class="fill">${CONTACT}</span>.</p>

<h2>What Ramble holds</h2>
<h3>Things you give it</h3>
<ul>
  <li><strong>Your email address and password.</strong> The password is stored only as a
      salted hash; it cannot be read back, by us or by anyone else.</li>
  <li><strong>Your recordings.</strong> The audio file itself, kept so you can play back
      what you actually said.</li>
  <li><strong>The text of your recordings.</strong> Transcripts, and the tasks, ideas,
      decisions, questions, reminders and commitments found in them.</li>
  <li><strong>The people, companies, and projects you mention</strong>, and how they relate
      to one another — assembled entirely from your own recordings.</li>
  <li><strong>A work-type preference</strong> you choose during setup, which changes what
      Ramble pays attention to.</li>
</ul>

<h3>Things it records about use</h3>
<p>Counts, durations, and outcomes: that a recording was created, how long it was, whether
processing succeeded, how long a search took. These carry no transcript text, no titles,
and no names. They exist to tell whether the service is working.</p>

<h3>Things it deliberately does not hold</h3>
<ul>
  <li><strong>Your calendar and your reminders.</strong> Ramble creates events and reminders
      through Apple's own on-device framework. It does not read your calendar, and nothing
      about it is ever sent to Ramble's servers.</li>
  <li><strong>Your contacts, your location, and your photos.</strong> Never requested.</li>
  <li><strong>Advertising identifiers.</strong> There is no advertising and no tracking
      across other apps or sites.</li>
</ul>

<h2>What happens on your phone rather than a server</h2>
<p>Where your device is capable of it, work is done on the device and the result — not the
audio — is what travels:</p>
<ul>
  <li><strong>Speech to text.</strong> Recent iPhones transcribe on the device. When that
      happens, the text is uploaded and the audio is still uploaded for playback, but no
      third party transcribes it.</li>
  <li><strong>Search vectors.</strong> The numeric representation used for meaning-based
      search is computed on the device where the hardware supports it.</li>
  <li><strong>Calendar and reminders.</strong> Always on the device, without exception.</li>
</ul>

<h2>Who else sees your words</h2>
<p>Ramble uses a small number of processors to do work it cannot do alone. Each receives
only what that job needs.</p>

<h3>Transcription — Deepgram</h3>
<p>Used when your device cannot transcribe a recording itself, or when you choose the
higher-accuracy setting. The <strong>audio</strong> is sent. Not used when your device
handles it.</p>

<h3>Understanding and answering — OpenRouter</h3>
<p>The <strong>text</strong> of your recording is sent to a language model through OpenRouter
so it can be structured, and to answer questions you ask about your own recordings. Ramble
sends these requests with data collection explicitly denied, and restricts them to providers
that accept that condition. It also excludes a list of providers by jurisdiction. Audio is
never sent here.</p>

<h3>Meaning-based search — OpenAI, via OpenRouter</h3>
<p>Where your device cannot compute search vectors itself, short passages of your text are
sent to an embedding model to be converted into numbers. Sent under the same
no-data-collection condition.</p>

<h3>Hosting — Railway</h3>
<p>The database and the audio files are stored on infrastructure operated by Railway, in the
Amsterdam region. Railway can technically access the disks it operates, as any hosting
provider can.</p>

<h2>Training</h2>
<p>Nothing you record is used to train any model — not ours, and not our providers'.
Requests are sent with data collection denied, and Ramble routes around providers that
will not accept that.</p>

<h2>How long it is kept</h2>
<p>Until you delete it. There is no automatic expiry, because the point of the product is
that you can find something you said a year ago.</p>
<ul>
  <li><strong>Deleting a recording</strong> removes its audio file, its transcript, and
      everything extracted from it.</li>
  <li><strong>Deleting your account</strong> removes every recording, every audio file,
      every transcript, everything extracted, and the account itself. It is immediate and
      cannot be undone.</li>
  <li>Backups and logs may retain fragments for a short period after deletion before they
      age out.</li>
</ul>

<h2>What you can do</h2>
<ul>
  <li><strong>Take it with you.</strong> A full machine-readable export of everything held
      about you is available from within the app and at <code>GET /v1/me/export</code>.</li>
  <li><strong>Correct it.</strong> Anything the model got wrong can be edited, and the
      correction is kept.</li>
  <li><strong>Delete any of it, or all of it</strong>, at any time.</li>
</ul>
<p>Depending on where you live you may also have rights to access, correct, port, restrict,
or object to this processing, and to complain to a data protection authority. Write to
<span class="fill">${CONTACT}</span> and it will be handled.</p>

<h2>Actions taken for you</h2>
<p>Ramble can create calendar events, reminders, and tasks from things you said. Anything
that would reach another person — an email, a message — always requires you to say yes
first, every single time, and that requirement cannot be turned off.</p>

<h2>Security</h2>
<p>Traffic is encrypted in transit. Passwords are stored as salted hashes. Audio is not
publicly reachable; playback happens through links that are scoped to a single file and
expire. Your session token is held in the iOS Keychain. No system is perfect, and this one
is operated by a small team.</p>

<h2>Children</h2>
<p>Ramble is not directed at children under 13, and accounts are not knowingly created for
them. If you believe a child has an account, write to <span class="fill">${CONTACT}</span>
and it will be removed.</p>

<h2>Changes</h2>
<p>If this policy changes in a way that affects what happens to your data, the app will say
so before the change takes effect. The date at the top always reflects the current version.</p>`,
);

const TERMS = page(
  'Terms of Service',
  `<h1>Terms of Service</h1>
<p class="updated">Last updated ${LAST_UPDATED}</p>

<div class="note">The short version: Ramble is a tool for keeping your own thoughts. It is
provided as-is, it will sometimes misunderstand you, and anything it does on your behalf
outside your own data needs your explicit approval first.</div>

<h2>The agreement</h2>
<p>These terms are between you and <span class="fill">${PUBLISHER}</span> ("we"). Using
Ramble means accepting them. If you do not accept them, do not use it.</p>

<h2>Your account</h2>
<p>You need an account, and you are responsible for keeping its password to yourself. You
must be old enough to enter a contract where you live, and at least 13. One person per
account.</p>

<h2>What is yours</h2>
<p>Your recordings, your transcripts, and everything extracted from them remain <strong>yours</strong>.
We claim no ownership of them. You grant us only the narrow permission needed to run the
service for you: to store your content, to send it to the processors named in the
<a href="/privacy">Privacy Policy</a>, and to show it back to you. That permission ends when
you delete the content or your account.</p>

<h2>What the software will and will not do</h2>
<p>Ramble uses automated language models to interpret what you said. <strong>They are
imperfect and will sometimes be wrong.</strong> A model may mishear a word, mislabel a task
as an idea, extract a deadline that was never said, or miss one that was.</p>
<p>Because of that:</p>
<ul>
  <li>Anything that would reach another person requires your explicit approval each time.</li>
  <li>Anything low-risk and clearly requested may be filed for you automatically, and can
      always be corrected or removed.</li>
  <li><strong>Do not rely on Ramble as the only record of anything that matters.</strong>
      It is a notebook, not a system of record, and not a substitute for professional,
      medical, legal, or financial advice.</li>
</ul>

<h2>Using it reasonably</h2>
<p>Do not use Ramble to record people without the consent their local law requires; to store
or process content that is illegal where you are; to attack, overload, or reverse-engineer
the service; to resell access; or to build a competing service out of it. We may suspend an
account that does these things.</p>

<h2>Connected services</h2>
<p>Where you connect Ramble to another service, that service's own terms apply to what
happens there, and we are not responsible for it. You can disconnect at any time.</p>

<h2>Availability</h2>
<p>There is no uptime guarantee. The service may be interrupted for maintenance, may change,
and may be discontinued. If it is discontinued, you will be given reasonable notice and the
means to export everything first.</p>

<h2>Ending it</h2>
<p>You may delete your account at any time, from inside the app. Doing so removes your
content permanently and immediately. We may close an account that breaks these terms, and
except in cases of serious abuse we will give you a chance to export first.</p>

<h2>No warranty</h2>
<p>Ramble is provided "as is" and "as available", without warranties of any kind, express or
implied, including merchantability, fitness for a particular purpose, accuracy, and
non-infringement. To the extent the law where you live does not allow some of that
exclusion, it does not apply to you.</p>

<h2>Limitation of liability</h2>
<p>To the fullest extent the law allows, we are not liable for indirect, incidental, special,
consequential, or punitive damages, nor for lost profits, lost data, or a missed commitment
arising from your use of Ramble. Our total liability for any claim is limited to the greater
of the amount you paid us in the twelve months before it arose, or fifty US dollars. Nothing
here limits liability that cannot lawfully be limited.</p>

<h2>Changes to these terms</h2>
<p>These terms may change. Material changes will be announced in the app before taking
effect, and continuing to use Ramble after that means accepting them.</p>

<h2>Governing law</h2>
<p>These terms are governed by the laws of <span class="fill">${JURISDICTION}</span>, without
regard to conflict-of-law rules. Consumer protections you enjoy where you live are
unaffected.</p>

<h2>Contact</h2>
<p>Questions about these terms: <span class="fill">${CONTACT}</span>.</p>`,
);

export async function legalRoutes(app: FastifyInstance): Promise<void> {
  const html = (body: string) => (_: unknown, reply: { type: (t: string) => { send: (b: string) => unknown } }) =>
    reply.type('text/html; charset=utf-8').send(body);

  app.get('/privacy', html(PRIVACY));
  app.get('/terms', html(TERMS));

  /**
   * Lets the app link to these without hardcoding the host, and lets it show
   * the review-blocking placeholders as an honest warning rather than
   * presenting an unfinished policy as final.
   */
  app.get('/v1/legal', async () => ({
    privacy_url: `${(await import('../lib/config.ts')).config.publicUrl}/privacy`,
    terms_url: `${(await import('../lib/config.ts')).config.publicUrl}/terms`,
    last_updated: LAST_UPDATED,
    complete: !PUBLISHER.startsWith('[') && !CONTACT.startsWith('[') && !JURISDICTION.startsWith('['),
  }));
}
