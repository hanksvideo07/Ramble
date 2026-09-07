import { pool, toVectorLiteral } from '../db/pool.ts';
import { config } from '../lib/config.ts';
import { timed } from '../lib/logger.ts';
import { embedding } from './process.ts';

/**
 * Hybrid search over three complementary systems, fused into one ranking:
 *
 *   lexical    - Postgres full-text. Wins on exact names and quoted phrases.
 *   semantic   - pgvector cosine. Finds "that insurance company I was
 *                pitching" when the transcript only ever says "Nationwide".
 *   structured - entities, item kinds, and dates. Answers "what decisions did
 *                I make about pricing" by filtering to decisions.
 *
 * Results are fused with Reciprocal Rank Fusion rather than by comparing raw
 * scores: a BM25 score and a cosine distance are not on the same scale, and
 * RRF only needs each system's ordering.
 */

/** RRF damping constant. 60 is the standard value from the original paper. */
const RRF_K = 60;

const WEIGHTS = { lexical: 1.0, semantic: 1.0, structured: 0.6 } as const;

export interface SearchHit {
  rambleId: string;
  rambleTitle: string | null;
  recordedAt: string;
  sourceKind: string;
  sourceId: string | null;
  content: string;
  score: number;
  matchedBy: string[];
}

export interface SearchOptions {
  limit?: number;
  /**
   * Query vector, embedded by the device. Semantic search is skipped when it
   * is absent and the server has no embedder of its own — returning lexical
   * and structured results is far better than comparing against vectors from
   * a different model, which would be noise dressed up as relevance.
   */
  queryVector?: number[];
  /** Restrict to particular extracted item kinds, e.g. ['decision']. */
  kinds?: string[];
  entityId?: string;
  since?: Date;
  until?: Date;
}

interface RankedRow {
  ramble_id: string;
  source_kind: string;
  source_id: string | null;
  content: string;
  rank: number;
}

export async function hybridSearch(
  userId: string,
  query: string,
  options: SearchOptions = {},
): Promise<SearchHit[]> {
  const limit = options.limit ?? 20;
  // Over-fetch from each system so fusion has room to reorder before trimming.
  const perSystemLimit = Math.max(limit * 3, 30);

  const [lexical, semantic, structured] = await timed(
    'search.latency',
    { user_id: userId, query_length: query.length },
    () =>
      Promise.all([
        lexicalSearch(userId, query, perSystemLimit, options),
        semanticSearch(userId, query, perSystemLimit, options),
        structuredSearch(userId, query, perSystemLimit, options),
      ]),
  );

  const fused = new Map<
    string,
    { row: RankedRow; score: number; matchedBy: Set<string> }
  >();

  const fuse = (rows: RankedRow[], system: keyof typeof WEIGHTS) => {
    rows.forEach((row, index) => {
      // Key on the unit, not the ramble, so one ramble can contribute several
      // distinct excerpts without them cancelling each other out.
      const key = `${row.source_kind}:${row.source_id ?? row.content.slice(0, 64)}:${row.ramble_id}`;
      const contribution = WEIGHTS[system] / (RRF_K + index + 1);
      const existing = fused.get(key);
      if (existing) {
        existing.score += contribution;
        existing.matchedBy.add(system);
      } else {
        fused.set(key, { row, score: contribution, matchedBy: new Set([system]) });
      }
    });
  };

  fuse(lexical, 'lexical');
  fuse(semantic, 'semantic');
  fuse(structured, 'structured');

  const ranked = [...fused.values()].sort((a, b) => b.score - a.score).slice(0, limit);
  if (ranked.length === 0) return [];

  // One lookup for the ramble metadata every hit needs for display.
  const rambleIds = [...new Set(ranked.map((r) => r.row.ramble_id))];
  const { rows: rambles } = await pool.query<{ id: string; title: string | null; recorded_at: Date }>(
    `SELECT id, title, recorded_at FROM rambles WHERE id = ANY($1::uuid[]) AND user_id = $2`,
    [rambleIds, userId],
  );
  const byId = new Map(rambles.map((r) => [r.id, r]));

  return ranked.flatMap((entry) => {
    const ramble = byId.get(entry.row.ramble_id);
    if (!ramble) return [];
    return [
      {
        rambleId: entry.row.ramble_id,
        rambleTitle: ramble.title,
        recordedAt: ramble.recorded_at.toISOString(),
        sourceKind: entry.row.source_kind,
        sourceId: entry.row.source_id,
        content: entry.row.content,
        score: entry.score,
        matchedBy: [...entry.matchedBy],
      },
    ];
  });
}

