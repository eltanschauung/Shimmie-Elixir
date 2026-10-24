defmodule ShimmiePhoenix.PasswordPolicy do
  @moduledoc "New password policy, shared by account creation, changes and bootstrap."
  def validate(password, confirmation) when is_binary(password) and is_binary(confirmation) do
    cond do
      password != confirmation ->
        {:error, :password_mismatch}

      not String.valid?(password) or String.length(password) < 12 or byte_size(password) > 72 ->
        {:error, :invalid_password}

      true ->
        :ok
    end
  end

  def validate(_, _), do: {:error, :invalid_password}
end
