defmodule Joken do
  @moduledoc """
  Joken is a library for working with standard JSON Web Tokens.

  It provides 4 basic operations:

  - Verify: the act of confirming the signature of the JWT;
  - Validate: processing validation logic on the set of claims;
  - Claim generation: generate dynamic value at token creation time;
  - Signature creation: encoding header and claims and generate a signature of their value.

  ## Architecture

  The core of Joken is `JOSE`, a library which provides all facilities to sign and verify tokens.
  Joken brings an easier Elixir API with some added functionality:

    - Validating claims. JOSE does not provide validation other than signature verification.
    - `config.exs` friendly. You can optionally define your signer configuration straight in your 
    `config.exs`.
    - Portable configuration. All your token logic can be encapsulated in a module with behaviours. 
    - Enhanced errors. Joken strives to be as informative as it can when errors happen be it at 
    compilation or at validation time.
    - Debug friendly. When a token fails validation, a `Logger` debug message will show which claim 
    failed validation with which value. The return value, though for security reasons, does not 
    contain these information.
    - Performance. We have a benchmark suite for identifying where we can have a better performance. 
    From this analysis came: Jason adapter for JOSE, redefinition of :base64url module and other 
    minor tweaks. 

  ## Usage

  Joken has 3 basic concepts:

    - Portable token configuration
    - Signer configuration
    - Hooks

  The portable token configuration is a map of binary keys to `Joken.Claim` structs and is used to 
  dynamically generate and validate tokens.

  A signer is an instance of `Joken.Signer` that encapsulates the algorithm and the key configuration 
  used to sign and verify a token.

  A hook is an implementation of the behaviour `Joken.Hooks` for easy plugging into the lifecycle of
  Joken operations.

  There are 2 forms of using Joken:

  1. Pure data structures. You can create your token configuration and signer and use them with this 
  module for all 4 operations: verify, validate, generate and sign.

      iex> token_config = %{}
      iex> %{ token_config | "scope" => %Joken.Claim{
      ...> generate_function: fn -> "user" end,
      ...> validate_function: &(&1 in ["user", "admin"])
      ...> }}
      iex> signer = Joken.Signer.create("HS256", "my secret")
      iex> claims = Joken.generate_claims(token_config, %{"extra"=> "claim"})
      iex> {:ok, jwt, claims} = Joken.encode_and_sign(claims, signer)

  2. With the encapsulated module approach using `Joken.Config`. See the docs for `Joken.Config` for 
  more details.

      iex> defmodule MyAppToken do
      ...>   use Joken.Config, default_signer: :pem_rs256
      ...>
      ...>   @impl Joken.Config
      ...>   def token_config do
      ...>     default_claims()
      ...>     |> add_claim("role", fn -> "USER" end, &(&1 in ["ADMIN", "USER"]))
      ...>   end
      ...> end
      iex> {:ok, token, _claims} = MyAppToken.generate_and_sign(%{"user_id" => "1234567890"})
      iex> {:ok, _claim_map} = MyAppToken.verify_and_validate(token)
  """
  alias Joken.{Signer, Claim}
  require Logger

  @typedoc """
  A signer argument that can be a key in the configuration or an instance of `Joken.Signer`.
  """
  @type signer_arg :: atom | Joken.Signer.t()

  @typedoc "A binary representing a bearer token."
  @type bearer_token :: binary

  @typedoc "A map with binary keys that represents a claim set."
  @type claims :: %{binary => term}

  @typedoc "A portable configuration of claims for generation and validation."
  @type token_config :: %{binary => Joken.Claim.t()}

  @type error_reason :: atom | binary | Keyword.t()

  # This ensures we provide an easy to setup test environment
  @current_time_adapter Application.get_env(:joken, :current_time_adapter, Joken.CurrentTime.OS)

  @doc """
  Retrieves current time in seconds. 

  This implementation uses an adapter so that you can replace it on your tests. The adapter is
  set through `config.exs`. Example:

      config :joken, 
        current_time_adapter: Joken.CurrentTime.OS

  See Joken's own tests for an example of how to override this with a customizable time mock.
  """
  @spec current_time() :: pos_integer
  def current_time(), do: @current_time_adapter.current_time()

  @doc """
  Decodes the header of a token without validation.

  **Use this with care!** This DOES NOT validate the token signature and therefore the token might 
  be invalid. The common use case for this function is when you need info to decide on which signer 
  will be used. Even though there is a use case for this, be extra careful to handle data without 
  validation.
  """
  @spec peek_header(bearer_token) :: claims
  def peek_header(token) when is_binary(token) do
    %JOSE.JWS{alg: {_, alg}, fields: fields} = JOSE.JWT.peek_protected(token)
    Map.put(fields, "alg", Atom.to_string(alg))
  end

  @doc """
  Decodes the claim set of a token without validation.

  **Use this with care!** This DOES NOT validate the token signature and therefore the token might 
  be invalid. The common use case for this function is when you need info to decide on which signer 
  will be used. Even though there is a use case for this, be extra careful to handle data without 
  validation.
  """
  @spec peek_claims(bearer_token) :: claims
  def peek_claims(token) when is_binary(token) do
    %JOSE.JWT{fields: fields} = JOSE.JWT.peek_payload(token)
    fields
  end

  @doc """
  Default function for generating `jti` claims. This was inspired by the `Plug.RequestId` generation.
  It avoids using `strong_rand_bytes` as it is known to have some contention when running with many 
  schedulers.
  """
  @spec generate_jti() :: binary
  def generate_jti do
    binary = <<
      System.system_time(:nanoseconds)::64,
      :erlang.phash2({node(), self()}, 16_777_216)::24,
      :erlang.unique_integer()::32
    >>

    Base.hex_encode32(binary, case: :lower)
  end

  @doc """
  Verifies a bearer_token using the given signer and executes hooks if any are given.
  """
  @spec verify(bearer_token, signer_arg, [module]) :: {:ok, claims} | {:error, error_reason}
  def verify(bearer_token, signer, hooks \\ [])

  def verify(bearer_token, nil, hooks) when is_binary(bearer_token) and is_list(hooks),
    do: verify(bearer_token, %Signer{}, hooks)

  def verify(bearer_token, signer, hooks) when is_binary(bearer_token) and is_atom(signer),
    do: verify(bearer_token, parse_signer(signer), hooks)

  def verify(bearer_token, signer = %Signer{}, hooks) when is_binary(bearer_token) do
    with {:ok, bearer_token, signer} <- before_verify(bearer_token, signer, hooks),
         :ok <- check_signer_not_empty(signer),
         result = {:ok, claim_map} <- Signer.verify(bearer_token, signer),
         status <- parse_status(result),
         {:ok, claims_map} <- after_verify(status, bearer_token, claim_map, signer, hooks) do
      {:ok, claims_map}
    end
  end

  defp check_signer_not_empty(%Signer{alg: nil}), do: {:error, :empty_signer}
  defp check_signer_not_empty(%Signer{}), do: :ok

  @doc """
  Validates the claim map with the given token configuration and the context.

  Context can by any term. It is always passed as the second argument to the validate 
  function.

  It also executes hooks if any are given.
  """
  @spec validate(token_config, claims, term, [module]) :: {:ok, claims} | {:error, error_reason}
  def validate(token_config, claims_map, context, hooks \\ []) do
    with {:ok, claims_map, config} <- before_validate(claims_map, token_config, hooks),
         result <- reduce_validations(token_config, claims_map, context),
         status <- parse_status(result),
         {:ok, claims} <- after_validate(status, claims_map, config, hooks) do
      {:ok, claims}
    end
  end

  @doc """
  Generates claims with the given token configuration and merges them with the given extra claims. 

  It also executes hooks if any are given.
  """
  @spec generate_claims(token_config, claims, [module]) :: {:ok, claims} | {:error, error_reason}
  def generate_claims(token_config, extra_claims, hooks \\ []) do
    with {:ok, extra_claims, token_config} <- before_generate(extra_claims, token_config, hooks),
         claims <- Enum.reduce(token_config, extra_claims, &Claim.__generate_claim__/2),
         {:ok, claims} <- after_generate(claims, hooks) do
      {:ok, claims}
    end
  end

  @doc """
  Encodes and generates a token from the given claim map and signs the result with the given signer.

  It also executes hooks if any are given.
  """
  @spec encode_and_sign(claims, signer_arg, [module]) :: {:ok, bearer_token, claims}
  def encode_and_sign(claims, signer, hooks \\ [])

  def encode_and_sign(claims, nil, hooks),
    do: encode_and_sign(claims, %Signer{}, hooks)

  def encode_and_sign(claims, signer, hooks) when is_atom(signer),
    do: encode_and_sign(claims, parse_signer(signer), hooks)

  def encode_and_sign(claims, %Signer{} = signer, hooks) do
    with {:ok, claims, signer} <- before_sign(claims, signer, hooks),
         :ok <- check_signer_not_empty(signer),
         result = {_, token} <- Signer.sign(claims, signer),
         status <- parse_status(result),
         {:ok, token, claims} <- after_sign(status, token, claims, signer, hooks) do
      {:ok, token, claims}
    end
  end

  defp parse_status(:ok), do: :ok
  defp parse_status({:ok, _}), do: :ok
  defp parse_status({:error, _} = res), do: res

  defp parse_signer(signer_key) do
    signer = Signer.parse_config(signer_key)

    if is_nil(signer),
      do: raise(Joken.Error, :no_default_signer),
      else: signer
  end

  defp reduce_validations(config, claim_map, context) do
    Enum.reduce_while(claim_map, nil, fn {key, claim_val}, _acc ->
      # When there is a function for validating the token
      with %Claim{validate: val_func} when not is_nil(val_func) <- config[key],
           true <- val_func.(claim_val, claim_map, context) do
        {:cont, :ok}
      else
        # When there is no configuration for the claim
        nil ->
          {:cont, :ok}

        # When there is a configuration but no validation function
        %Claim{validate: nil} ->
          {:cont, :ok}

        # When it fails validation
        false ->
          Logger.debug(fn ->
            """
            Claim %{"#{key}" => #{inspect(claim_val)}} did not pass validation.

            Current time: #{inspect(Joken.current_time())}
            """
          end)

          {:halt, {:error, message: "Invalid token", claim: key, claim_val: claim_val}}
      end
    end)
  end

  defp before_verify(bearer_token, signer, hooks) do
    run(
      hooks,
      {:ok, bearer_token, signer},
      fn hook, options, {_status, bearer_token, signer} ->
        hook.before_verify(options, bearer_token, signer)
      end
    )
  end

  defp before_validate(claims_map, token_config, hooks) do
    run(
      hooks,
      {:ok, claims_map, token_config},
      fn hook, options, {_status, claims_map, token_config} ->
        hook.before_validate(options, claims_map, token_config)
      end
    )
  end

  defp before_generate(extra_claims, token_config, hooks) do
    run(
      hooks,
      {:ok, extra_claims, token_config},
      fn hook, options, {_status, extra_claims, token_config} ->
        hook.before_generate(options, extra_claims, token_config)
      end
    )
  end

  defp before_sign(claims, signer, hooks) do
    run(
      hooks,
      {:ok, claims, signer},
      fn hook, options, {_status, claims, signer} ->
        hook.before_sign(options, claims, signer)
      end
    )
  end

  defp after_verify(status, bearer_token, claims_map, signer, hooks) do
    result =
      run_after_hook(
        hooks,
        {status, bearer_token, claims_map, signer},
        fn hook, options, {status, bearer_token, claims_map, signer} ->
          hook.after_verify(options, status, bearer_token, claims_map, signer)
        end
      )

    with {:ok, _bearer_token, claims_map, _signer} <- result do
      {:ok, claims_map}
    end
  end

  defp after_validate(status, claims_map, config, hooks) do
    result =
      run_after_hook(
        hooks,
        {status, claims_map, config},
        fn hook, options, {status, claims_map, config} ->
          hook.after_validate(options, status, claims_map, config)
        end
      )

    with {:ok, claims, _config} <- result do
      {:ok, claims}
    end
  end

  defp after_generate(claims, hooks) do
    run_after_hook(
      hooks,
      {:ok, claims},
      fn hook, options, {:ok, claims} ->
        hook.after_generate(options, claims)
      end
    )
  end

  defp after_sign(status, bearer_token, claims, signer, hooks) do
    result =
      run_after_hook(
        hooks,
        {status, bearer_token, claims, signer},
        fn hook, options, {status, bearer_token, claims, signer} ->
          hook.after_sign(options, status, bearer_token, claims, signer)
        end
      )

    with {:ok, bearer_token, claims, _signer} <- result do
      {:ok, bearer_token, claims}
    end
  end

  defp run_after_hook(hooks, args, fun) do
    result = run(hooks, args, fun)
    status = fetch_status(result)

    case status do
      :ok ->
        result

      :error ->
        {:error, :error_in_after_hook}

      {:error, reason} ->
        {:error, reason}

      :halt ->
        result

      _ ->
        {:error, :wrong_hook_callback_return}
    end
  end

  defp run(hooks, args, fun) do
    Enum.reduce_while(hooks, args, fn hook, args ->
      {hook, options} = unwrap_hook(hook)
      result = fun.(hook, options, args)
      status = fetch_status(result)

      case status do
        :ok ->
          {:cont, result}

        :error ->
          {:cont, result}

        {:error, _} ->
          {:cont, result}

        :halt ->
          {:halt, result}

        _ ->
          {:halt, {:error, :wrong_hook_callback}}
      end
    end)
  end

  defp fetch_status(result) when is_tuple(result), do: elem(result, 0)
  defp fetch_status(:ok), do: {:halt, :wrong_hook_callback}
  defp fetch_status(result), do: result

  defp unwrap_hook({_hook_module, _opts} = hook), do: hook
  defp unwrap_hook(hook) when is_atom(hook), do: {hook, []}
end
