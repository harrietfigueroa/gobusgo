defmodule Gobusgo.Reader.LocalFile.PosixErrorTest do
  # Verifies the closed mapping from POSIX reasons to reader error reasons as
  # a pure function, including that unknown reasons raise.
  use ExUnit.Case, async: true

  alias Gobusgo.Reader.LocalFile.PosixError

  for {posix, reason} <- [
        enoent: :not_found,
        enotdir: :not_found,
        eisdir: :not_found,
        eacces: :permission_denied,
        eperm: :permission_denied,
        eio: :io_failure,
        enametoolong: {:invalid_destination, :too_long},
        eloop: {:invalid_destination, :redirected}
      ] do
    test "maps #{posix} to #{inspect(reason)}" do
      assert PosixError.to_reason(unquote(posix)) == unquote(Macro.escape(reason))
    end
  end

  for posix <- [:einval, :enomem, :emfile, :eexist] do
    test "raises for unrecognized reason #{posix}" do
      assert_raise Gobusgo.Assert.AssertionError, fn -> PosixError.to_reason(unquote(posix)) end
    end
  end
end
