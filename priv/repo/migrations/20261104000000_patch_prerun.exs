defmodule BorsNG.Database.Repo.Migrations.PatchPrerun do
  use Ecto.Migration

  def change do
    alter table(:patches) do
      add :prerun_reviewer, :string
      add :prerun_since, :utc_datetime
    end

    create index(:patches, [:project_id, :prerun_since])
  end
end
