defmodule ShimmiePhoenixWeb.TransportSecurityTest do
  use ExUnit.Case, async: true

  defmodule Probe do
    def init(opts), do: opts
    def call(conn, _opts), do: Plug.Conn.send_resp(conn, 200, "transport-ok")
  end

  setup do
    server =
      start_supervised!(
        {Bandit,
         plug: Probe, ip: {127, 0, 0, 1}, port: 0, thousand_island_options: [num_acceptors: 1]}
      )

    {:ok, {_ip, port}} = ThousandIsland.listener_info(server)
    %{port: port}
  end

  test "HTTP server accepts ordinary requests", %{port: port} do
    assert request(port, "GET / HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n") =~
             "HTTP/1.1 200"
  end

  test "HTTP server rejects ambiguous duplicate content lengths", %{port: port} do
    assert request(
             port,
             "POST / HTTP/1.1\r\nHost: localhost\r\nContent-Length: 0\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
           ) =~ ~r/HTTP\/1\.[01] 400/
  end

  test "HTTP server rejects duplicate host headers", %{port: port} do
    assert request(
             port,
             "GET / HTTP/1.1\r\nHost: localhost\r\nHost: example.invalid\r\nConnection: close\r\n\r\n"
           ) =~ ~r/HTTP\/1\.[01] 400/
  end

  defp request(port, bytes) do
    {:ok, socket} = :gen_tcp.connect({127, 0, 0, 1}, port, [:binary, active: false], 2_000)

    try do
      :ok = :gen_tcp.send(socket, bytes)
      {:ok, response} = :gen_tcp.recv(socket, 0, 2_000)
      response
    after
      :gen_tcp.close(socket)
    end
  end
end
