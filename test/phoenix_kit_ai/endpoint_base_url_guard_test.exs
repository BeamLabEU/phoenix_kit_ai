defmodule PhoenixKitAI.EndpointBaseUrlGuardTest do
  @moduledoc """
  The SSRF guard on `Endpoint.base_url`, by host shape × rule: an address
  literal, a name resolving to an internal address, a name resolving to a
  public one and a name that does not resolve — each with the
  `:allow_internal_endpoint_urls` opt-out off and on — plus the bounds on
  the lookup itself and the refusal to follow a provider's redirect.

  Names resolve through the VM's own hosts table (`:inet_db`), put ahead
  of the system resolver for the duration of a test, so nothing here
  depends on real DNS answers.
  """

  use PhoenixKitAI.DataCase, async: false

  alias PhoenixKitAI.Endpoint
  alias PhoenixKitAI.Providers.HTTP

  @internal_name "internal.pk-ai-test"
  @public_name "public.pk-ai-test"
  @unresolvable_name "nowhere.pk-ai-test.invalid"

  @internal_ip {10, 1, 2, 3}
  @public_ip {93, 184, 216, 34}

  setup do
    lookup = :inet_db.res_option(:lookup)
    :inet_db.set_lookup([:file | lookup -- [:file]])
    :inet_db.add_host(@internal_ip, [String.to_charlist(@internal_name)])
    :inet_db.add_host(@public_ip, [String.to_charlist(@public_name)])

    on_exit(fn ->
      :inet_db.del_host(@internal_ip)
      :inet_db.del_host(@public_ip)
      :inet_db.set_lookup(lookup)
      Application.delete_env(:phoenix_kit_ai, :allow_internal_endpoint_urls)
      Application.delete_env(:phoenix_kit_ai, :req_options)
    end)
  end

  defp attrs(url) do
    %{
      name: "Guard #{System.unique_integer([:positive])}",
      provider: "openrouter",
      model: "a/b",
      api_key: "sk-test-key",
      base_url: url
    }
  end

  defp changeset(url, opts \\ []), do: Endpoint.changeset(%Endpoint{}, attrs(url), opts)

  defp base_url_errors(changeset) do
    for {:base_url, {message, _}} <- changeset.errors, do: message
  end

  @shapes [
    {"an internal address literal", "http://10.1.2.3:11434/v1", :internal},
    {"a name resolving to an internal address", "http://#{@internal_name}:11434/v1", :internal},
    {"a public address literal", "https://93.184.216.34/v1", :public},
    {"a name resolving to a public address", "https://#{@public_name}/v1", :public},
    {"a name that does not resolve", "https://#{@unresolvable_name}/v1", :unresolved}
  ]

  describe "with the opt-out off" do
    for {label, url, class} <- @shapes do
      if class == :internal do
        test "#{label} is refused, by the changeset and by create_endpoint/2" do
          changeset = changeset(unquote(url))

          refute changeset.valid?
          assert [message] = base_url_errors(changeset)
          assert message =~ "private/loopback/link-local"
          assert message =~ "allow_internal_endpoint_urls"

          assert {:error, %Ecto.Changeset{}} = PhoenixKitAI.create_endpoint(attrs(unquote(url)))
        end
      else
        test "#{label} is accepted, by the changeset and by create_endpoint/2" do
          assert changeset(unquote(url)).valid?
          assert {:ok, endpoint} = PhoenixKitAI.create_endpoint(attrs(unquote(url)))
          assert endpoint.base_url == unquote(url)
        end
      end
    end

    test "names reserved for internal use are refused without a lookup" do
      for url <- [
            "http://host.docker.internal:11434/v1",
            "http://metadata.google.internal/",
            "http://localhost.:11434/v1",
            "http://127.0.0.1.:11434/v1"
          ] do
        refute changeset(url).valid?, url
        # The same answer with resolution off: no lookup was needed.
        refute changeset(url, resolve_base_url: false).valid?, url
      end
    end

    test "the address ranges of the image-fetch policy apply to literals too" do
      for url <- [
            "http://198.18.0.1/",
            "http://224.0.0.1/",
            "http://192.0.0.8/",
            "http://[64:ff9b::7f00:1]/",
            "http://[2002:7f00:1::]/",
            "http://[::ffff:169.254.169.254]/"
          ] do
        refute changeset(url).valid?, url
      end
    end
  end

  describe "with the opt-out on" do
    setup do
      Application.put_env(:phoenix_kit_ai, :allow_internal_endpoint_urls, true)
    end

    for {label, url, _class} <- @shapes do
      test "#{label} is accepted, by the changeset and by create_endpoint/2" do
        assert changeset(unquote(url)).valid?
        assert {:ok, endpoint} = PhoenixKitAI.create_endpoint(attrs(unquote(url)))
        assert endpoint.base_url == unquote(url)
      end
    end

    test "a scheme other than http(s) is still refused" do
      refute changeset("file:///etc/passwd").valid?
    end
  end

  describe "when the name is resolved" do
    test "a form's changeset does not resolve; saving does" do
      url = "http://#{@internal_name}:11434/v1"

      assert PhoenixKitAI.change_endpoint(%Endpoint{}, attrs(url)).valid?
      assert {:error, changeset} = PhoenixKitAI.create_endpoint(attrs(url))
      assert [_] = base_url_errors(changeset)
    end

    test "a stored base_url is not resolved again by an unrelated update" do
      moving_ip = {198, 51, 100, 7}
      moving_name = ~c"moving.pk-ai-test"
      :inet_db.add_host(moving_ip, [moving_name])
      on_exit(fn -> :inet_db.del_host(moving_ip) end)

      url = "https://moving.pk-ai-test/v1"
      {:ok, endpoint} = PhoenixKitAI.create_endpoint(attrs(url))

      # The name now answers with an internal address.
      :inet_db.del_host(moving_ip)
      :inet_db.add_host({10, 9, 9, 9}, [moving_name])
      on_exit(fn -> :inet_db.del_host({10, 9, 9, 9}) end)

      assert {:ok, disabled} = PhoenixKitAI.update_endpoint(endpoint, %{enabled: false})
      refute disabled.enabled

      # Setting the URL is what gets it looked at.
      assert {:error, changeset} =
               PhoenixKitAI.update_endpoint(disabled, %{base_url: url <> "/again"})

      assert [_] = base_url_errors(changeset)
    end

    test "the provider's own default URL is accepted without a lookup" do
      default = Endpoint.default_base_url("openrouter")
      host = URI.parse(default).host

      # Were it looked up, this entry would have it refused.
      :inet_db.add_host({10, 8, 8, 8}, [String.to_charlist(host)])
      on_exit(fn -> :inet_db.del_host({10, 8, 8, 8}) end)

      assert changeset(default).valid?
      refute changeset(default <> "/custom").valid?
    end
  end

  describe "a lookup that does not finish in time" do
    test "is abandoned at the timeout and the name counts as unresolved" do
      # Unbounded, this name is internal. The lookup asks the system
      # resolver for the name's other address family, which cannot answer
      # inside a zero budget.
      assert HTTP.host_class(@internal_name) == :internal
      assert HTTP.host_class(@internal_name, timeout: 0) == :unresolved
    end

    test "resolution switched off judges literals and reserved names only" do
      assert HTTP.host_class(@internal_name, resolve: false) == :unresolved
      assert HTTP.host_class("10.1.2.3", resolve: false) == :internal
      assert HTTP.host_class("93.184.216.34", resolve: false) == :public
      assert HTTP.host_class("host.docker.internal", resolve: false) == :internal
    end
  end

  describe "a provider that answers with a redirect" do
    setup do
      test_pid = self()

      Req.Test.stub(__MODULE__, fn conn ->
        send(test_pid, {:requested, conn.host, conn.request_path})

        conn
        |> Plug.Conn.put_resp_header("location", "http://169.254.169.254/latest/meta-data/")
        |> Plug.Conn.send_resp(302, "")
      end)

      Application.put_env(:phoenix_kit_ai, :req_options,
        plug: {Req.Test, __MODULE__},
        retry: false
      )

      {:ok, _} =
        PhoenixKit.Settings.update_json_setting(
          "integration:openrouter:default",
          %{"api_key" => "sk-test-key", "status" => "connected", "provider" => "openrouter"}
        )

      :ok
    end

    test "is not followed by a chat completion" do
      {:ok, endpoint} =
        PhoenixKitAI.create_endpoint(Map.delete(attrs(nil), :base_url))

      ExUnit.CaptureLog.capture_log(fn ->
        assert {:error, {:api_error, 302}} = PhoenixKitAI.ask(endpoint.uuid, "hello")
      end)

      assert_received {:requested, "openrouter.ai", "/api/v1/chat/completions"}
      refute_received {:requested, _host, _path}
    end

    test "is not followed by the provider adapters' HTTP door" do
      assert {:ok, %{status: 302}} =
               HTTP.post_json("https://api.example.com/v1/images", [], %{"prompt" => "x"})

      assert {:ok, %{status: 302}} = HTTP.get_json("https://api.example.com/v1/images/models", [])

      assert_received {:requested, "api.example.com", "/v1/images"}
      assert_received {:requested, "api.example.com", "/v1/images/models"}
      refute_received {:requested, _host, _path}
    end
  end
end
