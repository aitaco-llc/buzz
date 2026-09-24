import { useQuery } from "@tanstack/react-query";

import { fetchTaskBoard, type TaskRepo } from "./taskBoardFetch";

/**
 * The task board for one repository.
 *
 * `staleTime` matches the project queries: the board moves when someone posts,
 * and a tab that refetches on every focus would hammer the relay with
 * per-thread queries for no new information.
 */
export function useTaskBoardQuery(repo: TaskRepo | null | undefined) {
  return useQuery({
    enabled: Boolean(repo),
    queryKey: ["tasks", repo?.owner ?? "none", repo?.id ?? "none", "board"],
    queryFn: () => {
      if (!repo) throw new Error("No task repository configured.");
      return fetchTaskBoard(repo);
    },
    staleTime: 30_000,
  });
}
