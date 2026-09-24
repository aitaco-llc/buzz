export const FAILURE_NOTICE_PREFIX: string;
export const WATCHDOG_PUBKEY: string;
export const STALL_AFTER_SECS: number;
export const IN_PROGRESS_WITHIN_SECS: number;
export const TASK_BOARD_STATE: {
  DONE: "Done";
  UNASSIGNED: "Unassigned";
  BLOCKED: "Blocked";
  IN_PROGRESS: "In Progress";
  UP_NEXT: "Up Next";
};

export type TaskBoardInput = {
  createdAt: number;
  closed: boolean;
  assignee: string | null;
  blockedBy: string | null;
  linkedThreads: string[];
  posts: {
    thread: string | null;
    pubkey: string;
    createdAt: number;
    content: string;
  }[];
  assigneeSeatUp: boolean;
  assigneeTurnInFlight: boolean;
};

export function taskActivityAt(task: TaskBoardInput): number | null;
export function deriveTaskBoardState(
  task: TaskBoardInput,
  now: number,
): {
  state: "Done" | "Unassigned" | "Blocked" | "In Progress" | "Up Next";
  activityAt: number | null;
  stalled: boolean;
};
