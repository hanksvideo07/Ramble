import {
  App,
  Notice,
  Plugin,
  PluginSettingTab,
  Setting,
  TFile,
  normalizePath,
  requestUrl,
} from 'obsidian';

/**
 * Ramble in Obsidian.
 *
 * One direction only: Ramble is where thoughts are captured, the vault is where
 * they are kept and connected. Writing back would mean two systems both
 * believing they own the same note, and the loser of that argument is always
 * the person's writing.
 *
 * The point of this plugin is not the transcripts — it is the links. Every
 * person, company and project a recording mentioned becomes a [[wiki-link]], so
 * Obsidian builds the backlinks itself and a page for someone you have talked
 * about eight times assembles without anyone maintaining it.
 */

interface RambleSettings {
  serverUrl: string;
  token: string;
  folder: string;
  entityFolder: string;
  includeTranscript: boolean;
  syncOnStartup: boolean;
  /** Recorded-at of the newest ramble written, so a sync only fetches what is new. */
  cursor: string | null;
}

const DEFAULT_SETTINGS: RambleSettings = {
  serverUrl: 'https://ramble-api-production.up.railway.app',
  token: '',
  folder: 'Rambles',
  entityFolder: 'People',
  includeTranscript: true,
  syncOnStartup: false,
  cursor: null,
};

interface RambleCard {
  id: string;
  title: string | null;
  summary: string | null;
  recorded_at: string;
  duration_seconds: number;
  processing_state: string;
}

interface ExtractedItem {
  kind: string;
  title: string;
  body: string | null;
  attributes: Record<string, unknown>;
  source_quote: string | null;
}

interface RambleDetail extends RambleCard {
  clean_transcript: string | null;
  items: ExtractedItem[];
  entities: { id: string; kind: string; name: string }[];
  segments: { start_seconds: number; text: string }[];
}

export default class RamblePlugin extends Plugin {
  settings: RambleSettings = DEFAULT_SETTINGS;

  async onload(): Promise<void> {
    await this.loadSettings();
    this.addSettingTab(new RambleSettingTab(this.app, this));

    this.addCommand({
      id: 'sync',
      name: 'Sync recordings',
      callback: () => void this.sync(),
    });

    this.addCommand({
      id: 'resync-all',
      name: 'Sync everything again from the beginning',
      callback: () => void this.sync({ fromStart: true }),
    });

    this.addRibbonIcon('mic', 'Sync Ramble', () => void this.sync());

    if (this.settings.syncOnStartup && this.settings.token) {
      // Deliberately after layout is ready: a sync during startup competes
      // with the vault opening and makes Obsidian feel slow.
      this.app.workspace.onLayoutReady(() => void this.sync({ quiet: true }));
    }
  }

  async loadSettings(): Promise<void> {
    this.settings = { ...DEFAULT_SETTINGS, ...(await this.loadData()) };
  }

  async saveSettings(): Promise<void> {
    await this.saveData(this.settings);
  }

  // MARK: - Syncing

  async sync(options: { fromStart?: boolean; quiet?: boolean } = {}): Promise<void> {
    if (!this.settings.token) {
      new Notice('Ramble: add your access token in settings first.');
      return;
    }

    const notice = options.quiet ? null : new Notice('Ramble: syncing…', 0);
    try {
      const cursor = options.fromStart ? null : this.settings.cursor;
      const cards = await this.fetchRambles(cursor);

      // Only finished ones. A recording still being understood would be
      // written as an empty note and then need rewriting a minute later.
      const ready = cards.filter((c) => c.processing_state === 'processed');

      let written = 0;
      let newest = cursor;
      for (const card of ready) {
        const detail = await this.fetchDetail(card.id);
        await this.writeNote(detail);
        written += 1;
        if (!newest || detail.recorded_at > newest) newest = detail.recorded_at;
      }

      this.settings.cursor = newest;
      await this.saveSettings();

      notice?.hide();
      if (!options.quiet) {
        new Notice(
          written === 0
            ? 'Ramble: nothing new.'
            : `Ramble: wrote ${written} recording${written === 1 ? '' : 's'}.`,
        );
      }
    } catch (error) {
      notice?.hide();
      const message = error instanceof Error ? error.message : String(error);
      new Notice(`Ramble: ${message}`, 8000);
    }
  }

  private async api<T>(path: string): Promise<T> {
    const response = await requestUrl({
      url: `${this.settings.serverUrl.replace(/\/$/, '')}${path}`,
      headers: { Authorization: `Bearer ${this.settings.token}` },
      throw: false,
    });
    if (response.status === 401) {
      throw new Error('That access token was rejected. Sign in again and paste a new one.');
    }
    if (response.status < 200 || response.status >= 300) {
      throw new Error(`The server returned ${response.status}.`);
    }
    return response.json as T;
  }

