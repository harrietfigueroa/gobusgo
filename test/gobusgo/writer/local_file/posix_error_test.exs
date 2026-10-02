defmodule Gobusgo.Writer.LocalFile.PosixErrorTest do
  # Verifies the closed mapping from POSIX reasons to writer error reasons as
  # a pure function, including that unknown reasons raise.
  use ExUnit.Case, async: true

  alias Gobusgo.Writer.LocalFile.PosixError

  for {posix, reason} <- [
        eexist: :already_exists,
        eacces: :permission_denied,
        eperm: :permission_denied,
        enospc: :storage_full,
        edquot: :storage_full,
        erofs: :read_only,
        eio: :io_failure,
        enotdir: :destination_conflict,
        eisdir: :destination_conflict,
        enametoolong: {:invalid_destination, :too_long},
        eloop: {:invalid_destination, :redirected}
      ] do
    test "maps #{posix} to #{inspect(reason)}" do
      assert PosixError.to_reason(unquote(posix)) == unquote(Macro.escape(reason))
    end
  end

  for posix <- [:einval, :enomem, :emfile, :ebusy] do
    test "raises for unrecognized reason #{posix}" do
      assert_raise Gobusgo.Assert.AssertionError, fn -> PosixError.to_reason(unquote(posix)) end
    end
  end
end
