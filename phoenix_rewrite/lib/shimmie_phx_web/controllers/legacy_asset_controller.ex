defmodule ShimmiePhoenixWeb.LegacyAssetController do
  use ShimmiePhoenixWeb, :controller

  alias ShimmiePhoenix.Site
  alias ShimmiePhoenixWeb.MediaController
  @allowed_data_roots MapSet.new(["cache"])

  @blocked_extensions MapSet.new([
                        ".php",
                        ".phtml",
                        ".phar",
                        ".pl",
                        ".py",
                        ".rb",
                        ".sh",
                        ".bash",
                        ".ex",
                        ".exs",
                        ".sql",
                        ".sqlite",
                        ".sqlite3",
                        ".db",
                        ".env",
                        ".conf",
                        ".ini",
                        ".yml",
                        ".yaml"
                      ])

  def data(conn, %{"path" => ["images" | parts]}) when parts != [],
    do: MediaController.legacy_image(conn, %{"hash" => List.last(parts)})

  def data(conn, %{"path" => ["thumbs" | parts]}) when parts != [],
    do: MediaController.legacy_thumb(conn, %{"hash" => List.last(parts)})

  def data(conn, %{"path" => path_parts}), do: serve(conn, ["data" | path_parts])
  def ext(conn, %{"path" => path_parts}), do: serve(conn, ["ext" | path_parts])
  def themes(conn, %{"path" => path_parts}), do: serve(conn, ["themes" | path_parts])
  def favicon(conn, _params), do: serve(conn, ["favicon.ico"])

  def apple_touch_icon(conn, _params) do
    with {:ok, file_path} <- safe_legacy_path(["apple-touch-icon.png"]),
         true <- File.regular?(file_path) do
      conn
      |> put_resp_content_type("image/png")
      |> send_file(200, file_path)
    else
      _ ->
        with {:ok, favicon_path} <- safe_legacy_path(["favicon.ico"]),
             true <- File.regular?(favicon_path) do
          conn
          |> put_resp_content_type("image/x-icon")
          |> send_file(200, favicon_path)
        else
          _ -> send_resp(conn, 204, "")
        end
    end
  end

  defp serve(conn, path_parts) do
    with :ok <- validate_request_path(path_parts),
         {:ok, file_path} <- safe_legacy_path(path_parts),
         true <- regular_non_symlink_file?(file_path),
         :ok <- validate_public_extension(file_path) do
      mime = MIME.from_path(file_path) || "application/octet-stream"

      conn
      |> put_resp_content_type(mime)
      |> maybe_put_immutable_cache(path_parts)
      |> send_file(200, file_path)
    else
      _ -> send_resp(conn, 404, "Not Found")
    end
  end

  defp maybe_put_immutable_cache(conn, ["ext", "home", "counters" | _rest]) do
    # Treat counter digit assets as immutable static content.
    conn
    |> put_resp_header("cache-control", "public, max-age=31536000, immutable")
    |> put_resp_header("expires", "Thu, 31 Dec 2099 23:59:59 GMT")
  end

  defp maybe_put_immutable_cache(conn, _path_parts), do: conn

  defp validate_request_path(["favicon.ico"]), do: :ok
  defp validate_request_path(["apple-touch-icon.png"]), do: :ok

  defp validate_request_path([scope | rest]) when scope in ["data", "ext", "themes"] do
    cond do
      rest == [] ->
        {:error, :invalid_path}

      Enum.any?(rest, &invalid_segment?/1) ->
        {:error, :invalid_path}

      scope == "data" and not allowed_data_scope?(rest) ->
        {:error, :invalid_path}

      true ->
        :ok
    end
  end

  defp validate_request_path(_), do: {:error, :invalid_path}

  defp invalid_segment?(segment) do
    part = to_string(segment || "")
    part in ["", ".", ".."] or String.starts_with?(part, ".")
  end

  defp allowed_data_scope?([root | _]), do: MapSet.member?(@allowed_data_roots, root)
  defp allowed_data_scope?(_), do: false

  defp validate_public_extension(path) do
    ext = path |> Path.extname() |> String.downcase()
    if MapSet.member?(@blocked_extensions, ext), do: {:error, :blocked_ext}, else: :ok
  end

  defp regular_non_symlink_file?(path) do
    case File.lstat(path) do
      {:ok, %File.Stat{type: :regular}} -> true
      _ -> false
    end
  end

  defp safe_legacy_path(path_parts) do
    case path_parts do
      [scope | rest] when scope in ["data", "themes", "ext"] and rest != [] ->
        # Each operator-configured scope root may itself point into an immutable
        # release. Reject links beneath that boundary, not the boundary itself.
        ShimmiePhoenix.SafePath.regular_file(
          Path.join(Site.legacy_root(), scope),
          Path.join(rest)
        )

      parts ->
        ShimmiePhoenix.SafePath.regular_file(Site.legacy_root(), Path.join(parts))
    end
  end
end
