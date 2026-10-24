defmodule ShimmiePhoenix.SafeFetch do
  @moduledoc "HTTP(S) imports pinned to validated public DNS addresses, without proxies or redirects."
  import Bitwise
  alias ShimmiePhoenix.{BoundedCommand, SourceURL}

  def fetch(url, target, max_size) do
    with {:ok, %{url: url, host: host, port: port, address: address}} <- destination(url),
         pin <- "#{host}:#{port}:#{address}",
         {:ok, status} <-
           BoundedCommand.run(
             "curl",
             [
               "-q",
               "--fail",
               "--silent",
               "--show-error",
               "--proto",
               "=http,https",
               "--proto-redir",
               "=http,https",
               "--max-redirs",
               "0",
               "--noproxy",
               "*",
               "--proxy",
               "",
               "--connect-timeout",
               "5",
               "--max-time",
               "25",
               "--max-filesize",
               Integer.to_string(max_size),
               "--resolve",
               pin,
               "--output",
               target,
               "--write-out",
               "%{http_code}",
               "--",
               url
             ], max_file_size: max_size),
         {code, ""} when code in 200..299 <- Integer.parse(status),
         {:ok, %{size: size}} when size > 0 and size <= max_size <- File.stat(target) do
      :ok
    else
      _ ->
        File.rm(target)
        {:error, :transload_failed}
    end
  end

  def destination(url, resolver \\ &resolve/1) do
    with value when is_binary(value) <- SourceURL.href(url),
         %URI{host: original_host, port: port} = uri <- URI.parse(value),
         host <- original_host |> String.downcase() |> String.trim_trailing("."),
         true <- port in [80, 443],
         true <- valid_host?(host),
         {:ok, addresses} when addresses != [] <- resolver.(host),
         true <- Enum.all?(addresses, &public_address?/1) do
      address = hd(addresses) |> :inet.ntoa() |> to_string()

      {:ok,
       %{
         url: URI.to_string(%{uri | host: host, authority: nil, fragment: nil}),
         host: host,
         port: port,
         address: if(String.contains?(address, ":"), do: "[#{address}]", else: address)
       }}
    else
      _ -> {:error, :invalid_url}
    end
  end

  def public_address?({a, b, c, d})
      when a in 0..255 and b in 0..255 and c in 0..255 and d in 0..255 do
    not (a in [0, 10, 127] or a >= 224 or (a == 100 and b in 64..127) or
           (a == 169 and b == 254) or (a == 172 and b in 16..31) or
           (a == 192 and (b == 168 or (b == 0 and c in [0, 2]) or (b == 88 and c == 99))) or
           (a == 198 and (b in [18, 19] or (b == 51 and c == 100))) or
           (a == 203 and b == 0 and c == 113))
  end

  def public_address?({a, b, c, d, e, f, g, h}) do
    Enum.all?([a, b, c, d, e, f, g, h], &(&1 in 0..65_535)) and
      (a &&& 0xE000) == 0x2000 and a != 0x2002 and
      not (a == 0x2001 and (b < 0x0200 or b == 0x0DB8)) and a != 0x3FFF
  end

  def public_address?(_), do: false

  defp valid_host?(host),
    do: byte_size(host) <= 253 and Regex.match?(~r/\A[a-zA-Z0-9][a-zA-Z0-9.-]*\z/, host)

  defp resolve(host) do
    task =
      Task.async(fn ->
        addresses =
          for family <- [:inet, :inet6],
              {:ok, values} <- [:inet.getaddrs(String.to_charlist(host), family)],
              address <- values,
              do: address

        {:ok, Enum.uniq(addresses)}
      end)

    case Task.yield(task, 2000) || Task.shutdown(task, :brutal_kill) do
      {:ok, result} -> result
      _ -> {:error, :dns_failed}
    end
  end
end
