/**
 * Versioned prompts. Bump the version when wording changes so stored
 * extractions stay attributable to the prompt that produced them.
 */

export const UNDERSTANDING_PROMPT_VERSION = 'understanding.v1';

/** Extraction emphasis per onboarding profile. Defaults only — the data model never changes. */
const PROFILE_EMPHASIS: Record<string, string> = {
  student:
    'This user is a student. Pay particular attention to assignments, deadlines, exams, readings, and study ideas.',
  founder:
    'This user is a founder. Pay particular attention to customers, companies, product ideas, follow-ups, commitments, and decisions.',
  executive:
    'This user is an executive. Pay particular attention to delegations, meetings, people, commitments, and decisions.',
  creator:
    'This user is a creator. Pay particular attention to content ideas, hooks, collaborations, and publishing deadlines.',
  developer:
    'This user is a developer. Pay particular attention to bugs, architectural decisions, technical ideas, and follow-up work.',
  other: 'Extract whatever is genuinely present without forcing a professional frame onto it.',
};

export function understandingSystemPrompt(profile: string): string {
  const emphasis = PROFILE_EMPHASIS[profile] ?? PROFILE_EMPHASIS.other;
  return `You extract structure from a person's spoken thoughts.

They spoke without organizing anything. Your job is to find everything genuinely present and record it faithfully.

${emphasis}

RULES

1. One recording usually contains MANY separate things. Never collapse it into a single item. A short recording may contain a task, an idea, and a person all at once.

2. Extract only what was actually said. Never invent a deadline, a name, or a commitment that was not spoken. If a detail is absent, leave the field out rather than guessing.

3. Every item needs a source_quote: the verbatim span of transcript that justifies it. If you cannot quote it, do not extract it.

3b. Choose the kind that matches what the sentence *is*. These are the only
   kinds, and most recordings contain several:

   note        - a fact or observation worth keeping. "They seem interested in the enterprise plan."
   idea        - a suggestion or possibility, not yet decided. "We should emphasize implementation speed."
   task        - something the speaker has to do. "Finish the history paper."
   reminder    - a task with a time attached. "Remind me tomorrow to send the pricing sheet."
   decision    - a choice already made. "We decided to lead with speed rather than price."
   question    - something genuinely unresolved, usually phrased as a question. "Do they have budget approved?"
   commitment  - something promised to another person. "I told her she'd have pricing by Friday."
   follow_up   - something to return to, with no date yet. "Circle back on the security review."
   journal     - a personal reflection about how they felt. "I'm nervous about this quarter."
   reference   - a link, document, or resource mentioned.
   summary     - do not emit this; the summary field covers it.

   "question" is for things the speaker does not know the answer to. A deadline
   someone else set is a commitment or a task, not a question. An opinion is a
   note or an idea, not a question. If you find yourself labelling everything a
   question, you are labelling statements as questions and should re-read them.

4. Distinguish what kind of statement each thing is. This matters more than anything else you do, because it decides whether software acts on the person's behalf:

   information            - an observation or opinion. "I think we should lower the price."
   intention              - something they mean to do. "I need to lower the price."
   explicit_action        - a direct instruction to change something. "Change the price in the document."
   external_communication - something that leaves the building and reaches another person.
                            "Email Sarah and tell her we're lowering the price."

   Never upgrade a musing into an instruction. If they were thinking aloud, it is information. When genuinely torn between two classes, choose the less consequential one.

5. Only emit an action when the person asked for something to happen. A reflection is not an action. Anything reaching another human is external_communication, however casually it was phrased.

6. Confidence is how certain you are that you understood correctly, not how important it seems. Use the full range. Below 0.5 means you are guessing.

7. Use the fullest form of a name available ("Sarah Chen", not "Sarah") and list shorter forms as aliases. If the person is only ever called "Sarah", then "Sarah" is the name.

8. Resolve relative dates against the recording time given in the request. "Tomorrow morning" becomes a concrete ISO 8601 datetime. If a time is vague, give the date and omit the time rather than fabricating one.

9. The title is what this person would call this recording later when scanning a list of them. Specific, 2-6 words, no trailing period, drawn from what they actually said. "Nationwide pricing follow-up", not "Extracted items" — never describe the work you are doing, and never reuse words from these instructions.

9b. Every action needs parameters, and every action's parameters need a title. Phrase it as the thing to be done: for "remind me tomorrow to send Sarah the pricing sheet", the title is "Send Sarah the pricing sheet", not "Remind me to...". An action with no parameters cannot be carried out and is worse than no action at all.

10. clean_transcript removes filler words, stammers, and false starts. It never paraphrases, summarizes, or reorders. If nothing needs removing, return the transcript unchanged.

Return a single JSON object and nothing else.`;
}

export function understandingUserPrompt(input: {
  transcript: string;
  sectionSummaries?: { topic: string; summary: string }[];
  recordedAt: Date;
  timezone: string;
  knownEntities: string[];
}): string {
  const parts: string[] = [];

  parts.push(`Recording time: ${input.recordedAt.toISOString()} (user timezone: ${input.timezone})`);

  if (input.knownEntities.length > 0) {
    parts.push(
      `People, companies, and projects this user has mentioned before. Reuse these exact names when the recording refers to the same thing:\n${input.knownEntities
        .map((name) => `- ${name}`)
        .join('\n')}`,
    );
  }

  if (input.sectionSummaries?.length) {
    parts.push(
      `This recording was long, so it was split into sections. Section summaries for context:\n${input.sectionSummaries
        .map((s, i) => `${i + 1}. ${s.topic}: ${s.summary}`)
        .join('\n')}`,
    );
  }

  parts.push(`TRANSCRIPT\n${input.transcript}`);
  return parts.join('\n\n');
}

export const SECTION_SUMMARY_PROMPT_VERSION = 'section_summary.v1';

export const sectionSummarySystemPrompt = `You summarize one section of a longer spoken recording.

Give a topic label of 2-5 words and a one-or-two-sentence summary of what was actually said in this section. Do not speculate about sections you were not shown. Return JSON only: {"topic": "...", "summary": "..."}`;

export const ANSWER_PROMPT_VERSION = 'answer.v1';

export const answerSystemPrompt = `You answer questions about a person's own recorded thoughts, using only the excerpts provided.

RULES

1. Answer only from the excerpts. If they do not contain the answer, say so plainly and mention what you did find that was close. Never fill a gap from general knowledge.

2. Cite the excerpts you used by their [n] marker, inline, right where the claim appears.

3. Speak to them about their own thinking: "You decided...", "You mentioned...". Not "The user...".

4. Be direct and brief. Two or three sentences usually suffices. Expand only when the question genuinely asks you to synthesize across many recordings.

5. When excerpts conflict, say so and note which is more recent rather than silently picking one.

6. Do not moralize, do not add encouragement, and do not offer unrequested advice.`;
