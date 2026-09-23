import * as React from "react";

import { useTaskBoardQuery } from "@/features/tasks/hooks";
import {
  groupTaskRows,
  lastActivity,
  type TaskRow,
} from "@/features/tasks/taskRows.mjs";
import { Badge } from "@/shared/ui/badge";
import { PubKey } from "@/shared/ui/PubKey";
import { Button } from "@/shared/ui/button";

/**
 * The task board.
 *
 * Every state on this screen is derived from public events by
 * `taskBoard.mjs`, the mirror of `crates/buzz-core/src/task_board.rs`, so this
 * view and `buzz tasks board` agree about a task by construction. Nothing here
 * decides a state; it only renders one.
 */

/** The tracker repository. One place, so the route and the tab cannot differ. */
export const TASKS_REPO = {
  owner: "41243293dd98372825e2c57bb2b44a100c36809a4339cf9bd564c9c33f8d5d0c",
  id: "aitaco-tasks",
};

const STATE_TONE: Record<string, string> = {
  Unassigned: "border-destructive/50 text-destructive",
  Blocked: "border-amber-500/50 text-amber-600 dark:text-amber-400",
  "In Progress": "border-emerald-500/50 text-emerald-600 dark:text-emerald-400",
  "Up Next": "border-muted-foreground/30 text-muted-foreground",
  Done: "border-muted-foreground/20 text-muted-foreground",
};

export function TasksView() {
  const [showDone, setShowDone] = React.useState(false);
  const query = useTaskBoardQuery(TASKS_REPO);
  const groups = React.useMemo(
    () => groupTaskRows(query.data ?? [], { showDone }),
    [query.data, showDone],
  );

  return (
    <div className="flex min-h-0 min-w-0 flex-1 flex-col overflow-hidden">
      <header className="flex items-center justify-between gap-3 border-b px-6 py-4">
        <div>
          <h1 className="text-lg font-semibold">Tasks</h1>
          <p className="text-sm text-muted-foreground">
            Active work, derived from what happened — never hand-set.
          </p>
        </div>
        <Button
          variant={showDone ? "secondary" : "ghost"}
          size="sm"
          onClick={() => setShowDone((on) => !on)}
        >
          {showDone ? "Hide done" : "Show done"}
        </Button>
      </header>

      <div className="min-h-0 flex-1 overflow-y-auto px-6 py-4">
        {query.isPending ? (
          <p className="text-sm text-muted-foreground">Reading the board…</p>
        ) : query.isError ? (
          <p className="text-sm text-destructive">
            The board could not be read. It is on the relay, not in this app —
            nothing has been lost.
          </p>
        ) : groups.length === 0 ? (
          <p className="text-sm text-muted-foreground">
            Nothing on the board. {showDone ? "" : "Completed work is hidden."}
          </p>
        ) : (
          groups.map((group) => (
            <section key={group.name} className="mb-6">
              <h2 className="mb-2 text-xs font-medium uppercase tracking-wide text-muted-foreground">
                {group.name} · {group.rows.length}
              </h2>
              <ul className="flex flex-col gap-2">
                {group.rows.map((row) => (
                  <TaskCard key={row.id} row={row} />
                ))}
              </ul>
            </section>
          ))
        )}
      </div>
    </div>
  );
}

function TaskCard({ row }: { row: TaskRow }) {
  return (
    <li className="rounded-md border px-3 py-2">
      <div className="flex items-start justify-between gap-3">
        <span className="text-sm font-medium">{row.subject}</span>
        <Badge variant="outline" className={STATE_TONE[row.state] ?? ""}>
          {row.state}
        </Badge>
      </div>
      <div className="mt-1 flex flex-wrap items-center gap-x-3 gap-y-1 text-xs text-muted-foreground">
        {row.assignee ? (
          // Never hand-truncate a pubkey: `PubKey` is the one renderer, and
          // `scripts/check-pubkey-truncation.mjs` enforces it. It also gives
          // the assignee a copyable npub, which a nudge in a thread cannot.
          <PubKey pubkey={row.assignee} variant="compact" />
        ) : (
          <span>nobody assigned</span>
        )}
        <span>{lastActivity(row)}</span>
        {row.commentCount > 0 ? <span>{row.commentCount} comments</span> : null}
        {row.linkedThreads.length === 0 ? (
          // Without a linked thread nothing that happens in a channel can ever
          // count as activity, so the row would sit in Up Next while the work
          // is being done. Saying so is more useful than showing a stale state.
          <span className="text-amber-600 dark:text-amber-400">
            no linked thread
          </span>
        ) : null}
      </div>
    </li>
  );
}
