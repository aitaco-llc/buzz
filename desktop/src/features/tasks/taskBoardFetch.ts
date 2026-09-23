import { relayClient } from "@/shared/api/relayClient";
import type { RelayEvent } from "@/shared/api/types";
import {
  KIND_GIT_ISSUE,
  KIND_GIT_STATUS_CLOSED,
  KIND_GIT_STATUS_DRAFT,
  KIND_GIT_STATUS_MERGED,
  KIND_GIT_STATUS_OPEN,
  KIND_REPO_ANNOUNCEMENT,
  KIND_STREAM_MESSAGE,
  KIND_STREAM_MESSAGE_V2,
  KIND_TEXT_NOTE,
} from "@/shared/constants/kinds";
import { projectIssueEventsToIssues } from "@/features/projects/projectIssues.mjs";

import { TASK_LABEL, taskRowsFrom } from "./taskRows.mjs";

/** Where the tracker lives. A coordinate, not a project: a task repo need not
 * be a member of any `kind:30621`. */
export type TaskRepo = { owner: string; id: string };

/**
 * Fetch and shape the task board.
 *
 * The same reads `buzz tasks board` makes, in the same order and for the same
 * reasons: issues labelled `t=task`, the repository's own announcement for its
 * `maintainers`, status and kind-1 notes keyed by issue id, and then the posts
 * of whatever threads the link notes named. Per-thread queries are the cost,
 * so a task nobody has started is free.
 *
 * `kind:44200` is not read. It is owner-scoped, so using it here would make
 * Lloyd's tab and a seat's `buzz tasks board` disagree about the same task —
 * see the visibility rule in section 6 of the plan.
 */
export async function fetchTaskBoard(
  repo: TaskRepo,
): Promise<ReturnType<typeof taskRowsFrom>> {
  const repoAddress = `${KIND_REPO_ANNOUNCEMENT}:${repo.owner.toLowerCase()}:${repo.id}`;

  const [issueEvents, repoEvents] = await Promise.all([
    relayClient.fetchEvents({
      kinds: [KIND_GIT_ISSUE],
      "#a": [repoAddress],
      "#t": [TASK_LABEL],
      limit: 500,
    }),
    relayClient.fetchEvents({
      kinds: [KIND_REPO_ANNOUNCEMENT],
      authors: [repo.owner.toLowerCase()],
      "#d": [repo.id],
      limit: 1,
    }),
  ]);
  if (issueEvents.length === 0) return [];

  const ids = issueEvents.map((event) => event.id);
  // The owner vouches for maintainers on the announcement, and NIP-34 trusts
  // them for status and assignment as it trusts the owner (buzz#71, #72).
  const maintainers = (repoEvents[0]?.tags ?? [])
    .filter((tag) => tag[0] === "maintainers")
    .flatMap((tag) => tag.slice(1))
    .filter(Boolean);

  const [statusEvents, noteEvents] = await Promise.all([
    relayClient.fetchEvents({
      kinds: [
        KIND_GIT_STATUS_OPEN,
        KIND_GIT_STATUS_MERGED,
        KIND_GIT_STATUS_CLOSED,
        KIND_GIT_STATUS_DRAFT,
      ],
      "#e": ids,
      limit: 1000,
    }),
    relayClient.fetchEvents({
      kinds: [KIND_TEXT_NOTE],
      "#e": ids,
      limit: 1000,
    }),
  ]);

  // `projectIssueEventsToIssues` applies the NIP-34 trust rule to status and
  // assignment, maintainers included. Nothing here re-decides any of that.
  const issues = projectIssueEventsToIssues(
    issueEvents,
    statusEvents,
    noteEvents,
    maintainers,
  );

  const threads = uniqueLinkedThreads(ids, noteEvents);
  const threadPosts =
    threads.length === 0
      ? []
      : (
          await Promise.all(
            threads.map((thread) =>
              relayClient.fetchEvents({
                kinds: [KIND_STREAM_MESSAGE, KIND_STREAM_MESSAGE_V2],
                "#e": [thread],
                limit: 500,
              }),
            ),
          )
        ).flat();

  return taskRowsFrom({
    issues,
    linkNotes: noteEvents,
    threadPosts,
    now: Math.floor(Date.now() / 1000),
  });
}

/** Every thread any of these issues links, deduped, for the post queries. */
function uniqueLinkedThreads(
  issueIds: string[],
  notes: RelayEvent[],
): string[] {
  const wanted = new Set(issueIds);
  const threads = new Set<string>();
  for (const note of notes) {
    const tags = note.tags ?? [];
    if (!tags.some((tag) => tag[0] === "e" && wanted.has(tag[1]))) continue;
    if (!tags.some((tag) => tag[0] === "t" && tag[1] === "task-thread"))
      continue;
    const target = tags.find(
      (tag) => tag[0] === "e" && tag[3] === "mention",
    )?.[1];
    if (target) threads.add(target);
  }
  return [...threads];
}