  private async fetchRambles(since: string | null): Promise<RambleCard[]> {
    // The API pages backwards from newest, so this walks back until it reaches
    // something already written rather than asking for everything each time.
    const collected: RambleCard[] = [];
    let before: string | null = null;

    for (let page = 0; page < 20; page += 1) {
      // Annotated because `before` is assigned from the result below, which
      // makes the inference circular.
      const query: string = before ? `?limit=50&before=${encodeURIComponent(before)}` : '?limit=50';
      const result: { rambles: RambleCard[]; next_cursor: string | null } = await this.api(
        `/v1/rambles${query}`,
      );
      if (result.rambles.length === 0) break;

      for (const card of result.rambles) {
        if (since && card.recorded_at <= since) return collected;
        collected.push(card);
      }
      if (!result.next_cursor) break;
      before = result.next_cursor;
    }
    return collected;
  }

  private fetchDetail(id: string): Promise<RambleDetail> {
    return this.api<RambleDetail>(`/v1/rambles/${id}`);
  }

  // MARK: - Writing

  private async writeNote(detail: RambleDetail): Promise<void> {
    await this.ensureFolder(this.settings.folder);
    const path = normalizePath(`${this.settings.folder}/${this.fileName(detail)}`);
    const body = this.render(detail);

    const existing = this.app.vault.getAbstractFileByPath(path);
    if (existing instanceof TFile) {
      // Ramble owns these files, and says so in the frontmatter. Rewriting is
      // how a reprocessed recording or a corrected title reaches the vault.
      await this.app.vault.modify(existing, body);
    } else {
      await this.app.vault.create(path, body);
    }

    if (this.settings.entityFolder) {
      await this.ensureEntityNotes(detail);
    }
  }

  /**
   * Creates a stub note for each person or project, but only when one does not
   * already exist.
   *
   * A wiki-link works without a file behind it, so these are not required —
   * they exist so the vault's graph shows the person before you have written
   * anything about them. Never overwritten: the moment someone adds their own
   * notes to a person's page, that page is theirs.
   */
  private async ensureEntityNotes(detail: RambleDetail): Promise<void> {
    if (detail.entities.length === 0) return;
    await this.ensureFolder(this.settings.entityFolder);

    for (const entity of detail.entities) {
      const path = normalizePath(`${this.settings.entityFolder}/${sanitize(entity.name)}.md`);
      if (this.app.vault.getAbstractFileByPath(path)) continue;
      await this.app.vault.create(
        path,
        [
          '---',
          'ramble-entity-id: ' + entity.id,
          'kind: ' + entity.kind,
          '---',
          '',
          `# ${entity.name}`,
          '',
          '*Created by Ramble because you mentioned them. It is yours now — Ramble will not touch this file again.*',
          '',
        ].join('\n'),
      );
    }
  }

  private async ensureFolder(folder: string): Promise<void> {
    const path = normalizePath(folder);
    if (!this.app.vault.getAbstractFileByPath(path)) {
      await this.app.vault.createFolder(path).catch(() => undefined);
    }
  }

  private fileName(detail: RambleDetail): string {
    const date = new Date(detail.recorded_at);
    const stamp = [
      date.getFullYear(),
      String(date.getMonth() + 1).padStart(2, '0'),
      String(date.getDate()).padStart(2, '0'),
    ].join('-');
    const time = [
      String(date.getHours()).padStart(2, '0'),
      String(date.getMinutes()).padStart(2, '0'),
    ].join('');
    const title = sanitize(detail.title || 'Untitled');
    return `${stamp} ${time} ${title}.md`;
  }

  private render(detail: RambleDetail): string {
    const lines: string[] = [];
    const entityLinks = detail.entities.map((e) => `"[[${sanitize(e.name)}]]"`);

    lines.push('---');
    lines.push(`ramble-id: ${detail.id}`);
    lines.push(`recorded: ${detail.recorded_at}`);
    lines.push(`duration: ${Math.round(detail.duration_seconds)}`);
    if (entityLinks.length > 0) lines.push(`people: [${entityLinks.join(', ')}]`);
    // States plainly that this file is generated, so nobody is surprised when
    // their edits to it are replaced on the next sync.
    lines.push('source: ramble');
    lines.push('---');
    lines.push('');
    lines.push(`# ${detail.title || 'Untitled'}`);
    lines.push('');

    if (detail.summary) {
      lines.push(detail.summary);
      lines.push('');
    }

    const grouped = groupByKind(detail.items);
    for (const [kind, items] of grouped) {
      lines.push(`## ${plural(kind)}`);
      lines.push('');
      for (const item of items) {
        const due = typeof item.attributes?.due_at === 'string' ? item.attributes.due_at : null;
        // Tasks and reminders become real checkboxes, so Obsidian's own task
        // queries pick them up alongside everything else in the vault.
        const bullet = kind === 'task' || kind === 'reminder' ? '- [ ]' : '-';
        lines.push(`${bullet} ${item.title}${due ? ` 📅 ${due.slice(0, 10)}` : ''}`);
        if (item.body) lines.push(`  ${item.body}`);
      }
      lines.push('');
    }

    if (detail.entities.length > 0) {
      lines.push('## Mentioned');
      lines.push('');
      lines.push(detail.entities.map((e) => `[[${sanitize(e.name)}]]`).join(' · '));
      lines.push('');
    }

    if (this.settings.includeTranscript) {
      const transcript =
        detail.segments?.length > 0
          ? detail.segments.map((s) => s.text).join(' ')
          : detail.clean_transcript;
      if (transcript) {
        lines.push('## Transcript');
        lines.push('');
        lines.push(transcript);
        lines.push('');
      }
    }

    return lines.join('\n');
  }
}

