import type { ProjectIssue } from "@/features/projects/projectIssues.d.mts";
import type { RelayEvent } from "@/shared/api/types";

export type TaskBoardState =
  | "Unassigned"
  | "Blocked"
  | "In Progress"
  | "Up Next"
  | "Done";

export type TaskRow = {
  id: string;
  subject: string;
  content: string;
  author: string;
  createdAt: number;
  assignee: string | null;
  blockedBy: string | null;
  linkedThreads: string[];
  state: TaskBoardState;
  /** Newest qualifying activity, or null. Section 6's definition. */
  activityAt: number | null;
  commentCount: number;
};

export const TASK_LABEL: "task";
export const TASK_GROUP_ORDER: TaskBoardState[];

export function threadKeyOf(event: RelayEvent): string;
export function linksFor(
  issueId: string,
  notes: RelayEvent[],
): { threads: string[]; blockedBy: string | null };
export function taskRowsFrom(input: {
  issues: ProjectIssue[];
  linkNotes?: RelayEvent[];
  threadPosts?: RelayEvent[];
  now: number;
}): TaskRow[];
export function groupTaskRows(
  rows: TaskRow[],
  options?: { showDone?: boolean },
): { name: TaskBoardState; rows: TaskRow[] }[];
export function lastActivity(
  row: Pick<TaskRow, "activityAt">,
  now?: number,
): string;