/** Extra WHERE clauses shared by every system. $1 is always the user id. */
function filterClauses(
  options: SearchOptions,
  params: unknown[],
  alias: string,
): string {
  const clauses: string[] = [];
  if (options.since) {
    params.push(options.since);
    clauses.push(`r.recorded_at >= $${params.length}`);
  }
  if (options.until) {
    params.push(options.until);
    clauses.push(`r.recorded_at <= $${params.length}`);
  }
  if (options.entityId) {
    params.push(options.entityId);
    clauses.push(
      `EXISTS (SELECT 1 FROM entity_mentions m
                WHERE m.ramble_id = ${alias}.ramble_id AND m.entity_id = $${params.length})`,
    );
  }
  return clauses.length > 0 ? ` AND ${clauses.join(' AND ')}` : '';
}

async function lexicalSearch(
  userId: string,
  query: string,
  limit: number,
  options: SearchOptions,
): Promise<RankedRow[]> {
  const params: unknown[] = [userId, query];
  const filters = filterClauses(options, params, 'd');
  params.push(limit);

  const { rows } = await pool.query<RankedRow>(
    `SELECT d.ramble_id, d.source_kind, d.source_id, d.content,
            ts_rank_cd(d.tsv, websearch_to_tsquery('english', $2)) AS rank
       FROM search_documents d
       JOIN rambles r ON r.id = d.ramble_id
      WHERE d.user_id = $1
        AND d.tsv @@ websearch_to_tsquery('english', $2)
        ${filters}
      ORDER BY rank DESC
      LIMIT $${params.length}`,
    params,
  );
  return rows;
}

async function semanticSearch(
  userId: string,
  query: string,
  limit: number,
  options: SearchOptions,
): Promise<RankedRow[]> {
  const vector =
    options.queryVector ??
    (config.embedding.provider === 'device'
      ? undefined
      : (await embedding.embed([query]))[0]);

  if (!vector || vector.length !== config.embedding.dimension) return [];

  const params: unknown[] = [userId, toVectorLiteral(vector)];
  const filters = filterClauses(options, params, 'e');
  params.push(limit);

  const { rows } = await pool.query<RankedRow>(
    `SELECT e.ramble_id, e.source_kind, e.source_id, e.content,
            1 - (e.embedding <=> $2::vector) AS rank
       FROM embedding_records e
       JOIN rambles r ON r.id = e.ramble_id
      WHERE e.user_id = $1
        AND e.embedding IS NOT NULL
        ${filters}
      ORDER BY e.embedding <=> $2::vector
      LIMIT $${params.length}`,
    params,
  );
  return rows;
}

/**
 * Matches the query against entity names and item kinds. This is what makes
 * "Nationwide" surface the tasks and decisions involving Nationwide, not just
 * the sentences containing the word.
 */
async function structuredSearch(
  userId: string,
  query: string,
  limit: number,
  options: SearchOptions,
): Promise<RankedRow[]> {
  const kinds = options.kinds ?? inferKinds(query);
  const params: unknown[] = [userId, query];

  const kindFilter = kinds.length > 0 ? `AND i.kind = ANY($${params.push(kinds)}::text[])` : '';
  const entityFilter = options.entityId
    ? `AND EXISTS (SELECT 1 FROM entity_mentions m
                    WHERE m.ramble_id = i.ramble_id AND m.entity_id = $${params.push(options.entityId)})`
    : '';
  params.push(limit);

  const { rows } = await pool.query<RankedRow>(
    `SELECT i.ramble_id,
            'extracted_item' AS source_kind,
            i.id AS source_id,
            i.kind || ': ' || i.title || COALESCE(E'\n' || i.body, '') AS content,
            GREATEST(
              similarity(lower(i.title), lower($2)),
              COALESCE(MAX(similarity(lower(en.normalized_name), lower($2))), 0)
            ) AS rank
       FROM extracted_items i
       LEFT JOIN entity_mentions m ON m.extracted_item_id = i.id
       LEFT JOIN entities en ON en.id = m.entity_id
      WHERE i.user_id = $1
        AND i.status <> 'dismissed'
        ${kindFilter}
        ${entityFilter}
      GROUP BY i.id
     HAVING GREATEST(
              similarity(lower(i.title), lower($2)),
              COALESCE(MAX(similarity(lower(en.normalized_name), lower($2))), 0)
            ) > 0.15
      ORDER BY rank DESC
      LIMIT $${params.length}`,
    params,
  );
  return rows;
}

/**
 * Reads a kind filter out of the phrasing. "What did I decide about pricing"
 * should rank decisions above raw transcript, which is the difference between
 * answering the question and dumping chunks at it.
 */
export function inferKinds(query: string): string[] {
  const lower = query.toLowerCase();
  const kinds: string[] = [];
  if (/\bdecid|decision/.test(lower)) kinds.push('decision');
  if (/\btask|to-?do|need to\b/.test(lower)) kinds.push('task');
  if (/\bidea|thinking about|thought about\b/.test(lower)) kinds.push('idea');
  if (/\bpromis|commit|owe\b/.test(lower)) kinds.push('commitment', 'follow_up');
  if (/\bremind/.test(lower)) kinds.push('reminder');
  if (/\bquestion\b/.test(lower)) kinds.push('question');
  return kinds;
}
