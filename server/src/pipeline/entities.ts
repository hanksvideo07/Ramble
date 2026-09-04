import type pg from 'pg';
import type { ExtractedEntity } from '../providers/schema.ts';

/**
 * Entity resolution.
 *
 * The goal is that "Sarah", "Sarah Chen", and "sarah chen" become one entity
 * page rather than three, without merging genuinely different people. When a
 * match is uncertain we create a separate entity: a duplicate is a small
 * annoyance the user can merge, whereas a wrong merge silently corrupts
 * someone's memory of two different people.
 */

export function normalizeName(name: string): string {
  return name
    .toLowerCase()
    .normalize('NFKD')
    .replace(/[̀-ͯ]/g, '')
    // Drop honorifics and corporate suffixes so "Nationwide" and
    // "Nationwide Inc." resolve together.
    .replace(/^(mr|mrs|ms|dr|prof)\.?\s+/i, '')
    .replace(/\s+(inc|llc|ltd|corp|co|company|gmbh)\.?$/i, '')
    .replace(/[^a-z0-9\s]/g, '')
    .replace(/\s+/g, ' ')
    .trim();
}

/** True when `short` is a leading-name subset of `full`, e.g. "Sarah" of "Sarah Chen". */
export function isNameSubset(short: string, full: string): boolean {
  const shortParts = short.split(' ').filter(Boolean);
  const fullParts = full.split(' ').filter(Boolean);
  if (shortParts.length === 0 || shortParts.length >= fullParts.length) return false;
  return shortParts.every((part, i) => fullParts[i] === part);
}

export interface ResolvedEntity {
  id: string;
  name: string;
  created: boolean;
}

interface EntityRow {
  id: string;
  name: string;
  normalized_name: string;
  aliases: string[];
}

/**
 * Finds the entity this mention refers to, or creates one.
 *
 * Match order, most to least certain:
 *   1. exact normalized name
 *   2. a recorded alias
 *   3. a unique first-name-style subset among existing entities of the same
 *      kind ("Sarah" -> "Sarah Chen", but only if exactly one candidate)
 */
export async function resolveEntity(
  client: pg.PoolClient,
  userId: string,
  entity: ExtractedEntity,
): Promise<ResolvedEntity> {
  const normalized = normalizeName(entity.name);
  if (!normalized) {
    throw new Error(`Entity name "${entity.name}" normalized to empty.`);
  }

  const { rows: candidates } = await client.query<EntityRow>(
    `SELECT id, name, normalized_name, aliases
       FROM entities
      WHERE user_id = $1 AND kind = $2 AND merged_into_id IS NULL`,
    [userId, entity.kind],
  );

  const exact = candidates.find((row) => row.normalized_name === normalized);
  if (exact) {
    await recordAliases(client, exact.id, entity.aliases);
    await touchEntity(client, exact.id);
    return { id: exact.id, name: exact.name, created: false };
  }

  const byAlias = candidates.find((row) =>
    row.aliases.some((alias) => normalizeName(alias) === normalized),
  );
  if (byAlias) {
    await touchEntity(client, byAlias.id);
    return { id: byAlias.id, name: byAlias.name, created: false };
  }

  // "Sarah" folds into "Sarah Chen" only when she is the single candidate.
  // Two Sarahs means we cannot tell, so a new entity is created instead.
  const supersets = candidates.filter((row) => isNameSubset(normalized, row.normalized_name));
  if (supersets.length === 1) {
    const match = supersets[0]!;
    await recordAliases(client, match.id, [entity.name, ...entity.aliases]);
    await touchEntity(client, match.id);
    return { id: match.id, name: match.name, created: false };
  }

  // The mention may be the fuller form of an entity we already have
  // ("Sarah Chen" arriving after "Sarah"): rename in place and keep the old
  // form as an alias, so history stays attached to one page.
  const subsets = candidates.filter((row) => isNameSubset(row.normalized_name, normalized));
  if (subsets.length === 1) {
    const match = subsets[0]!;
    await client.query(
      `UPDATE entities
          SET name = $2, normalized_name = $3,
              aliases = (SELECT ARRAY(SELECT DISTINCT unnest(aliases || $4::text[]))),
              mention_count = mention_count + 1, last_seen_at = now()
        WHERE id = $1`,
      [match.id, entity.name, normalized, [match.name, ...entity.aliases]],
    );
    return { id: match.id, name: entity.name, created: false };
  }

  const { rows } = await client.query<{ id: string }>(
    `INSERT INTO entities (user_id, kind, name, normalized_name, aliases, mention_count)
     VALUES ($1, $2, $3, $4, $5, 1)
     ON CONFLICT (user_id, kind, normalized_name)
       DO UPDATE SET mention_count = entities.mention_count + 1, last_seen_at = now()
     RETURNING id`,
    [userId, entity.kind, entity.name, normalized, entity.aliases],
  );
  return { id: rows[0]!.id, name: entity.name, created: true };
}

async function recordAliases(client: pg.PoolClient, entityId: string, aliases: string[]): Promise<void> {
  if (aliases.length === 0) return;
  await client.query(
    `UPDATE entities
        SET aliases = (SELECT ARRAY(SELECT DISTINCT unnest(aliases || $2::text[])))
      WHERE id = $1`,
    [entityId, aliases],
  );
}

async function touchEntity(client: pg.PoolClient, entityId: string): Promise<void> {
  await client.query(
    `UPDATE entities SET mention_count = mention_count + 1, last_seen_at = now() WHERE id = $1`,
    [entityId],
  );
}

/**
 * Merges `sourceId` into `targetId` after a user says two entities are the
 * same person. Mentions and relationships repoint; the source row is kept as a
 * tombstone so any stored reference still resolves.
 */
export async function mergeEntities(
  client: pg.PoolClient,
  userId: string,
  sourceId: string,
  targetId: string,
): Promise<void> {
  if (sourceId === targetId) return;

  const { rows } = await client.query<{ id: string; name: string; aliases: string[] }>(
    `SELECT id, name, aliases FROM entities WHERE id = ANY($1::uuid[]) AND user_id = $2`,
    [[sourceId, targetId], userId],
  );
  if (rows.length !== 2) throw new Error('Both entities must belong to this user.');
  const source = rows.find((r) => r.id === sourceId)!;

  await client.query(
    `UPDATE entity_mentions SET entity_id = $2 WHERE entity_id = $1 AND user_id = $3`,
    [sourceId, targetId, userId],
  );
  await client.query(
    `UPDATE relationships SET from_entity_id = $2 WHERE from_entity_id = $1 AND user_id = $3`,
    [sourceId, targetId, userId],
  );
  await client.query(
    `UPDATE relationships SET to_entity_id = $2 WHERE to_entity_id = $1 AND user_id = $3`,
    [sourceId, targetId, userId],
  );
  await client.query(
    `UPDATE entities
        SET aliases = (SELECT ARRAY(SELECT DISTINCT unnest(aliases || $2::text[]))),
            mention_count = mention_count + (SELECT mention_count FROM entities WHERE id = $3)
      WHERE id = $1`,
    [targetId, [source.name, ...source.aliases], sourceId],
  );
  await client.query(`UPDATE entities SET merged_into_id = $2 WHERE id = $1`, [sourceId, targetId]);
}
