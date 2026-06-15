defmodule AiroClient.Application do
  @moduledoc false
  use Application

  @impl true
  def start(_type, _args) do
    children = [
      # Owns the processes that consume streaming responses off the caller's path.
      {Task.Supervisor, name: AiroClient.TaskSupervisor}
    ]

    Supervisor.start_link(children, strategy: :one_for_one, name: AiroClient.Supervisor)
  end
end
