-- A recording's title and summary are model output, and were permanent: you
-- could correct an extracted item but not the sentence describing the whole
-- recording. This marks the ones a person rewrote, so reprocessing leaves them
-- alone rather than quietly replacing the correction with another guess.
ALTER TABLE rambles
  ADD COLUMN IF NOT EXISTS title_edited_by_user boolean NOT NULL DEFAULT false;