// MARK: - Helpers

/** Obsidian filenames cannot contain these, and a link to one silently breaks. */
function sanitize(name: string): string {
  return name.replace(/[\\/:*?"<>|#^[\]]/g, '').trim() || 'Untitled';
}

function plural(kind: string): string {
  switch (kind) {
    case 'task': return 'Tasks';
    case 'reminder': return 'Reminders';
    case 'idea': return 'Ideas';
    case 'decision': return 'Decisions';
    case 'question': return 'Questions';
    case 'commitment': return 'Commitments';
    case 'follow_up': return 'Follow-ups';
    case 'note': return 'Notes';
    case 'journal': return 'Journal';
    case 'reference': return 'References';
    default: return kind;
  }
}

/** What you owe before what you thought, matching the app's own ordering. */
const KIND_ORDER = [
  'task', 'reminder', 'commitment', 'follow_up',
  'decision', 'idea', 'question', 'note', 'journal', 'reference',
];

function groupByKind(items: ExtractedItem[]): [string, ExtractedItem[]][] {
  const groups = new Map<string, ExtractedItem[]>();
  for (const item of items) {
    if (item.kind === 'summary') continue;
    const existing = groups.get(item.kind);
    if (existing) existing.push(item);
    else groups.set(item.kind, [item]);
  }
  return [...groups.entries()].sort(
    (a, b) => KIND_ORDER.indexOf(a[0]) - KIND_ORDER.indexOf(b[0]),
  );
}

// MARK: - Settings

class RambleSettingTab extends PluginSettingTab {
  constructor(app: App, private readonly plugin: RamblePlugin) {
    super(app, plugin);
  }

  display(): void {
    const { containerEl } = this;
    containerEl.empty();

    new Setting(containerEl)
      .setName('Server')
      .setDesc('Where your Ramble backend lives.')
      .addText((text) =>
        text
          .setPlaceholder('https://…')
          .setValue(this.plugin.settings.serverUrl)
          .onChange(async (value) => {
            this.plugin.settings.serverUrl = value.trim();
            await this.plugin.saveSettings();
          }),
      );

    new Setting(containerEl)
      .setName('Access token')
      .setDesc('From the Ramble app, under Settings › Let other software in.')
      .addText((text) => {
        text.inputEl.type = 'password';
        text
          .setPlaceholder('Paste your token')
          .setValue(this.plugin.settings.token)
          .onChange(async (value) => {
            this.plugin.settings.token = value.trim();
            await this.plugin.saveSettings();
          });
      });

    new Setting(containerEl)
      .setName('Recordings folder')
      .setDesc('Ramble owns the notes in here and will rewrite them. Keep your own writing elsewhere.')
      .addText((text) =>
        text.setValue(this.plugin.settings.folder).onChange(async (value) => {
          this.plugin.settings.folder = value.trim() || 'Rambles';
          await this.plugin.saveSettings();
        }),
      );

    new Setting(containerEl)
      .setName('People folder')
      .setDesc('A stub note per person or project, created once and never touched again. Leave empty to skip.')
      .addText((text) =>
        text.setValue(this.plugin.settings.entityFolder).onChange(async (value) => {
          this.plugin.settings.entityFolder = value.trim();
          await this.plugin.saveSettings();
        }),
      );

    new Setting(containerEl)
      .setName('Include the transcript')
      .setDesc('The full text of what you said, under the extracted items.')
      .addToggle((toggle) =>
        toggle.setValue(this.plugin.settings.includeTranscript).onChange(async (value) => {
          this.plugin.settings.includeTranscript = value;
          await this.plugin.saveSettings();
        }),
      );

    new Setting(containerEl)
      .setName('Sync when Obsidian opens')
      .addToggle((toggle) =>
        toggle.setValue(this.plugin.settings.syncOnStartup).onChange(async (value) => {
          this.plugin.settings.syncOnStartup = value;
          await this.plugin.saveSettings();
        }),
      );

    new Setting(containerEl)
      .setName('Sync now')
      .addButton((button) =>
        button.setButtonText('Sync').setCta().onClick(() => void this.plugin.sync()),
      );
  }
}
