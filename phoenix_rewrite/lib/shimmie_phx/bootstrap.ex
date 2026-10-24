defmodule ShimmiePhoenix.Bootstrap do
  @moduledoc "Explicit-secret initial administrator creation; never resets an existing administrator."
  alias ShimmiePhoenix.PasswordPolicy

  def ensure_admin!(repo, options \\ []) do
    {:ok, result} =
      repo.transaction(fn ->
        repo.query!("LOCK TABLE users IN SHARE ROW EXCLUSIVE MODE")
        [[count]] = repo.query!("SELECT COUNT(*) FROM users WHERE LOWER(class) = 'admin'").rows

        if count > 0 do
          :existing
        else
          password =
            Keyword.get(options, :password, System.get_env("SHIMMIE_BOOTSTRAP_ADMIN_PASSWORD"))

          name =
            Keyword.get(options, :name, System.get_env("SHIMMIE_BOOTSTRAP_ADMIN_NAME") || "admin")

          unless :ok == PasswordPolicy.validate(password, password) do
            raise "Set SHIMMIE_BOOTSTRAP_ADMIN_PASSWORD to a unique password of at least 12 characters (at most 72 UTF-8 bytes) before first migration"
          end

          unless is_binary(name) and Regex.match?(~r/\A[A-Za-z0-9_-]{2,32}\z/, name) do
            raise "Invalid SHIMMIE_BOOTSTRAP_ADMIN_NAME"
          end

          if repo.query!("SELECT 1 FROM users WHERE LOWER(name) = LOWER($1)", [name]).rows != [] do
            raise "Bootstrap account name already exists; choose another name explicitly"
          end

          hash = Bcrypt.hash_pwd_salt(password)

          [[id]] =
            repo.query!(
              "INSERT INTO users(id,name,pass,class,joindate) SELECT COALESCE(MAX(id),0)+1,$1,$2,'admin',NOW() FROM users RETURNING id",
              [name, hash]
            ).rows

          id
        end
      end)

    result
  end
end
