defmodule Rumbo.ProjectsTest do
  use Rumbo.DataCase, async: true

  import Rumbo.Fixtures

  alias Rumbo.Projects

  describe "create_project/1" do
    test "genera el slug desde el nombre" do
      assert {:ok, project} = Projects.create_project(%{name: "Better Route 2.0"})
      assert project.slug == "better-route-2-0"
    end

    test "rechaza slugs duplicados" do
      {:ok, _} = Projects.create_project(%{name: "Uno", slug: "repetido"})
      assert {:error, changeset} = Projects.create_project(%{name: "Dos", slug: "repetido"})
      assert %{slug: ["has already been taken"]} = errors_on(changeset)
    end
  end

  describe "API keys" do
    test "autentica una key válida y devuelve su proyecto" do
      project = project_fixture()
      raw_key = api_key_fixture(project)

      assert String.starts_with?(raw_key, "rk_")
      assert {:ok, authenticated} = Projects.authenticate_api_key(raw_key)
      assert authenticated.id == project.id
    end

    test "rechaza keys desconocidas o malformadas" do
      assert {:error, :unauthorized} = Projects.authenticate_api_key("rk_inventada")
      assert {:error, :unauthorized} = Projects.authenticate_api_key("otracosa")
      assert {:error, :unauthorized} = Projects.authenticate_api_key(nil)
    end

    test "rechaza keys revocadas" do
      project = project_fixture()
      {:ok, api_key, raw_key} = Projects.create_api_key(project, "para-revocar")

      assert {:ok, _} = Projects.authenticate_api_key(raw_key)
      assert {:ok, _} = Projects.revoke_api_key(project, api_key.id)
      assert {:error, :unauthorized} = Projects.authenticate_api_key(raw_key)
    end
  end
end
