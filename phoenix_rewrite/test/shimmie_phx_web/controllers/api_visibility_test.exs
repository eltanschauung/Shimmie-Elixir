defmodule ShimmiePhoenixWeb.APIVisibilityTest do
  use ShimmiePhoenixWeb.ConnCase, async: false
  alias ShimmiePhoenix.{Repo, SiteSchemaHelper}

  setup do
    SiteSchemaHelper.ensure_legacy_tables!()
    SiteSchemaHelper.reset_legacy_tables!()

    Repo.query!(
      "ALTER TABLE images ADD COLUMN IF NOT EXISTS approved BOOLEAN NOT NULL DEFAULT TRUE"
    )

    Repo.query!("INSERT INTO config(name,value) VALUES ('approve_images','1')")

    for {id, name, class} <- [
          {2, "owner", "user"},
          {3, "reader", "user"},
          {4, "reviewer", "moderator"}
        ] do
      Repo.query!("INSERT INTO users(id,name,class) VALUES ($1,$2,$3)", [id, name, class])
    end

    Repo.query!(
      "INSERT INTO images(id,owner_id,filename,filesize,hash,ext,width,height,approved) VALUES (901,2,'pending.png',1,$1,'png',1,1,FALSE)",
      [String.duplicate("a", 32)]
    )

    :ok
  end

  test "every JSON/XML selector respects guest, owner and moderator visibility", %{conn: conn} do
    for selector <- ["id=901", "md5=" <> String.duplicate("a", 32)] do
      url = "/api/danbooru/find_posts/index.json?" <> selector
      assert json_response(get(conn, url), 200) == []
      assert json_response(conn |> init_test_session(%{site_user_id: 3}) |> get(url), 200) == []

      for id <- [2, 4] do
        result = conn |> init_test_session(%{site_user_id: id}) |> get(url)
        assert [%{"id" => 901}] = json_response(result, 200)
        assert get_resp_header(result, "cache-control") == ["private, no-store"]
      end

      for route <- ["/api/danbooru/find_posts?", "/api/danbooru/post/index.xml?"] do
        result = get(conn, route <> selector)
        assert response(result, 200) =~ "count=\"0\""
        refute response(result, 200) =~ "pending.png"
        owner = conn |> init_test_session(%{site_user_id: 2}) |> get(route <> selector)
        assert response(owner, 200) =~ "id=\"901\""
      end
    end
  end

  test "malformed or over-budget selectors never fall back to an unrestricted search", %{
    conn: conn
  } do
    for selector <- [
          "id=bad",
          "id[]=901",
          "md5=bad",
          "id=" <> Enum.map_join(1..201, ",", &to_string/1)
        ] do
      assert json_response(get(conn, "/api/danbooru/find_posts/index.json?" <> selector), 200) ==
               []
    end
  end
end
