defmodule Pow.Plug.SessionTest do
  use ExUnit.Case
  doctest Pow.Plug.Session

  alias Pow.{Config, Plug, Plug.Session, Store.CredentialsCache}
  alias Pow.Test.{ConnHelpers, EtsCacheMock}

  @default_opts [
    current_user_assigns_key: :current_user,
    session_key: "auth",
    cache_store_backend: EtsCacheMock
  ]

  setup do
    EtsCacheMock.init()
    conn = :get |> ConnHelpers.conn("/") |> ConnHelpers.with_session()

    {:ok, %{conn: conn}}
  end

  test "call/2 sets mod in :pow_config", %{conn: conn} do
    conn = Session.call(conn, @default_opts)

    assert is_nil(conn.assigns[:current_user])
    assert conn.private[:pow_config] == Config.put(@default_opts, :mod, Session)
  end

  test "call/2 with assigned current_user", %{conn: conn} do
    conn =
      conn
      |> Plug.assign_current_user("assigned", @default_opts)
      |> Session.call(@default_opts)

    assert conn.assigns[:current_user] == "assigned"
  end

  test "call/2 with stored current_user", %{conn: conn} do
    EtsCacheMock.put(nil, "token", {"cached", :os.system_time(:millisecond)})

    conn =
      conn
      |> ConnHelpers.put_session(@default_opts[:session_key], "token")
      |> Session.call(@default_opts)

    assert conn.assigns[:current_user] == "cached"
  end

  test "call/2 with non existing cached key", %{conn: conn} do
    EtsCacheMock.put(nil, "token", "cached")

    conn =
      conn
      |> ConnHelpers.put_session(@default_opts[:session_key], "invalid")
      |> Session.call(@default_opts)

    assert is_nil(conn.assigns[:current_user])
  end

  test "call/2 creates new session when :session_renewal_ttl reached", %{conn: conn} do
    ttl             = 100
    config          = Keyword.put(@default_opts, :session_ttl_renewal, ttl)
    timestamp       = :os.system_time(:millisecond)
    stale_timestamp = timestamp - ttl - 1
    conn            = ConnHelpers.put_session(conn, config[:session_key], "token")

    EtsCacheMock.put(nil, "token", {"cached", timestamp})

    fetched_conn = Session.call(conn, config)
    session_id = get_session_id(fetched_conn)

    assert fetched_conn.assigns[:current_user] == "cached"

    EtsCacheMock.put(nil, "token", {"cached", stale_timestamp})

    fetched_conn = Session.call(conn, config)

    assert fetched_conn.assigns[:current_user] == "cached"
    assert new_session_id = get_session_id(fetched_conn)
    assert new_session_id != session_id
  end

  test "create/2 creates new session id", %{conn: conn} do
    user = %{id: 1}
    conn =
      conn
      |> Session.call(@default_opts)
      |> Session.do_create(user)

    session_id = get_session_id(conn)
    {etc_user, _inserted_at} = EtsCacheMock.get(nil, session_id)

    assert is_binary(session_id)
    assert etc_user == user
    assert Plug.current_user(conn) == user

    conn = Session.do_create(conn, user)
    new_session_id = get_session_id(conn)
    {etc_user, _inserted_at} = EtsCacheMock.get(nil, new_session_id)

    assert is_binary(session_id)
    assert new_session_id != session_id
    assert EtsCacheMock.get(nil, session_id) == :not_found
    assert etc_user == user
    assert Plug.current_user(conn) == user
  end

  test "delete/1 removes session id", %{conn: conn} do
    user = %{id: 1}
    conn =
      conn
      |> Session.call(@default_opts)
      |> Session.do_create(user)

    session_id = get_session_id(conn)
    {etc_user, _inserted_at} = EtsCacheMock.get(nil, session_id)

    assert is_binary(session_id)
    assert etc_user == user
    assert Plug.current_user(conn) == user

    conn = Session.do_delete(conn)

    refute new_session_id = get_session_id(conn)
    assert is_nil(new_session_id)
    assert EtsCacheMock.get(nil, session_id) == :not_found
    assert is_nil(Plug.current_user(conn))
  end

  describe "with EtsCache backend" do
    test "stores through CredentialsCache", %{conn: conn} do
      sesion_key = "auth"
      config     = [session_key: sesion_key]
      token      = "credentials_cache_test"
      timestamp  = :os.system_time(:millisecond)
      CredentialsCache.put(config, token, {"cached", timestamp})

      :timer.sleep(100)

      conn =
        conn
        |> ConnHelpers.put_session("auth", token)
        |> Session.call(session_key: "auth")

      assert conn.assigns[:current_user] == "cached"
    end
  end

  def get_session_id(conn) do
    conn.private[:plug_session][@default_opts[:session_key]]
  end
end