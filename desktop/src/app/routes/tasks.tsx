import * as React from "react";
import { createFileRoute } from "@tanstack/react-router";

import { ViewLoadingFallback } from "@/shared/ui/ViewLoadingFallback";

const TasksView = React.lazy(async () => {
  const module = await import("@/features/tasks/ui/TasksView");
  return { default: module.TasksView };
});

export const Route = createFileRoute("/tasks")({
  component: TasksRouteComponent,
});

function TasksRouteComponent() {
  return (
    <React.Suspense fallback={<ViewLoadingFallback kind="projects" />}>
      <TasksView />
    </React.Suspense>
  );
}
