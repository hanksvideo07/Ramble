import assert from 'node:assert/strict';
import { describe, it } from 'node:test';
import { isNameSubset, normalizeName } from '../src/pipeline/entities.ts';

describe('entity name normalization', () => {
  it('folds case, punctuation, and spacing', () => {
    assert.equal(normalizeName('  Sarah   Chen! '), 'sarah chen');
    assert.equal(normalizeName('SARAH CHEN'), 'sarah chen');
  });

  it('drops corporate suffixes so one company is one entity', () => {
    assert.equal(normalizeName('Nationwide Inc.'), 'nationwide');
    assert.equal(normalizeName('Nationwide, LLC'), 'nationwide');
    assert.equal(normalizeName('Nationwide'), 'nationwide');
  });

  it('drops honorifics', () => {
    assert.equal(normalizeName('Dr. Sarah Chen'), 'sarah chen');
  });
});

describe('name subset matching', () => {
  it('recognizes a first name as part of a full name', () => {
    assert.equal(isNameSubset('sarah', 'sarah chen'), true);
  });

  it('does not match a surname against a full name', () => {
    // "Chen" is not a leading subset, so it will not silently merge.
    assert.equal(isNameSubset('chen', 'sarah chen'), false);
  });

  it('does not match unrelated people who share nothing', () => {
    assert.equal(isNameSubset('ben', 'sarah chen'), false);
  });

  it('does not treat an identical name as a subset', () => {
    assert.equal(isNameSubset('sarah chen', 'sarah chen'), false);
  });
});
