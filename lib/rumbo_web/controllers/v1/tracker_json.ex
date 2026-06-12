defmodule RumboWeb.V1.TrackerJSON do
  alias Rumbo.Tracking

  def index(%{trackers: trackers, project: project}) do
    %{data: Enum.map(trackers, &data(&1, project))}
  end

  def show(%{tracker: tracker, project: project}) do
    %{data: data(tracker, project)}
  end

  def data(tracker, project) do
    %{
      key: tracker.key,
      name: tracker.name,
      metadata: tracker.metadata,
      position: tracker.last_position,
      last_seen_at: tracker.last_seen_at,
      online: Tracking.online?(project, tracker),
      created_at: tracker.inserted_at
    }
  end
end
