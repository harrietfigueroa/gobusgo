defmodule Gobusgo.Reader.LocalFile.PosixError do
  @moduledoc """
  The closed mapping from POSIX reasons to `t:Gobusgo.Reader.error_reason/0`.
  Pure; a reason outside the mapping raises, so a new failure mode surfaces
  as a programmer error rather than a silently misfiled outcome.
  """

  alias Gobusgo.Assert

  @doc "Returns the reader error reason for a POSIX reason atom."
  @spec to_reason(atom()) :: Gobusgo.Reader.error_reason()
  def to_reason(:enoent), do: :not_found
  def to_reason(:enotdir), do: :not_found
  def to_reason(:eisdir), do: :not_found
  def to_reason(:eacces), do: :permission_denied
  def to_reason(:eperm), do: :permission_denied
  def to_reason(:eio), do: :io_failure
  def to_reason(:enametoolong), do: {:invalid_destination, :too_long}
  def to_reason(:eloop), do: {:invalid_destination, :redirected}
  def to_reason(other), do: Assert.unreachable(other)
end
