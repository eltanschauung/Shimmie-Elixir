defmodule ShimmiePhoenix.SafePath do
  @moduledoc "Reject descendant symlinks while allowing an operator-configured root/state symlink."

  def regular_file(root, relative) do
    root = Path.expand(root)
    parts = Path.split(relative)

    if Path.type(relative) == :relative and parts != [] and
         Enum.all?(parts, &(&1 not in [".", "..", ""])) do
      walk(root, parts)
    else
      {:error, :invalid_path}
    end
  end

  defp walk(root, [file]) do
    path = Path.join(root, file)

    case File.lstat(path) do
      {:ok, %File.Stat{type: :regular}} -> {:ok, path}
      _ -> {:error, :invalid_path}
    end
  end

  defp walk(root, [directory | rest]) do
    path = Path.join(root, directory)

    case File.lstat(path) do
      {:ok, %File.Stat{type: :directory}} -> walk(path, rest)
      _ -> {:error, :invalid_path}
    end
  end
end
