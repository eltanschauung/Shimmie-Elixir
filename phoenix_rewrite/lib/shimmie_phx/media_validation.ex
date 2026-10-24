defmodule ShimmiePhoenix.MediaValidation do
  @moduledoc "Signature checks followed by bounded, explicit-coder image decoding; failed decodes are never thumbnails."
  alias ShimmiePhoenix.BoundedCommand
  alias ShimmiePhoenix.Site.Store

  @coders %{
    "jpg" => "JPEG",
    "jpeg" => "JPEG",
    "jfif" => "JPEG",
    "jfi" => "JPEG",
    "png" => "PNG",
    "gif" => "GIF",
    "webp" => "WEBP",
    "avif" => "AVIF"
  }
  @limits [
    "-limit",
    "memory",
    "64MiB",
    "-limit",
    "map",
    "128MiB",
    "-limit",
    "disk",
    "32MiB",
    "-limit",
    "thread",
    "1",
    "-limit",
    "time",
    "20",
    "-limit",
    "width",
    "100000",
    "-limit",
    "height",
    "100000"
  ]

  def prepare(path, ext, thumb) do
    with {:ok, header} <- header(path), true <- signature?(header, ext) do
      case Map.get(@coders, ext) do
        nil -> {:ok, {0, 0}}
        coder -> image(path, coder, thumb)
      end
    else
      _ -> {:error, :invalid_upload}
    end
  end

  defp image(path, coder, thumb) do
    convert = Store.get_config("media_convert_path", "convert") |> to_string() |> String.trim()
    identify = String.replace_suffix(convert, "convert", "identify")
    input = coder <> ":" <> path <> "[0]"

    with {:ok, dimensions} <- BoundedCommand.run(identify, @limits ++ ["-format", "%w %h", input]),
         [w, h] <- String.split(String.trim(dimensions)),
         {width, ""} <- Integer.parse(w),
         {height, ""} <- Integer.parse(h),
         true <- width > 0 and height > 0 and width * height <= 20_000_000,
         {:ok, _} <-
           BoundedCommand.run(
             convert,
             @limits ++
               [
                 input,
                 "-auto-orient",
                 "-thumbnail",
                 thumb_size(),
                 "-background",
                 background(),
                 "-alpha",
                 "remove",
                 "-alpha",
                 "off",
                 "-strip",
                 "-quality",
                 "90",
                 "JPEG:" <> thumb
               ]
           ),
         {:ok, <<255, 216, 255, _::binary>>} <- header(thumb) do
      {:ok, {width, height}}
    else
      _ -> {:error, :invalid_upload}
    end
  end

  defp thumb_size do
    w = size(Store.get_config("thumb_width", "192"))
    h = size(Store.get_config("thumb_height", "192"))
    "#{w}x#{h}>"
  end

  defp background do
    value =
      Store.get_config("thumb_alpha_color", "#ffffff")
      |> to_string()
      |> String.trim()
      |> String.trim_leading("#")

    if Regex.match?(~r/\A[0-9a-fA-F]{6}\z/, value), do: "#" <> value, else: "#ffffff"
  end

  defp size(value) do
    case Integer.parse(to_string(value)) do
      {n, ""} when n > 0 -> min(n, 2048)
      _ -> 192
    end
  end

  defp header(path) do
    with {:ok, file} <- File.open(path, [:read, :binary]) do
      try do
        case IO.binread(file, 64) do
          value when is_binary(value) -> {:ok, value}
          _ -> {:error, :invalid_upload}
        end
      after
        File.close(file)
      end
    end
  end

  defp signature?(<<255, 216, 255, _::binary>>, ext) when ext in ["jpg", "jpeg", "jfif", "jfi"],
    do: true

  defp signature?(<<137, 80, 78, 71, 13, 10, 26, 10, _::binary>>, "png"), do: true

  defp signature?(<<"GIF", version::binary-size(3), _::binary>>, "gif"),
    do: version in ["87a", "89a"]

  defp signature?(<<"RIFF", _::binary-size(4), "WEBP", _::binary>>, "webp"), do: true

  defp signature?(<<_::binary-size(4), "ftyp", brand::binary-size(4), _::binary>>, "avif"),
    do: brand in ["avif", "avis"]

  defp signature?(<<"PK", a, b, _::binary>>, "zip"), do: {a, b} in [{3, 4}, {5, 6}, {7, 8}]
  defp signature?(<<kind::binary-size(3), _::binary>>, "swf"), do: kind in ["FWS", "CWS", "ZWS"]
  defp signature?(<<"RIFF", _::binary-size(4), "AVI ", _::binary>>, "avi"), do: true
  defp signature?(<<26, 69, 223, 163, _::binary>>, ext) when ext in ["mkv", "webm"], do: true
  defp signature?(<<"OggS", _::binary>>, "ogv"), do: true
  defp signature?(<<"FLV", _::binary>>, "flv"), do: true

  defp signature?(<<_::binary-size(4), atom::binary-size(4), _::binary>>, ext)
       when ext in ["mp4", "m4v", "mov"], do: atom in ["ftyp", "moov", "mdat", "wide"]

  defp signature?(
         <<48, 38, 178, 117, 142, 102, 207, 17, 166, 217, 0, 170, 0, 98, 206, 108, _::binary>>,
         ext
       )
       when ext in ["asf", "wmv", "wma"], do: true

  defp signature?(_, _), do: false
end
