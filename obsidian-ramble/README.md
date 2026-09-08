# Ramble for Obsidian

Brings your Ramble recordings into your vault as notes.

The point isn't the transcripts — it's the links. Every person, company, and
project a recording mentioned becomes a `[[wiki-link]]`, so Obsidian builds the
backlinks itself. A page for someone you've talked about eight times assembles
without you maintaining it.

## Installing

Until this is in the community plugin list, install it by hand:

```
npm install && npm run build
```

Then copy `manifest.json` and `main.js` into
`<your vault>/.obsidian/plugins/ramble/` and enable it in
Settings → Community plugins.

## Setting it up

Paste your access token, from the Ramble app under
**Settings → Let other software in**.

## What it writes

One note per recording, in the folder you choose:

```markdown
---
ramble-id: 8f3c…
recorded: 2026-09-07T18:12:04Z
duration: 94
people: ["[[Maya Chen]]", "[[Northstar]]"]
source: ramble
---

# A simpler plan for Atlas

One price, a clearer trial, and a note for Maya.

## Tasks
- [ ] Sketch the new pricing page 📅 2026-09-08

## Decisions
- Launch with one plan at $29/month

## Mentioned
[[Maya Chen]] · [[Northstar]]
```

Tasks and reminders are written as real checkboxes, so Obsidian's own task
queries pick them up alongside everything else in your vault.

## Two things worth knowing

**It only goes one way.** Ramble is where thoughts are captured; the vault is
where they're kept and connected. Writing back would mean two systems both
believing they own the same note, and the loser of that argument is always your
writing.

**Ramble owns the recordings folder.** Notes in there are rewritten when a
recording is reprocessed or you correct its title. Keep your own writing
somewhere else.

Person notes are the exception: created once, so the graph shows someone before
you've written about them, and never touched again. The moment you add anything
to a person's page, it's yours.
